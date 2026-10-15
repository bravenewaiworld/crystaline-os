//! A backup of a whole disk (the internal storage) to a folder on the SD card's data partition,
//! and putting one back. backups/internal-<time, UTC>/ holds:
//!   piece-NNN.zst   1 GiB of the disk each (the last one less), zstd-compressed (FAT32, the data
//!                   partition's filesystem, can't hold a file over 4 GiB)
//!   manifest.json   { "created", "bytes": the disk's size, "sha256": of the whole disk,
//!                     "holds": what the disk held (install::holds),
//!                     "pieces": [{ "file", "bytes", "sha256" (of the piece's disk bytes) }] }
//! A backup is made under a name ending in ".partial" and renamed once every piece has been read
//! back and checked, so a folder without it is complete; one with it is left from a backup cut
//! short, and is deleted when the next backup starts.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::disk::{CHUNK, Disk};
use crate::install::{self, RESTORING};
use crate::report::{Context, Report, Result, fail, gb, read_json, timestamp};

const PIECE: u64 = 1 << 30;
/// How many steps `restore` reports.
pub const RESTORE_STEPS: usize = 3;

/// A complete backup found on the card. `holds` is missing in backups made before it was recorded.
pub struct Found { pub dir: PathBuf, pub created: String, pub bytes: u64, pub holds: Option<String> }

/// The complete backups in `<data>/backups`, newest first.
pub fn list(data: &Path) -> Vec<Found> {
    let mut found: Vec<Found> = std::fs::read_dir(data.join("backups")).into_iter().flatten().flatten()
        .filter(|e| !e.file_name().to_string_lossy().ends_with(".partial"))
        .filter_map(|e| {
            let m = read_json(&e.path().join("manifest.json"), "").ok()?;
            Some(Found { dir: e.path(), created: m["created"].as_str()?.into(), bytes: m["bytes"].as_u64()?, holds: m["holds"].as_str().map(Into::into) })
        })
        .collect();
    found.sort_by(|a, b| b.created.cmp(&a.created));
    found
}

/// Backups cut short, in `<data>/backups`, and how much room they take.
pub fn leftovers(data: &Path) -> (Vec<PathBuf>, u64) {
    let dirs: Vec<PathBuf> = std::fs::read_dir(data.join("backups")).into_iter().flatten().flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".partial")).map(|e| e.path()).collect();
    let bytes = dirs.iter().flat_map(|d| std::fs::read_dir(d).into_iter().flatten().flatten())
        .filter_map(|f| f.metadata().ok()).map(|m| m.len()).sum();
    (dirs, bytes)
}

/// Backs `disk` up into a new folder under `<data>/backups`, then reads every piece back and
/// checks it. Returns the folder.
pub fn make(disk: &Disk, data: &Path, report: &mut Report) -> Result<PathBuf> {
    for old in leftovers(data).0 {
        report.log(&format!("deleting {}, from a backup cut short", old.display()));
        std::fs::remove_dir_all(&old).ctx(&format!("deleting {}", old.display()))?;
    }
    let created = timestamp();
    let done_dir = data.join("backups").join(format!("internal-{created}"));
    let dir = PathBuf::from(format!("{}.partial", done_dir.display()));
    std::fs::create_dir_all(&dir).ctx(&format!("making {}", dir.display()))?;
    let (mut whole, mut pieces, mut offset) = (Sha256::new(), Vec::new(), 0);
    while offset < disk.size {
        let len = PIECE.min(disk.size - offset);
        let file = format!("piece-{:03}.zst", pieces.len());
        let mut enc = zstd::Encoder::new(File::create(dir.join(&file)).ctx(&format!("making {file}"))?, 1).ctx("starting compression")?;
        let mut piece = Sha256::new();
        disk.each_chunk(offset, len, |off, chunk| {
            whole.update(chunk);
            piece.update(chunk);
            enc.write_all(chunk).ctx(&format!("writing {file} (is the card full?)"))?;
            report.progress(offset + off + chunk.len() as u64, disk.size);
            Ok(())
        })?;
        enc.finish().and_then(|f| f.sync_all()).ctx(&format!("finishing {file}"))?;
        pieces.push(serde_json::json!({ "file": file, "bytes": len, "sha256": hex(&piece.finalize()) }));
        offset += len;
    }
    let manifest = serde_json::json!({ "created": created, "bytes": disk.size, "sha256": hex(&whole.finalize()), "holds": install::holds(disk), "pieces": pieces });
    std::fs::write(dir.join("manifest.json"), serde_json::to_vec_pretty(&manifest).unwrap()).ctx("writing the backup's manifest")?;
    report.log(&format!("backup written to {}; reading it back", dir.display()));
    check(&dir, report)?;
    std::fs::rename(&dir, &done_dir).ctx("naming the finished backup")?;
    report.log(&format!("backup complete: {}", done_dir.display()));
    Ok(done_dir)
}

