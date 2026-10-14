//! Installing the system that runs from the SD card onto the internal storage (eMMC).
//!
//! Everything comes from the card the system runs from, so the internal storage starts exactly
//! what runs now: the boot area (first-stage loader and boot package), the bootloader partition
//! (a FAT filesystem holding the boot logo), the boot image of the running version, and a new system partition holding that version's files
//! (images/<version>/) and the state (saved WiFi networks, Bluetooth pairings). Then everything
//! written is read back and checked, and the card's first-stage loader is erased (unless asked
//! not to), so the device starts from the internal storage: the boot ROM tries the card first.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::backup;
use crate::disk::{self, Disk, SECTOR};
use crate::env;
use crate::report::{Context, Report, Result, SEE_LOG, fail, gb, read_json};

/// The internal storage's partitions, in sectors (start, size; None: the rest of the disk).
/// TrimUI's first four exactly where its own eMMC layout has them, as the only layout known to
/// start from the eMMC (they start 1024 sectors later than on an SD card), then our system
/// partition over everything after them.
const LAYOUT: [(&str, u64, Option<u64>); 5] = [
    ("bootloader", 41984, Some(49152)),
    ("env", 91136, Some(1024)),
    ("env-redund", 92160, Some(1024)),
    ("boot", 93184, Some(49152)),
    ("system", 142336, None),
];
/// The boot area, in sectors (first, end exclusive): from the first-stage loader (boot0, at 16; its copy at 256) up to
/// where the card's partitions start, including the boot package at 32800. Copied from the card
/// as it is (the boot ROM and the first-stage loader read the same places on both disks).
const BOOT_AREA: (u64, u64) = (16, 40960);
/// The part of the boot area erased on the card so it no longer starts, in sectors (first, end
/// exclusive): both copies of boot0, up to the boot package.
const CARD_BOOT0: (u64, u64) = (16, 32800);
/// The smallest internal storage the system fits on (the boot partitions, then 1 GiB).
const MIN_SIZE: u64 = 142336 * SECTOR + (1 << 30);

/// Where things are; on the device all are found by `Paths::find`, and any can be given instead
/// (e.g. image files and folders on a PC, for tests).
pub struct Paths {
    /// The internal storage (a disk device, or an image file).
    pub target: PathBuf,
    /// The disk the system runs from (the SD card).
    pub source: PathBuf,
    /// The running system's partition (images/, state/), mounted.
    pub system: PathBuf,
    /// The card's data partition (backups/, logs/).
    pub data: PathBuf,
    /// The running system's version.
    pub version: String,
}

pub struct Options { pub backup: bool, pub keep_card_bootable: bool, pub dry_run: bool }

/// The installation, step by step.
pub fn install(p: &Paths, o: &Options, report: &mut Report) -> Result<String> {
    report.steps(if o.backup { 6 } else { 5 });
    report.step("Checking");
    let source = Disk::open(&p.source, !o.dry_run && !o.keep_card_bootable)?;
    let target = Disk::open(&p.target, !o.dry_run)?;
    let card = disk::partitions(&p.source, report)?;
    let (card_boot, card_env) = (disk::named(&card, "bootloader", &p.source)?, disk::named(&card, "env", &p.source)?);
    report.log(&format!("installing version {} from {} onto {} ({} bytes)", p.version, p.source.display(), p.target.display(), target.size));
    if p.source == p.target { return fail("the internal storage is the disk the system runs from", "Start the device from an SD card to install."); }
    if target.size < MIN_SIZE { return fail(format!("the internal storage holds only {}", gb(target.size)), format!("The system needs at least {}.", gb(MIN_SIZE))); }
    battery_ok()?;
    let images = p.system.join("images").join(&p.version);
    let manifest = check_images(&images, report)?;
    if o.backup { backup_room(&p.data, target.size)?; }

    if o.backup {
        report.step("Backing up the internal storage");
        if o.dry_run { report.log("dry run: no backup made"); } else { backup::make(&target, &p.data, report)?; }
    }

    report.step("Partitioning the internal storage");
    let script = layout_script(target.size);
    report.log(&format!("partition table:\n{script}"));
    if !o.dry_run { sfdisk(&p.target, &script, report)?; }

    report.step("Writing the start-up files");
    let uuid = std::fs::read_to_string("/proc/sys/kernel/random/uuid").ctx("making a filesystem UUID")?.trim().to_string();
    let settings = env::set(&source.read_at(card_env.start, env::SIZE)?, "mmc_root", &format!("UUID={uuid}"))?;
    let boot_img = std::fs::read(images.join("boot.img")).ctx("reading boot.img")?;
    let (boot_area, bootloader) = (bytes(BOOT_AREA), part("bootloader"));
    if bootloader.1 < card_boot.size { return fail("the card's bootloader partition doesn't fit the internal storage's", SEE_LOG); }
    if boot_img.len() as u64 > part("boot").1 { return fail("boot.img doesn't fit the internal storage's boot partition", SEE_LOG); }
    if !o.dry_run {
        source.copy_to(boot_area.0, &target, boot_area.0, boot_area.1, report)?;
        source.copy_to(card_boot.start, &target, bootloader.0, card_boot.size, report)?;
        target.write_at(part("env").0, &settings)?;
        target.write_at(part("env-redund").0, &settings)?;
        target.write_at(part("boot").0, &boot_img)?;
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
        same("boot image", target.read_at(part("boot").0, boot_img.len())?, boot_img)?;
        check_system(&p.target, system.0, &p.version, &manifest, report)?;
    }

    if o.keep_card_bootable {
        report.log("the card stays bootable, as asked: the device keeps starting from it while it is in");
    } else if !o.dry_run {
        source.zero(CARD_BOOT0.0 * SECTOR, (CARD_BOOT0.1 - CARD_BOOT0.0) * SECTOR)?;
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

fn bytes((from, to): (u64, u64)) -> (u64, u64) { (from * SECTOR, (to - from) * SECTOR) }

/// sfdisk's script for `LAYOUT` on a disk of `size` bytes. 16 table entries, so the table (sectors
/// 2 to 5) ends before the boot area.
fn layout_script(size: u64) -> String {
    // The last 33 sectors stay free for the backup table: its header, and room for a standard
    // 128-entry table (sfdisk's default; ours needs only 4).
    let last = size / SECTOR - 34;
    let mut s = format!("label: gpt\ntable-length: 16\nfirst-lba: {}\nlast-lba: {last}\n", LAYOUT[0].1);
    for (name, start, len) in LAYOUT {
        let len = len.unwrap_or(last + 1 - start);
        // Linux filesystem type, as TrimUI's: U-Boot finds partitions by name.
        s += &format!("start={start}, size={len}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name={name}\n");
    }
    s
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

/// Checks the running version's files against its manifest; returns the manifest.
fn check_images(dir: &Path, report: &mut Report) -> Result<serde_json::Value> {
    let m = read_json(&dir.join("manifest.json"), "the system's manifest")?;
    for (name, f) in m["files"].as_object().into_iter().flatten() {
        let mut sha = Sha256::new();
        let file = Disk::open(&dir.join(name), false)?;
        file.each_chunk(0, file.size, |_, c| { sha.update(c); Ok(()) })?;
        if backup::hex(&sha.finalize()) != f["sha256"].as_str().unwrap_or_default() {
            return fail(format!("{name} of the running system doesn't match its manifest"), "The SD card's system is damaged: write a fresh card.");
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
        let sha = backup::hex(&Sha256::digest(&out.stdout));
        if sha != f["sha256"].as_str().unwrap_or_default() {
            return fail(format!("{path} on the internal storage doesn't read back as written"), "Try installing again; if it fails again, the internal storage may be failing.");
        }
        report.log(&format!("  {path}: matches the manifest"));
    }
    Ok(())
}

/// Refuses to install on a battery under half full, unless charging. (No battery: a PC.)
fn battery_ok() -> Result<()> {
    let Some(bat) = std::fs::read_dir("/sys/class/power_supply").into_iter().flatten().flatten()
        .map(|e| e.path()).find(|p| std::fs::read_to_string(p.join("type")).is_ok_and(|t| t.trim() == "Battery")) else { return Ok(()) };
    let read = |f: &str| std::fs::read_to_string(bat.join(f)).unwrap_or_default().trim().to_string();
    let (level, status) = (read("capacity").parse::<u32>().unwrap_or(100), read("status"));
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
        let s = layout_script(15269888 * SECTOR); // this Brick's eMMC
        assert!(s.contains("table-length: 16") && s.contains("first-lba: 41984") && s.contains("last-lba: 15269854"));
        assert!(s.contains("start=93184, size=49152, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=boot"));
        assert!(s.contains("start=142336, size=15127519, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=system"));
        assert!(2 + 16 * 128 / 512 <= BOOT_AREA.0); // the table's entries end before boot0
    }
}
