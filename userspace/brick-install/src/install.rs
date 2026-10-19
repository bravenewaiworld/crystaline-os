//! Installing the system that runs from the SD card onto the internal storage (eMMC).
//!
//! Everything comes from the card the system runs from, so the internal storage starts exactly
//! what runs now: the boot area (first-stage loader and boot package), the bootloader partition
//! (a FAT filesystem holding the boot logo), U-Boot's settings, the boot image of the running
//! version (into boot slot A), and a new system partition holding that version's files
//! (images/<version>/) and the state (saved WiFi networks, Bluetooth pairings). Then everything
//! written is read back and checked, and the card's first-stage loader is erased (unless asked
//! not to), so the device starts from the internal storage: the boot ROM tries the card first.
//!
//! An install (or a restore, backup.rs) cut short, e.g. by a power cut, must be told apart from a
//! finished one: while it writes, the sector of the partition table's header holds a marker
//! (`INSTALLING`, `RESTORING`) instead, and the partition table is written last (everything else
//! is written at known places, without it). `holds` tells these states apart. Until the very end the card
//! still starts the device, so a cut-short install can simply be run again.

use std::path::Path;

use sha2::{Digest, Sha256};

use crate::Paths;
use crate::backup;
use crate::disk::{self, Disk, SECTOR};
use crate::env;
use crate::report::{Context, Report, Result, SEE_LOG, fail, gb, hex, read_json};

/// The internal storage's partitions, in sectors (start, size; None: the rest of the disk).
/// TrimUI's first four stay exactly where its own eMMC layout has them (its "boot" is our boot_a):
/// it is the only layout known to start from the eMMC. That is why they start 1024 sectors later
/// than on our SD card, and why the two settings copies sit side by side here rather than in
/// separate 4 MiB units as on the card. Then boot slot B, the kernel's crash records (pstore),
/// and our system partition over the rest.
const LAYOUT: [(&str, u64, Option<u64>); 7] = [
    ("bootloader", 41984, Some(49152)),
    ("env", 91136, Some(1024)),
    ("env-redund", 92160, Some(1024)),
    ("boot_a", 93184, Some(49152)),
    ("boot_b", 142336, Some(49152)),
    ("pstore", 191488, Some(2048)),
    ("system", 193536, None),
];
/// The boot area, in sectors (first, end exclusive): from the first-stage loader (boot0, at 16;
/// its copy at 256) up to where the card's partitions start, including the boot package at 32800. Copied from the card
/// as it is (the boot ROM and the first-stage loader read the same places on both disks).
const BOOT_AREA: (u64, u64) = (16, 40960);
/// The part of the boot area erased on the card so it no longer starts, in sectors (first, end
/// exclusive): both copies of boot0, up to the boot package. A prepared restore writes it back
/// (backup.rs).
pub const CARD_BOOT0: (u64, u64) = (16, 32800);
/// The marker in the partition table's header sector while an install writes (see the top of
/// this file).
pub const INSTALLING: &[u8] = b"BRICK-INSTALLING";
/// The marker while a restore writes (backup.rs).
pub const RESTORING: &[u8] = b"BRICK-RESTORING";

/// The smallest internal storage the system fits on (the partitions before the system
/// partition, then 1 GiB).
const MIN_SIZE: u64 = LAYOUT[LAYOUT.len() - 1].1 * SECTOR + (1 << 30);

/// The install's options (main.rs's usage).
pub struct Options { pub backup: bool, pub keep_card_bootable: bool, pub dry_run: bool }

