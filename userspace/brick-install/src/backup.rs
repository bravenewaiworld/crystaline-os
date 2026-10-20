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
//!
//! A restore runs from the SD card's system. From the installed system, `restore` prepares it:
//! it copies the first-stage loader from the internal storage back onto the card, where an
//! install erased it, then leaves a marker, `backups/restore-pending.json` (`PENDING`), on the
//! data partition. After a restart the card's system starts; Specular sees the marker (offer's
//! `restore_pending`) and offers to continue, or to cancel, which erases the card's first-stage
//! loader again. The loader is written before the marker: a power cut between the two leaves a
//! card that starts the device without a marker, from which the backup can still be restored in
//! Settings as usual.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::Paths;
use crate::disk::{self, CHUNK, Disk};
use crate::install::{self, CARD_BOOT0, RESTORING};
use crate::report::{Context, REWRITE_CARD, Report, Result, fail, gb, hex, read_json, timestamp};

/// How much of the disk each piece holds.
const PIECE: u64 = 1 << 30;
/// The prepared-restore marker, in `<data>/backups/`:
///   { "backup": the backup folder's name, "bytes": its disk size, "prepared": when (UTC) }
const PENDING: &str = "restore-pending.json";
/// The partitions a card made for this system has.
const CARD_PARTS: [&str; 6] = ["bootloader", "env", "env-redund", "boot_a", "boot_b", "system"];

/// A complete backup found on the card. `holds` is None when its manifest doesn't record it.
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
    let bytes = dirs.iter().map(|d| install::dir_bytes(d)).sum();
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

/// `brick-install restore <dir>`: from the SD card, `restore`; from the installed system, `prepare`.
pub fn restore_or_prepare(p: &Paths, dir: &Path, report: &mut Report) -> Result<String> {
    if !p.on_card() { return prepare(p, dir, report); }
    report.steps(3);
    report.step("Checking the backup");
    install::battery_ok(&p.power, report)?;
    let target = Disk::open(p.internal()?, true)?;
    restore(dir, &target, report)?;
    let marker = p.data.join("backups").join(PENDING);
    if marker.exists() {
        report.log(&format!("deleting {}", marker.display()));
        std::fs::remove_file(&marker).ctx("deleting the prepared restore's marker")?;
    }
    Ok("Restored the internal storage. Power off, remove the SD card, then turn the device on.".into())
}

/// Writes the backup in `dir` back onto `disk`, in 3 steps (the caller starts the first): every
/// piece is checked first, then written, then the whole disk is read back and compared. The first
/// chunk (with the partition table) is written last, over the `RESTORING` marker (see install.rs).
fn restore(dir: &Path, disk: &Disk, report: &mut Report) -> Result<()> {
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

/// Prepares restoring the backup in `dir` from the installed system (see the top of this file).
fn prepare(p: &Paths, dir: &Path, report: &mut Report) -> Result<String> {
    report.steps(2);
    report.step("Checking");
    let internal = Disk::open(p.internal()?, false)?;
    let card = Disk::open(p.card()?, true)?;
    can_prepare(&internal, &card)?;
    let m = read_json(&dir.join("manifest.json"), "the backup's manifest")?;
    if m["bytes"].as_u64() != Some(internal.size) {
        return fail(format!("the backup is of a {} disk, the internal storage holds {}", gb(m["bytes"].as_u64().unwrap_or(0)), gb(internal.size)), "This backup is from another device.");
    }
    if let Some(missing) = m["pieces"].as_array().into_iter().flatten().filter_map(|p| p["file"].as_str()).find(|f| !dir.join(f).is_file()) {
        return fail(format!("{missing} of the backup is missing"), "This backup can't be used.");
    }
    report.log(&format!("backup {}: {} bytes, made {}", dir.display(), m["bytes"], m["created"]));
    install::battery_ok(&p.power, report)?;

    report.step("Making the SD card start the device");
    let (from, len) = install::bytes(CARD_BOOT0);
    card.write_checked(from, &internal.read_at(from, len as usize)?, "the first-stage loader (from the internal storage)", report)?;
    let name = dir.file_name().unwrap_or_default().to_string_lossy();
    let marker = serde_json::json!({ "backup": name, "bytes": m["bytes"], "prepared": timestamp() });
    let (path, tmp) = (p.data.join("backups").join(PENDING), p.data.join("backups").join(format!("{PENDING}.new")));
    let write = || -> std::io::Result<()> {
        let mut f = File::create(&tmp)?;
        f.write_all(&serde_json::to_vec_pretty(&marker).unwrap())?;
        f.sync_all()?;
        std::fs::rename(&tmp, &path)?;
        File::open(p.data.join("backups"))?.sync_all()
    };
    write().ctx("writing the prepared restore's marker")?;
    report.log(&format!("wrote {}: {marker}", path.display()));
    Ok("Restart to continue the restore from the SD card.".into())
}

/// Whether a restore can be prepared: the internal storage holds this system, and the card is one
/// of ours that starts (the boot slot its settings name holds a boot image).
fn can_prepare(internal: &Disk, card: &Disk) -> Result<()> {
    if install::holds(internal) != "this-system" {
        return fail(format!("the internal storage holds {}, not this system", install::holds(internal)), "Restore from the SD card's system instead.");
    }
    let rewrite = format!("{REWRITE_CARD} Then try again.");
    let parts = card.partitions()?;
    if let Some(missing) = CARD_PARTS.iter().find(|n| disk::named(&parts, n, &card.path).is_err()) {
        return fail(format!("the SD card has no {missing} partition: it wasn't made for this version of the system"), rewrite);
    }
    let (settings, _) = crate::env::current(card, &parts)?;
    let slot = crate::env::get(&settings.pairs, "boot_partition").unwrap_or_default();
    if !disk::named(&parts, slot, &card.path).and_then(|s| card.read_at(s.start, 8)).is_ok_and(|b| b == b"ANDROID!") {
        return fail(format!("the SD card's boot slot {slot:?} holds no system"), rewrite);
    }
    Ok(())
}

/// `brick-install restore --cancel`, on the SD card: drops a prepared restore (its marker) and
/// erases the card's first-stage loader again, so the device starts from the internal storage.
pub fn cancel(p: &Paths, report: &mut Report) -> Result<String> {
    report.steps(1);
    report.step("Cancelling the restore");
    if !p.on_card() { return fail("the system isn't running from an SD card", "Cancel the restore from the SD card's system."); }
    let held = install::holds(&Disk::open(p.internal()?, false)?);
    if held != "this-system" {
        return fail(format!("the internal storage holds {held}, not this system"), "Without this system on the internal storage, the device has to start from the SD card.");
    }
    let marker = p.data.join("backups").join(PENDING);
    match std::fs::remove_file(&marker) {
        Ok(()) => report.log(&format!("deleted {}", marker.display())),
        Err(e) => report.log(&format!("{}: {e}", marker.display())),
    }
    let card = Disk::open(p.card()?, true)?;
    let (from, len) = install::bytes(CARD_BOOT0);
    card.write_checked(from, &vec![0; len as usize], "zeros over the card's first-stage loader", report)?;
    Ok("The restore is cancelled. Restart to start from the internal storage.".into())
}

/// For `offer` on the SD card: the prepared restore's marker, or null.
pub fn pending(data: &Path) -> serde_json::Value {
    read_json(&data.join("backups").join(PENDING), "").unwrap_or(serde_json::Value::Null)
}

/// For `offer` on the installed system: whether a restore can be prepared ({ "possible": true }
/// or { "why_not" }); the backup itself is checked when it runs.
pub fn offer_prepare(p: &Paths) -> serde_json::Value {
    let ready = || can_prepare(&Disk::open(p.internal()?, false)?, &Disk::open(p.card()?, false)?);
    match ready() {
        Ok(()) => serde_json::json!({ "possible": true }),
        Err(e) => serde_json::json!({ "why_not": e.message }),
    }
}
