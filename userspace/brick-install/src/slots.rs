//! The two boot slots, boot_a and boot_b, on the disk the system runs from. U-Boot loads the one
//! its settings name (`boot_partition`) and tells the kernel which with `brick.boot=` on the
//! command line; each slot holds one version's boot.img, whose initramfs starts that version
//! (docs/boot.md). Making another version start next writes it to the slot not running, then
//! switches the settings (env::switch), so the running version stays the one that starts until
//! the settings are switched, and remains the one to go back to after that.
//!
//! What a slot holds needs no record of its own: it holds version V when its first bytes are V's
//! boot.img (the size and SHA-256 images/V/manifest.json gives); otherwise it is unknown.

use std::path::Path;

use sha2::{Digest, Sha256};

use crate::Paths;
use crate::cut;
use crate::disk::{self, Disk, Part};
use crate::env;
use crate::install;
use crate::report::{Context, Report, Result, SEE_LOG, fail, hex};

/// The boot slots' partition names, as U-Boot's `boot_partition` and `brick.boot=` give them.
pub const SLOTS: [&str; 2] = ["boot_a", "boot_b"];

/// What each slot holds: a version in images/, or None (unknown: no installed version matches).
pub type Holdings = [(&'static str, Option<String>); 2];

/// What each slot of `disk` (whose partitions are `parts`) holds, from the versions in
/// `<system>/images/`.
pub fn holdings(disk: &Disk, parts: &[Part], system: &Path) -> Result<Holdings> {
    let mut versions = installed(system);
    // Longest first: when one version's boot.img is the start of another's (test-installer.sh's
    // made-up versions do this; real builds don't), a slot holding the longer one isn't taken
    // for the shorter.
    versions.sort_by_key(|v| std::cmp::Reverse(v.1));
    let mut out: Holdings = SLOTS.map(|s| (s, None));
    for (slot, held) in out.iter_mut() {
        let part = disk::named(parts, slot, &disk.path)?;
        // The versions are sorted by size, so versions of the same size follow each other and
        // the last hash serves them all.
        let mut last: Option<(u64, String)> = None;
        for (version, size, sha) in &versions {
            if *size > part.size { continue; }
            if last.as_ref().is_none_or(|(s, _)| s != size) {
                last = Some((*size, hex(&Sha256::digest(disk.read_at(part.start, *size as usize)?))));
            }
            if last.as_ref().is_some_and(|(_, h)| h == sha) { *held = Some(version.clone()); break; }
        }
    }
    Ok(out)
}

/// The versions in `<system>/images/` (complete ones: not `*.part`), with their boot.img's size
/// and SHA-256 from their manifests.
fn installed(system: &Path) -> Vec<(String, u64, String)> {
    std::fs::read_dir(system.join("images")).into_iter().flatten().flatten().filter_map(|e| {
        let version = e.file_name().to_string_lossy().to_string();
        if version.ends_with(".part") { return None; }
        let m = crate::report::read_json(&e.path().join("manifest.json"), "").ok()?;
        let b = &m["files"]["boot.img"];
        Some((version, b["size"].as_u64()?, b["sha256"].as_str()?.to_string()))
    }).collect()
}

/// The slot the running system was started from (index into `held`): `--slot` if given, else
/// `brick.boot=` on the kernel command line; checked to hold the running version.
pub fn running(p: &Paths, held: &Holdings) -> Result<usize> {
    let slot = p.slot.clone().or_else(|| std::fs::read_to_string("/proc/cmdline").unwrap_or_default().split_whitespace()
        .find_map(|a| a.strip_prefix("brick.boot=").map(str::to_string)));
    let Some(slot) = slot else {
        return fail("the start-up settings don't say which boot slot started", "They were made for an older layout: write a fresh SD card, or install again from one.");
    };
    let Some(i) = SLOTS.iter().position(|s| *s == slot) else { return fail(format!("unknown boot slot {slot}"), SEE_LOG) };
    if held[i].1.as_deref() != Some(p.version.as_str()) {
        return fail(format!("boot slot {slot} doesn't hold the running version {}", p.version), "Nothing was changed. Restart the device, then try again.");
    }
    Ok(i)
}

/// Makes installed `version` (in `<system>/images/`) the one that starts next: checks its files
/// against its manifest, writes its boot.img to the slot not running (unless it holds it
/// already) and reads it back, switches the settings to that slot, then deletes the versions
/// (and their developer layers: overlay/<version>/, the writable layer of developer mode) other
/// than it and the running one. A developer layer on the running version gets an empty one for
/// `version`, so developer mode carries over (its files don't). Returns the closing message
/// (report.rs's DONE line). Activating the running version undoes an activate not yet followed
/// by a restart (`keep_running`).
pub fn activate(p: &Paths, version: &str, report: &mut Report) -> Result<String> {
    if version == p.version { return keep_running(p, report); }
    let dir = p.system.join("images").join(version);
    if version.ends_with(".part") || !dir.join("manifest.json").is_file() {
        return fail(format!("version {version} isn't installed"), "Choose a version from brick-install slots, or install an update.");
    }
    install::check_images(&dir, report)?;
    let (disk, parts, held, this) = target(p, true, report)?;
    let (other, slot) = (1 - this, SLOTS[1 - this]);
    if held[other].1.as_deref() == Some(version) {
        report.log(&format!("{slot} already holds {version}"));
    } else {
        // If an earlier activate wasn't followed by a restart, the settings already name the slot
        // about to be overwritten: point them back at the running slot first, so a power cut
        // mid-write never leaves them naming a half-written slot.
        if env::get(&env::current(&disk, &parts)?.0.pairs, "boot_partition") == Some(slot) {
            report.log(&format!("the settings name {slot}, about to be written: switching them to {} first", SLOTS[this]));
            env::switch(&disk, &parts, &[("boot_partition", SLOTS[this])], report)?;
        }
        let boot = std::fs::read(dir.join("boot.img")).ctx("reading boot.img")?;
        let part = disk::named(&parts, slot, &p.running)?;
        if boot.len() as u64 > part.size {
            return fail(format!("boot.img of {version} is bigger than boot slot {slot}"), "This version can't start from this disk.");
        }
        disk.write_checked(part.start, &boot, &format!("boot.img of {version} into {slot}"), report)?;
        cut::here("slot-written");
    }
    let overlay = p.system.join("overlay");
    if overlay.join(&p.version).is_dir() {
        std::fs::create_dir_all(overlay.join(version)).ctx("carrying the developer layer over")?;
    }
    env::switch(&disk, &parts, &[("boot_partition", slot)], report)?;
    // The settings now name the new slot: a version that can't be deleted is only logged (the next
    // activate tries again).
    for folder in [p.system.join("images"), overlay] {
        for e in std::fs::read_dir(&folder).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name != version && name != p.version {
                let result = std::fs::remove_dir_all(e.path()).map_or_else(|e| format!("failed: {e}"), |()| "done".into());
                report.log(&format!("deleting {}: {result}", e.path().display()));
            }
        }
    }
    unsafe { libc::sync() };
    Ok(format!("Version {version} starts at the next restart."))
}

/// Points the settings back at the running slot (if they name the other one), so the running
/// version starts next again; writes no slot and deletes nothing.
fn keep_running(p: &Paths, report: &mut Report) -> Result<String> {
    let (disk, parts, _, this) = target(p, true, report)?;
    if env::get(&env::current(&disk, &parts)?.0.pairs, "boot_partition") == Some(SLOTS[this]) {
        report.log(&format!("the settings already name {}", SLOTS[this]));
    } else {
        env::switch(&disk, &parts, &[("boot_partition", SLOTS[this])], report)?;
    }
    Ok(format!("Version {} is running, and stays the one that starts.", p.version))
}

/// The disk the system runs from (opened for writing if `write`), its partitions, what each slot
/// holds and which slot is running (an index into the holdings). Logs the holdings.
pub fn target(p: &Paths, write: bool, report: &mut Report) -> Result<(Disk, Vec<Part>, Holdings, usize)> {
    let disk = Disk::open(&p.running, write)?;
    let parts = disk.partitions()?;
    let held = holdings(&disk, &parts, &p.system)?;
    for (slot, version) in &held { report.log(&format!("{slot} holds {}", version.as_deref().unwrap_or("an unknown version"))); }
    let this = running(p, &held)?;
    Ok((disk, parts, held, this))
}

/// What `brick-install slots` prints: each slot with what it holds ("unknown" if no version in
/// images/ matches), labelled "running" or "previous" (the other slot, holding another version),
/// then the slot that starts next, from the settings copy U-Boot uses:
///   boot_a 20261018-212347-b3a6d97 running
///   boot_b 20261012-090000-1a2b3c4 previous
///   next boot_a
/// The labels are left out when the running slot can't be told (the reason goes to stderr).
pub fn describe(p: &Paths) -> Result<String> {
    let disk = Disk::open(&p.running, false)?;
    let parts = disk.partitions()?;
    let held = holdings(&disk, &parts, &p.system)?;
    let running = running(p, &held).inspect_err(|e| eprintln!("{}", e.message)).ok();
    let mut out = String::new();
    for (i, (slot, version)) in held.iter().enumerate() {
        let label = match running { Some(r) if r == i => " running", Some(_) if version.as_deref().is_some_and(|v| v != p.version) => " previous", _ => "" };
        out += &format!("{slot} {}{label}\n", version.as_deref().unwrap_or("unknown"));
    }
    let (next, _) = env::current(&disk, &parts)?;
    out += &format!("next {}\n", env::get(&next.pairs, "boot_partition").unwrap_or("unknown"));
    Ok(out)
}

/// For `offer`: the running slot (or null), and the previous version in the other slot
/// ({ "version", "slot" }, or null).
pub fn offer(p: &Paths) -> (serde_json::Value, serde_json::Value) {
    let Ok(held) = Disk::open(&p.running, false).and_then(|d| holdings(&d, &d.partitions()?, &p.system)) else { return Default::default() };
    let Ok(i) = running(p, &held) else { return Default::default() };
    let previous = match &held[1 - i].1 {
        Some(v) if *v != p.version => serde_json::json!({ "version": v, "slot": SLOTS[1 - i] }),
        _ => serde_json::Value::Null,
    };
    (SLOTS[i].into(), previous)
}