/// `brick-install install`: the steps in docs/install-and-update.md ("Install steps"). Returns the
/// closing message (the DONE line).
pub fn install(p: &Paths, o: &Options, report: &mut Report) -> Result<String> {
    report.steps(if o.backup { 6 } else { 5 });
    report.step("Checking");
    if !p.on_card() { return fail("the system isn't running from an SD card", "Start the device from an SD card to install."); }
    let (source_path, target_path) = (p.card()?, p.internal()?);
    let source = Disk::open(source_path, !o.dry_run && !o.keep_card_bootable)?;
    let target = Disk::open(target_path, !o.dry_run)?;
    let card = source.partitions()?;
    let card_boot = disk::named(&card, "bootloader", source_path)?;
    report.log(&format!("installing version {} from {} onto {} ({} bytes, holding {})", p.version, source_path.display(), target_path.display(), target.size, holds(&target)));
    if target.size < MIN_SIZE { return fail(format!("the internal storage holds only {}", gb(target.size)), format!("The system needs at least {}.", gb(MIN_SIZE))); }
    battery_ok(&p.power, report)?;
    let images = p.system.join("images").join(&p.version);
    let manifest = check_images(&images, report)?;
    if o.backup { backup_room(&p.data, target.size)?; }

    if o.backup {
        report.step("Backing up the internal storage");
        if o.dry_run { report.log("dry run: no backup made"); } else { backup::make(&target, &p.data, report)?; }
    }

    report.step("Writing the start-up files");
    if !o.dry_run { mark(&target, INSTALLING)?; }
    let (uuid, pstore_uuid) = (new_uuid()?, new_uuid()?);
    // The card's settings, as U-Boot uses them, pointed at the internal storage's partitions;
    // the same in both copies.
    let (card_settings, state) = env::current(&source, &card)?;
    report.log(&state);
    let changes = [("mmc_root", &*format!("UUID={uuid}")), ("boot_partition", "boot_a"), ("blkoops_blkdev", &*format!("PARTUUID={pstore_uuid}"))];
    let settings = env::encode(&card_settings.pairs, &changes, card_settings.flags)?;
    let boot_img = std::fs::read(images.join("boot.img")).ctx("reading boot.img")?;
    let (boot_area, bootloader, pstore) = (bytes(BOOT_AREA), part("bootloader"), part("pstore"));
    if bootloader.1 < card_boot.size { return fail("the card's bootloader partition doesn't fit the internal storage's", SEE_LOG); }
    if boot_img.len() as u64 > part("boot_a").1 { return fail("boot.img doesn't fit the internal storage's boot slots", SEE_LOG); }
    if !o.dry_run {
        source.copy_to(boot_area.0, &target, boot_area.0, boot_area.1, report)?;
        source.copy_to(card_boot.start, &target, bootloader.0, card_boot.size, report)?;
        target.write_at(part("env").0, &settings)?;
        target.write_at(part("env-redund").0, &settings)?;
        target.write_at(part("boot_a").0, &boot_img)?;
        // TrimUI's data would otherwise sit where the kernel looks for crash records.
        target.zero(pstore.0, pstore.1)?;
        target.sync()?;
    }

    report.step("Writing the system");
    let system = part("system");
    if !o.dry_run { write_system(p, &target, system, &uuid, report)?; }

    report.step("Checking the internal storage");
    if !o.dry_run {
        let same = |what: &str, a: Vec<u8>, b: Vec<u8>| if a == b { Ok(()) } else { fail(format!("the internal storage's {what} doesn't read back as written"), "Try installing again; if it fails again, the internal storage may be failing.") };
        same("boot area", target.read_at(boot_area.0, boot_area.1 as usize)?, source.read_at(boot_area.0, boot_area.1 as usize)?)?;
        same("bootloader partition", target.read_at(bootloader.0, card_boot.size as usize)?, source.read_at(card_boot.start, card_boot.size as usize)?)?;
        same("U-Boot settings", target.read_at(part("env").0, env::SIZE)?, settings.clone())?;
        same("U-Boot settings (copy)", target.read_at(part("env-redund").0, env::SIZE)?, settings)?;
        same("boot image", target.read_at(part("boot_a").0, boot_img.len())?, boot_img)?;
        same("crash record partition", target.read_at(pstore.0, pstore.1 as usize)?, vec![0; pstore.1 as usize])?;
        check_system(target_path, system.0, &p.version, &manifest, report)?;
    }

    report.step("Finishing");
    let script = layout_script(target.size, &pstore_uuid);
    report.log(&format!("partition table:\n{script}"));
    if !o.dry_run {
        sfdisk(target_path, &script, report)?;
        let parts = target.partitions()?;
        for (name, ..) in LAYOUT {
            let (start, size) = part(name);
            if !disk::named(&parts, name, target_path).is_ok_and(|q| q.start == start && (size == 0 || q.size == size)) {
                return fail(format!("the internal storage's partition {name} doesn't read back as written"), "Try installing again; if it fails again, the internal storage may be failing.");
            }
        }
    }
    if o.keep_card_bootable {
        report.log("the card stays bootable, as asked: the device keeps starting from it while it is in");
    } else if !o.dry_run {
        let (from, len) = bytes(CARD_BOOT0);
        source.zero(from, len)?;
        source.sync()?;
        report.log("erased the card's first-stage loader: the device now starts from the internal storage");
    }
    Ok(if o.dry_run { "Dry run: nothing was written.".into() }
       else if o.keep_card_bootable { format!("Installed version {}. The device still starts from the SD card while it's in: remove it to start from the internal storage.", p.version) }
       else { format!("Installed version {}. Restart to start from the internal storage.", p.version) })
}

/// The internal storage's partition `name` (from `LAYOUT`): start and size in bytes. (The system
/// partition's size isn't known here; its size is 0.)
fn part(name: &str) -> (u64, u64) {
    let (_, start, size) = LAYOUT.iter().find(|(n, ..)| *n == name).unwrap();
    (start * SECTOR, size.unwrap_or(0) * SECTOR)
}

/// A range of sectors (first, end exclusive) as bytes (start, length).
pub fn bytes((from, to): (u64, u64)) -> (u64, u64) { (from * SECTOR, (to - from) * SECTOR) }

/// sfdisk's script for `LAYOUT` on a disk of `size` bytes, the pstore partition with GPT UUID
/// `pstore_uuid` (U-Boot's settings name it by that). 16 table entries, so the table (sectors 2
/// to 5) ends before the boot area.
fn layout_script(size: u64, pstore_uuid: &str) -> String {
    // The last 33 sectors stay free for the backup table: its header, and room for a standard
    // 128-entry table (sfdisk's default; ours needs only 7).
    let last = size / SECTOR - 34;
    let mut s = format!("label: gpt\ntable-length: 16\nfirst-lba: {}\nlast-lba: {last}\n", LAYOUT[0].1);
    for (name, start, len) in LAYOUT {
        let len = len.unwrap_or(last + 1 - start);
        // Linux filesystem type, as TrimUI's: U-Boot finds partitions by name.
        let uuid = if name == "pstore" { format!(", uuid={pstore_uuid}") } else { String::new() };
        s += &format!("start={start}, size={len}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name={name}{uuid}\n");
    }
    s
}

/// What the internal storage holds, for the user and the log: "trimui" (TrimUI's system),
/// "this-system" (installed by us), "unfinished-install", "unfinished-restore" (see the top of
/// this file), or "unknown". Read from its partition table: its header's sector, and the names.
pub fn holds(disk: &Disk) -> &'static str {
    let Ok(header) = disk.read_at(SECTOR, SECTOR as usize) else { return "unknown" };
    if header.starts_with(INSTALLING) { return "unfinished-install"; }
    if header.starts_with(RESTORING) { return "unfinished-restore"; }
    // TrimUI's layout has a partition named UDISK; ours has one named system.
    let names: Vec<String> = disk.partitions().unwrap_or_default().into_iter().map(|p| p.name).collect();
    if names.iter().any(|n| n == "system") { "this-system" } else if names.iter().any(|n| n == "UDISK") { "trimui" } else { "unknown" }
}

/// A new random UUID.
fn new_uuid() -> Result<String> {
    Ok(std::fs::read_to_string("/proc/sys/kernel/random/uuid").ctx("making a UUID")?.trim().to_string())
}

/// Writes `marker` over the partition table's header (see the top of this file).
pub fn mark(disk: &Disk, marker: &[u8]) -> Result<()> {
    let mut sector = vec![0; SECTOR as usize];
    sector[..marker.len()].copy_from_slice(marker);
    disk.write_at(SECTOR, &sector)?;
    disk.sync()
}

/// Writes a partition table with sfdisk from `script`.
fn sfdisk(target: &Path, script: &str, report: &mut Report) -> Result<()> {
    use std::io::Write;
    report.log(&format!("$ sfdisk --quiet --wipe never --no-reread --no-tell-kernel {}", target.display()));
    let mut child = std::process::Command::new("sfdisk").args(["--quiet", "--wipe", "never", "--no-reread", "--no-tell-kernel"]).arg(target)
        .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped())
        .spawn().ctx("starting sfdisk")?;
    child.stdin.take().unwrap().write_all(script.as_bytes()).ctx("writing the partition table")?;
    let out = child.wait_with_output().ctx("writing the partition table")?;
    for line in String::from_utf8_lossy(&out.stderr).lines() { report.log(&format!("  {line}")); }
    if out.status.success() { Ok(()) } else { fail(format!("sfdisk failed: {}", out.status), SEE_LOG) }
}

/// Makes the system partition's filesystem from a folder staged on the running system's partition:
/// images/<version>/ (links to the running version's files, so nothing is copied twice), a copy
/// of state/, and logs/. The mke2fs options are tools/system/mkfs-system.sh's (keep them in step),
/// plus where on the disk the partition starts.
fn write_system(p: &Paths, target: &Disk, (start, _): (u64, u64), uuid: &str, report: &mut Report) -> Result<()> {
    let stage = p.system.join(".install");
    let _ = std::fs::remove_dir_all(&stage);
    let images = stage.join("images").join(&p.version);
    std::fs::create_dir_all(&images).and_then(|()| std::fs::create_dir_all(stage.join("logs"))).ctx("staging the system")?;
    for f in ["boot.img", "rootfs.squashfs", "manifest.json"] {
        std::fs::hard_link(p.system.join("images").join(&p.version).join(f), images.join(f)).ctx(&format!("staging {f}"))?;
    }
    if p.system.join("state").is_dir() {
        report.run("cp", &["-a", &p.system.join("state").to_string_lossy(), &stage.to_string_lossy()])?;
    }
    if let Some(log) = &report.log_path { let _ = std::fs::copy(log, stage.join("logs").join("install.log")); }
    let size_k = (target.size - start - 34 * SECTOR) / 1024;
    let result = report.run("mke2fs", &["-q", "-F", "-t", "ext4", "-O", "^orphan_file", "-L", "brick-system", "-U", uuid,
        "-d", &stage.to_string_lossy(), "-E", &format!("offset={start},root_owner=0:0"), &target.path.to_string_lossy(), &format!("{size_k}k")]);
    let _ = std::fs::remove_dir_all(&stage);
    result.map(|_| ())
}

/// Refuses a version whose kernel doesn't make our device-tree changes itself (its manifest lacks
/// `"dt_edits": true`, which build-system.sh writes), for installs, activations and update files.
/// The boot packages we write are TrimUI's, unchanged, so such a version would start without its
/// buttons, internal storage or CPU voltage control. Devices installed before 2026-10-18 would
/// still run it (their boot package has the changes), but get the same refusal: one rule for
/// every device.
pub fn require_dt_edits(manifest: &serde_json::Value) -> Result<()> {
    if manifest["dt_edits"] == true { return Ok(()); }
    fail(format!("version {} is too old: its kernel doesn't make the device-tree changes itself",
                 manifest["version"].as_str().unwrap_or("(unnamed)")), "Choose a newer version.")
}

/// Checks a version's files (in `dir`, images/<version>/) against its manifest; returns the
/// manifest.
pub fn check_images(dir: &Path, report: &mut Report) -> Result<serde_json::Value> {
    let m = read_json(&dir.join("manifest.json"), "the system's manifest")?;
    require_dt_edits(&m)?;
    for (name, f) in m["files"].as_object().into_iter().flatten() {
        let mut sha = Sha256::new();
        let file = Disk::open(&dir.join(name), false)?;
        file.each_chunk(0, file.size, |_, c| { sha.update(c); Ok(()) })?;
        if hex(&sha.finalize()) != f["sha256"].as_str().unwrap_or_default() {
            return fail(format!("{name} of version {} doesn't match its manifest", dir.file_name().unwrap_or_default().to_string_lossy()),
                        "The system partition is damaged: write a fresh SD card.");
        }
        report.log(&format!("{name}: matches the manifest"));
    }
    Ok(m)
}

/// Checks the new system partition (at byte `start` of `target`): e2fsck finds nothing wrong, and
/// its image files read back (through debugfs, which reads a filesystem without mounting it)
/// match the manifest.
fn check_system(target: &Path, start: u64, version: &str, manifest: &serde_json::Value, report: &mut Report) -> Result<()> {
    let at = format!("{}?offset={start}", target.display());
    report.run("e2fsck", &["-fn", &at])?;
    for (name, f) in manifest["files"].as_object().into_iter().flatten() {
        let path = format!("/images/{version}/{name}");
        report.log(&format!("$ debugfs -R 'cat {path}' {at}"));
        let out = std::process::Command::new("debugfs").args(["-R", &format!("cat {path}"), &at]).output().ctx("starting debugfs")?;
        let sha = hex(&Sha256::digest(&out.stdout));
        if sha != f["sha256"].as_str().unwrap_or_default() {
            return fail(format!("{path} on the internal storage doesn't read back as written"), "Try installing again; if it fails again, the internal storage may be failing.");
        }
        report.log(&format!("  {path}: matches the manifest"));
    }
    Ok(())
}

/// Refuses a task that must not be cut short on a battery under half full, unless charging.
/// `power`: the kernel's power supplies (sysfs's power_supply class); no battery there: a PC.
pub fn battery_ok(power: &Path, report: &mut Report) -> Result<()> {
    let Some(bat) = std::fs::read_dir(power).into_iter().flatten().flatten()
        .map(|e| e.path()).find(|p| std::fs::read_to_string(p.join("type")).is_ok_and(|t| t.trim() == "Battery")) else {
        report.log(&format!("no battery in {}", power.display()));
        return Ok(());
    };
    let read = |f: &str| std::fs::read_to_string(bat.join(f)).unwrap_or_default().trim().to_string();
    let (level, status) = (read("capacity").parse::<u32>().unwrap_or(100), read("status"));
    report.log(&format!("battery: {level} %, {status}"));
    if level >= 50 || matches!(status.as_str(), "Charging" | "Full") { return Ok(()); }
    fail(format!("the battery is at {level} %"), "Connect the charger, or charge to at least 50 %, then try again.")
}

/// Refuses a backup the card's data partition has no room for: as much as the internal storage
/// holds, since how well it compresses isn't known beforehand.
pub fn backup_room(data: &Path, need: u64) -> Result<()> {
    let free = free_bytes(data);
    if free >= need { return Ok(()); }
    fail(format!("a backup needs {} on the SD card, {} is free", gb(need), gb(free)), "Free some space on the card, or install without a backup.")
}

/// The total size of the files directly in `dir` (not in its subfolders).
pub fn dir_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir).into_iter().flatten().flatten().filter_map(|f| f.metadata().ok()).map(|m| m.len()).sum()
}

/// The free space on the filesystem holding `path` (0 if it can't be read).
pub fn free_bytes(path: &Path) -> u64 {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap_or_default();
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut s) } != 0 { return 0; }
    s.f_bavail as u64 * s.f_frsize as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_layout_keeps_trimuis_first_partitions_and_the_table_before_the_boot_area() {
        let s = layout_script(15269888 * SECTOR, "U"); // this Brick's eMMC
        assert!(s.contains("table-length: 16") && s.contains("first-lba: 41984") && s.contains("last-lba: 15269854"));
        assert!(s.contains("start=93184, size=49152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=boot_a\n"));
        assert!(s.contains("start=191488, size=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=pstore, uuid=U\n"));
        assert!(s.contains("start=193536, size=15076319, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=system\n"));
        // Each partition starts where the one before it ends.
        assert!(LAYOUT.windows(2).all(|w| w[0].1 + w[0].2.unwrap() == w[1].1));
        assert!(2 + 16 * 128 / 512 <= BOOT_AREA.0); // the table's entries end before boot0
    }
}