/// Reads every piece of the backup in `dir` and checks it against the manifest. Returns the
/// manifest.
pub fn check(dir: &Path, report: &mut Report) -> Result<serde_json::Value> {
    let m = read_json(&dir.join("manifest.json"), "the backup's manifest")?;
    let total = m["bytes"].as_u64().unwrap_or(0);
    let mut done = 0;
    each_piece(dir, &m, |chunk| { done += chunk.len() as u64; report.progress(done, total); Ok(()) })?;
    Ok(m)
}

/// Writes the backup in `dir` back onto `disk`, in `RESTORE_STEPS` steps: every piece is checked
/// first, then written, then the whole disk is read back and compared. The first chunk (with the
/// partition table) is written last, over the `RESTORING` marker (see install.rs).
pub fn restore(dir: &Path, disk: &Disk, report: &mut Report) -> Result<()> {
    report.step("Checking the backup");
    let m = check(dir, report)?;
    let total = m["bytes"].as_u64().unwrap_or(0);
    if total != disk.size {
        return fail(format!("the backup is of a {} disk, the internal storage holds {}", gb(total), gb(disk.size)),
                    "This backup is from another device.");
    }
    report.step("Writing the internal storage");
    install::mark(disk, RESTORING)?;
    let (mut at, mut first) = (0, Vec::with_capacity(CHUNK));
    each_piece(dir, &m, |mut chunk| {
        let held = (CHUNK - first.len()).min(chunk.len());
        first.extend_from_slice(&chunk[..held]);
        chunk = &chunk[held..];
        disk.write_at(at + held as u64, chunk)?;
        at += (held + chunk.len()) as u64;
        report.progress(at, total);
        Ok(())
    })?;
    disk.sync()?;
    disk.write_at(0, &first)?;
    disk.sync()?;
    report.step("Checking the internal storage");
    let mut whole = Sha256::new();
    disk.each_chunk(0, total, |off, chunk| { whole.update(chunk); report.progress(off + chunk.len() as u64, total); Ok(()) })?;
    if hex(&whole.finalize()) != m["sha256"].as_str().unwrap_or_default() {
        return fail("the internal storage doesn't read back as the backup", "Try restoring again; if it fails again, the internal storage may be failing.");
    }
    Ok(())
}

/// Decompresses each piece in order, checking its size and checksum, and hands its bytes to `f`.
fn each_piece(dir: &Path, m: &serde_json::Value, mut f: impl FnMut(&[u8]) -> Result<()>) -> Result<()> {
    for p in m["pieces"].as_array().into_iter().flatten() {
        let name = p["file"].as_str().unwrap_or_default();
        let file = File::open(dir.join(name)).ctx(&format!("opening {name}"))?;
        let mut dec = zstd::Decoder::new(file).ctx(&format!("reading {name}"))?;
        let (mut sha, mut len, mut buf) = (Sha256::new(), 0u64, vec![0; CHUNK]);
        loop {
            let n = dec.read(&mut buf).ctx(&format!("reading {name}"))?;
            if n == 0 { break; }
            sha.update(&buf[..n]);
            len += n as u64;
            f(&buf[..n])?;
        }
        if len != p["bytes"].as_u64().unwrap_or(0) || hex(&sha.finalize()) != p["sha256"].as_str().unwrap_or_default() {
            return fail(format!("{name} in {} is damaged", dir.display()), "This backup can't be used; the SD card may be failing.");
        }
    }
    Ok(())
}

pub fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }
