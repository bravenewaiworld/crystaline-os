//! Update files: one version of the system (build-system.sh's output) and a signature over its
//! manifest, made by tools/system/sign-update.sh. A ustar tar holding exactly, in this order:
//!   manifest.json     the version's manifest
//!   manifest.sig      64 bytes: an Ed25519 signature over manifest.json's exact bytes
//!   boot.img
//!   rootfs.squashfs
//! The manifest and its signature come first, so nothing is trusted before the signature is
//! checked: the other files' sizes and SHA-256 come from the signed manifest. The reader is
//! strict (any other name, order, type or extension header is refused) rather than a general
//! tar reader, which would accept far more than sign-update.sh writes.
//!
//! Trusted keys are files of 64 hex characters (a raw Ed25519 public key) in the keys folder
//! (/etc/brick/update-keys/; --keys).

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::Paths;
use crate::disk::{self, Disk};
use crate::install;
use crate::report::{Context, RELEASES, REWRITE_CARD, Report, Result, fail, hex};
use crate::slots;

/// The largest manifest.json accepted.
const MANIFEST_MAX: u64 = 64 << 10;
/// Room left free on the system partition after an update's files.
const SPARE: u64 = 16 << 20;
const DAMAGED: &str = "Download the update file again.";

/// An update file whose head (manifest and signature) has been checked.
pub struct Update {
    file: Disk,
    /// The version it holds (its manifest's).
    pub version: String,
    /// manifest.json's exact bytes.
    manifest: Vec<u8>,
    /// manifest.sig: the signature over them.
    sig: Vec<u8>,
    /// The trusted key file that verified the signature.
    pub key: String,
    /// boot.img and rootfs.squashfs: where their data starts in the file, their size and SHA-256.
    images: [(&'static str, u64, u64, String); 2],
}

/// Reads and checks an update file against the keys in `keys`: its layout, the signature, the
/// version's name, and that its files' sizes match the signed manifest (their contents are
/// checked as they are copied).
pub fn open(path: &Path, keys: &Path) -> Result<Update> {
    let file = Disk::open(path, false)?;
    let damaged = |why: &str| damaged(path, why);
    let m = member(&file, 0, "manifest.json")?;
    if m.1 > MANIFEST_MAX { return damaged("manifest.json is too big"); }
    let sig_m = member(&file, next(m), "manifest.sig")?;
    if sig_m.1 != 64 { return damaged("manifest.sig isn't 64 bytes"); }
    let (manifest, sig) = (file.read_at(m.0, m.1 as usize)?, file.read_at(sig_m.0, 64)?);
    let Some(key) = verify(keys, &manifest, &sig) else {
        // (A development image also trusts its checkout's key: its own update files pass.)
        return fail(format!("{} isn't signed for this system", path.display()), format!("Download the update file from {RELEASES}."));
    };
    let json: serde_json::Value = serde_json::from_slice(&manifest).ctx("reading the update's manifest")?;
    let version = json["version"].as_str().unwrap_or_default().to_string();
    if !valid_version(&version) { return damaged(&format!("version name {version:?}")); }
    install::require_dt_edits(&json)?;
    let mut at = next(sig_m);
    let mut images = Vec::new();
    for name in ["boot.img", "rootfs.squashfs"] {
        let f = &json["files"][name];
        let (Some(size), Some(sha)) = (f["size"].as_u64(), f["sha256"].as_str()) else { return damaged(&format!("the manifest lacks {name}")) };
        let i = member(&file, at, name)?;
        if i.1 != size { return damaged(&format!("{name} isn't the size its manifest says")); }
        images.push((name, i.0, size, sha.to_string()));
        at = next(i);
    }
    if json["files"].as_object().map(|o| o.len()) != Some(2) { return damaged("the manifest lists other files"); }
    // The end: the two zero blocks that end a tar, then only the zeros tar pads its last record
    // with (10 KiB records; up to 64 KiB is accepted).
    let rest = file.size.saturating_sub(at);
    if !(1024..=64 << 10).contains(&rest) || file.read_at(at, rest as usize)?.iter().any(|&b| b != 0) {
        return damaged("something follows rootfs.squashfs");
    }
    Ok(Update { file, version, manifest, sig, key, images: images.try_into().unwrap() })
}

/// A tar member's header at `at`, which must be a plain file named `name`: where its data starts
/// and its size.
fn member(file: &Disk, at: u64, name: &str) -> Result<(u64, u64)> {
    let damaged = |why: String| damaged(&file.path, why);
    if at + 512 > file.size { return damaged(format!("it ends before {name}")); }
    let h = file.read_at(at, 512)?;
    let octal = |field: &[u8]| std::str::from_utf8(field).ok()
        .and_then(|s| u64::from_str_radix(s.trim_matches(|c| c == '\0' || c == ' '), 8).ok());
    // The checksum: the sum of the header's bytes with its own field counted as spaces.
    let sum: u64 = h.iter().enumerate().map(|(i, &b)| if (148..156).contains(&i) { 32 } else { b as u64 }).sum();
    let mut want = name.as_bytes().to_vec();
    want.resize(100, 0);
    if h[..100] != want[..] { return damaged(format!("expected {name} next")); }
    if &h[257..265] != b"ustar\x0000" || !matches!(h[156], b'0' | 0) || h[345..500].iter().any(|&b| b != 0) || octal(&h[148..156]) != Some(sum) {
        return damaged(format!("{name}'s tar header"));
    }
    let Some(size) = octal(&h[124..136]) else { return damaged(format!("{name}'s size")) };
    if at + 512 + size > file.size { return damaged(format!("it ends inside {name}")); }
    Ok((at + 512, size))
}

fn damaged<T>(file: &Path, why: impl std::fmt::Display) -> Result<T> {
    fail(format!("{} is damaged or isn't an update file ({why})", file.display()), DAMAGED)
}

/// Where the header after a member (data start, size) is: tar pads data to 512 bytes.
fn next((at, size): (u64, u64)) -> u64 { at + size.div_ceil(512) * 512 }

/// The name of the trusted key file in `keys` whose key verifies `sig` over `data`, if any.
/// Files that aren't keys are skipped.
fn verify(keys: &Path, data: &[u8], sig: &[u8]) -> Option<String> {
    let sig = Signature::from_bytes(sig.try_into().ok()?);
    let mut files: Vec<_> = std::fs::read_dir(keys).into_iter().flatten().flatten().map(|e| e.path()).collect();
    files.sort();
    let found = files.into_iter().find(|f| read_key(f).is_some_and(|k| k.verify_strict(data, &sig).is_ok()))?;
    Some(found.file_name()?.to_string_lossy().into())
}

/// The key in a key file: 64 hex characters (and maybe a line end).
fn read_key(path: &Path) -> Option<VerifyingKey> {
    let text = std::fs::read_to_string(path).ok()?;
    let text = text.trim();
    if text.len() != 64 { return None; }
    let bytes: Vec<u8> = (0..64).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect::<Option<_>>()?;
    VerifyingKey::from_bytes(&bytes.try_into().ok()?).ok()
}

/// Whether `v` is a version name as build-system.sh makes them: YYYYMMDD-HHMMSS-<commit>, with
/// -dirty for uncommitted changes. (It becomes a folder name, so nothing else may pass.)
fn valid_version(v: &str) -> bool {
    let digits = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_digit());
    let parts: Vec<&str> = v.strip_suffix("-dirty").unwrap_or(v).split('-').collect();
    matches!(parts.as_slice(), [date, time, commit] if digits(date, 8) && digits(time, 6)
        && (7..=40).contains(&commit.len()) && commit.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))
}

/// `brick-install update <file>`, in three steps: checking the update file, copying it into
/// `images/<version>/` (through `<version>.part/`, renamed once complete), then making it start
/// next (slots::activate). An older version is allowed (`list` marks it, so Specular can warn).
pub fn apply(p: &Paths, path: &Path, report: &mut Report) -> Result<String> {
    report.steps(3);
    report.step("Checking the update");
    let meta = std::fs::metadata(path).ctx(&format!("reading {}", path.display()))?;
    let mtime = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    report.log(&format!("update file {}: {} bytes, modified at {mtime} (seconds since 1970, UTC)", path.display(), meta.len()));
    let u = open(path, &p.keys)?;
    report.log(&format!("version {}, manifest sha256 {}, signed with {}", u.version, hex(&Sha256::digest(&u.manifest)), u.key));
    if u.version == p.version { return fail(format!("version {} is running now", u.version), "This update is already installed."); }
    // Version names start with the build date and time, so they sort by age.
    if u.version < p.version { report.log(&format!("older than the running version {}", p.version)); }
    let (_, parts, _, this) = slots::target(p, false, report)?;
    let other = slots::SLOTS[1 - this];
    let slot = disk::named(&parts, other, &p.running)?;
    if u.images[0].2 > slot.size {
        return fail(format!("boot.img of {} is bigger than boot slot {other} ({} bytes)", u.version, slot.size), "This update can't start from this disk.");
    }
    let images = p.system.join("images");
    let need: u64 = u.images.iter().map(|i| i.2).sum::<u64>() + SPARE;
    let free = install::free_bytes(&p.system) + leftovers(&images).iter().map(|d| install::dir_bytes(d)).sum::<u64>();
    report.log(&format!("system partition: {free} bytes free (counting copies cut short), {need} needed"));
    let have = complete(&images.join(&u.version), &u, report);
    if !have && free < need {
        // Only two versions are kept, so this takes a developer layer (overlay/) or an image built
        // bigger than the storage was made for; neither is something a user can clear.
        return fail(format!("the system storage has {} MB free; this update needs {} MB", free >> 20, need >> 20),
                    format!("There's no room for it here. To use this version, start from an SD card with it: {REWRITE_CARD}"));
    }
    install::battery_ok(&p.power, report)?;

    report.step("Copying the update");
    if have { report.log(&format!("version {} is in images/ already", u.version)); } else { copy(&images, &u, report)?; }

    report.step(&format!("Switching to version {}", u.version));
    slots::activate(p, &u.version, report)
}

/// Copies the update's files into `<images>/<version>/`, replacing anything there.
fn copy(images: &Path, u: &Update, report: &mut Report) -> Result<()> {
    let done = images.join(&u.version);
    for old in leftovers(images).into_iter().chain(done.exists().then(|| done.clone())) {
        report.log(&format!("deleting {}", old.display()));
        std::fs::remove_dir_all(&old).ctx(&format!("deleting {}", old.display()))?;
    }
    let part = images.join(format!("{}.part", u.version));
    let result = copy_into(&part, u, report).and_then(|()| {
        std::fs::rename(&part, &done).ctx(&format!("naming {}", done.display()))?;
        sync_dir(images)
    });
    if result.is_err() { let _ = std::fs::remove_dir_all(&part); }
    result
}

fn copy_into(dir: &Path, u: &Update, report: &mut Report) -> Result<()> {
    std::fs::create_dir_all(dir).ctx(&format!("making {}", dir.display()))?;
    let total: u64 = u.images.iter().map(|i| i.2).sum();
    let mut copied = 0;
    for (name, at, size, sha) in &u.images {
        let mut out = File::create(dir.join(name)).ctx(&format!("making {name}"))?;
        let mut h = Sha256::new();
        u.file.each_chunk(*at, *size, |off, c| {
            h.update(c);
            out.write_all(c).ctx(&format!("writing {name}"))?;
            report.progress(copied + off + c.len() as u64, total);
            Ok(())
        })?;
        out.sync_all().ctx(&format!("writing {name}"))?;
        copied += size;
        if hex(&h.finalize()) != *sha {
            return fail(format!("{} is damaged: {name} doesn't match its manifest", u.file.path.display()), DAMAGED);
        }
        report.log(&format!("{name}: {size} bytes, matches the manifest"));
    }
    for (name, data) in [("manifest.json", &u.manifest), ("manifest.sig", &u.sig)] {
        let mut out = File::create(dir.join(name)).ctx(&format!("making {name}"))?;
        out.write_all(data).and_then(|()| out.sync_all()).ctx(&format!("writing {name}"))?;
    }
    sync_dir(dir)
}

/// Whether `dir` holds this update's version completely: the same manifest, and files that match it.
fn complete(dir: &Path, u: &Update, report: &mut Report) -> bool {
    std::fs::read(dir.join("manifest.json")).is_ok_and(|m| m == u.manifest) && install::check_images(dir, report).is_ok()
}

/// Copies cut short (`*.part`) in `images`.
fn leftovers(images: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(images).into_iter().flatten().flatten().map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "part")).collect()
}

/// Makes a folder's entries (new and renamed files) reach the storage.
fn sync_dir(dir: &Path) -> Result<()> {
    File::open(dir).and_then(|d| d.sync_all()).ctx(&format!("flushing {}", dir.display()))
}

/// An update file found on the card.
pub struct Found {
    pub file: PathBuf,
    /// Its version; None if the file can't be read.
    pub version: Option<String>,
    /// Older than the running version (names sort by age).
    pub older: bool,
    /// Why it can't be used, if it can't.
    pub problem: Option<String>,
}

/// The update files in `<data>/updates/` (`*.update`), newest version first, those that can't
/// be read last. Only each file's manifest and signature are checked (`open`), not its contents'
/// hashes.
pub fn list(data: &Path, keys: &Path, running: &str) -> Vec<Found> {
    let mut found: Vec<Found> = std::fs::read_dir(data.join("updates")).into_iter().flatten().flatten().map(|e| e.path())
        .filter(|f| f.extension().is_some_and(|e| e == "update"))
        .map(|file| match open(&file, keys) {
            Ok(u) => Found { older: u.version.as_str() < running, problem: (u.version == running).then(|| "this version is running now".into()), version: Some(u.version), file },
            Err(e) => Found { file, version: None, older: false, problem: Some(e.message) },
        })
        .collect();
    found.sort_by(|a, b| b.version.cmp(&a.version));
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_build_version_names() {
        assert!(valid_version("20261018-212347-b3a6d97"));
        assert!(valid_version("20261018-212347-b3a6d97-dirty"));
        for bad in ["", "../x", "20261018-212347", "20261018-212347-B3A6D97", "2026101-212347-b3a6d97", "20261018-212347-b3a6d97/..", "20261018-212347-b3a6"] {
            assert!(!valid_version(bad), "{bad}");
        }
    }
}
