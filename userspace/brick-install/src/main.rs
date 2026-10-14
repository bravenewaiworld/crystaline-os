//! brick-install: installs the system running from the SD card onto the internal storage (eMMC),
//! optionally backing the internal storage up to the card first, and puts such a backup back.
//! Specular runs it from its Settings and shows its progress (see report.rs for what it prints);
//! it also runs on a PC against image files and folders, which is how
//! tools/system/test-installer.sh tests it.
//!
//! Usage:
//!   brick-install offer                  what can be done now, as JSON (see `offer`)
//!   brick-install install [--backup] [--keep-card-bootable] [--dry-run]
//!   brick-install restore <backup folder>
//! On the device everything is found by itself; any of these can be given instead:
//!   --target <disk or file>  --source <disk or file>  --system <folder>  --data <folder>
//!   --version <version>
//! The log goes to logs/ on the card's data partition.

mod backup;
mod disk;
mod env;
mod install;
mod report;

use std::path::{Path, PathBuf};

use install::{Options, Paths};
use report::{Report, Result, fail};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut flag = |name: &str| args.iter().position(|a| a == name).map(|i| args.remove(i)).is_some();
    let o = Options { backup: flag("--backup"), keep_card_bootable: flag("--keep-card-bootable"), dry_run: flag("--dry-run") };
    let mut value = |name: &str| args.iter().position(|a| a == name).filter(|&i| i + 1 < args.len())
        .map(|i| { args.remove(i); args.remove(i) });
    let paths = Paths::find(|name| value(name));
    let data = paths.as_ref().ok().map(|p| p.data.join("logs"));
    let code = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["offer"] => { println!("{}", offer(&paths)); 0 }
        ["install"] => run(data.as_deref(), "install", |r| install::install(paths.as_ref().map_err(Clone::clone)?, &o, r)),
        ["restore", dir] => run(data.as_deref(), "restore", |r| restore(paths.as_ref().map_err(Clone::clone)?, Path::new(dir), r)),
        _ => { eprintln!("usage: brick-install offer | install [--backup] [--keep-card-bootable] [--dry-run] | restore <backup folder>"); 2 }
    };
    std::process::exit(code);
}

/// Runs an action, reporting its end; the exit status is 0 if it succeeded.
fn run(logs: Option<&Path>, name: &str, f: impl FnOnce(&mut Report) -> Result<String>) -> i32 {
    let mut report = Report::new(logs, name);
    match f(&mut report) {
        Ok(message) => { report.done(&message); 0 }
        Err(e) => { report.failed(&e); 1 }
    }
}

fn restore(p: &Paths, dir: &Path, report: &mut Report) -> Result<String> {
    if !p.source.exists() || p.source == p.target { return fail("not running from an SD card", "Start the device from an SD card to restore."); }
    let target = disk::Disk::open(&p.target, true)?;
    report.steps(backup::RESTORE_STEPS);
    backup::restore(dir, &target, report)?;
    Ok("Restored the internal storage. Power off, remove the SD card, then turn the device on.".into())
}

/// What can be done now, for Specular's settings:
///   { "install": null, or { "bytes": the internal storage's size,
///                           "backup": { "possible", "free" (bytes on the data partition) } },
///     "why_not": why installing isn't possible (with "install": null),
///     "backups": [{ "dir", "created", "bytes" }] (complete ones on the card, newest first) }
/// Installing (and restoring) is possible only while the system runs from an SD card, on a
/// device with internal storage. A backup needs as much free space as the internal storage holds.
fn offer(paths: &Result<Paths>) -> serde_json::Value {
    let p = match paths {
        Ok(p) => p,
        Err(e) => return serde_json::json!({ "install": null, "why_not": e.message, "backups": [] }),
    };
    let backups: Vec<_> = backup::list(&p.data).iter()
        .map(|b| serde_json::json!({ "dir": b.dir, "created": b.created, "bytes": b.bytes })).collect();
    match disk::Disk::open(&p.target, false) {
        Ok(t) => {
            let free = install::free_bytes(&p.data);
            serde_json::json!({ "install": { "bytes": t.size, "backup": { "possible": free >= t.size, "free": free } }, "backups": backups })
        }
        Err(e) => serde_json::json!({ "install": null, "why_not": e.message, "backups": backups }),
    }
}

impl Paths {
    /// The paths given (by option name, e.g. "--target"), the rest found on the device: the
    /// internal storage is the disk on the
    /// eMMC controller (sdc2); the system runs from the disk holding /system, which must be the
    /// SD card (on sdc0); the data partition is at /mnt/SDCARD; the version is /etc/brick-version.
    fn find(mut given: impl FnMut(&str) -> Option<String>) -> Result<Self> {
        let (target, source, system, data, version) = (given("--target"), given("--source"), given("--system"), given("--data"), given("--version"));
        let system = PathBuf::from(system.unwrap_or_else(|| "/system".into()));
        let source = match source {
            Some(s) => PathBuf::from(s),
            None => {
                let mounts = std::fs::read_to_string("/proc/mounts").unwrap_or_default();
                let dev = mounts.lines().find_map(|l| { let mut f = l.split(' '); let d = f.next()?; (f.next()? == "/system").then(|| d.to_string()) });
                let Some(dev) = dev else { return fail("the system partition isn't mounted", "Start the device from an SD card written for this system.") };
                let disk = dev.trim_end_matches(|c: char| c.is_ascii_digit()).trim_end_matches('p').to_string();
                let name = disk.trim_start_matches("/dev/");
                if disk_on("sdc0").as_deref() != Some(name) { return fail("the system isn't running from an SD card", "Start the device from an SD card to install."); }
                PathBuf::from(disk)
            }
        };
        let target = match target {
            Some(t) => PathBuf::from(t),
            None => match disk_on("sdc2") {
                Some(name) => PathBuf::from(format!("/dev/{name}")),
                None => return fail("this device's internal storage isn't available", "This system can't reach the internal storage: its device tree must enable it (system/board/brick/dt-tweaks.sh)."),
            },
        };
        let version = match version {
            Some(v) => v,
            None => std::fs::read_to_string("/etc/brick-version").map(|v| v.trim().to_string())
                .map_err(|e| report::Failure { message: format!("reading /etc/brick-version: {e}"), hint: "The SD card's system is damaged: write a fresh card.".into() })?,
        };
        Ok(Self { target, source, system, data: PathBuf::from(data.unwrap_or_else(|| "/mnt/SDCARD".into())), version })
    }
}

/// The disk (e.g. "mmcblk0") on the storage controller `controller` (a platform device: sdc0 is
/// the SD card's, sdc2 the eMMC's), if any.
fn disk_on(controller: &str) -> Option<String> {
    let hosts = std::fs::read_dir(format!("/sys/bus/platform/devices/{controller}/mmc_host")).ok()?;
    for host in hosts.flatten() {
        for card in std::fs::read_dir(host.path()).ok()?.flatten() {
            if let Ok(disks) = std::fs::read_dir(card.path().join("block"))
                && let Some(d) = disks.flatten().next() { return Some(d.file_name().to_string_lossy().into()); }
        }
    }
    None
}
