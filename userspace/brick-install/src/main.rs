//! brick-install: installs the system running from the SD card onto the internal storage (eMMC),
//! optionally backing the internal storage up to the card first, and puts such a backup back;
//! installs signed update files and switches between installed versions (A/B boot slots).
//! Specular runs it from its Settings and shows its progress (see report.rs for what it prints),
//! as does the recovery menu in the initramfs; it also runs on a PC against image files and
//! folders, which is how tools/system/test-installer.sh tests it.
//!
//! Usage:
//!   brick-install offer                  what can be done now, as JSON (see `offer`)
//!   brick-install install [--backup] [--keep-card-bootable] [--dry-run]
//!   brick-install restore <backup folder>
//!                                        from the SD card: puts the backup back; from the
//!                                        installed system: prepares a restore (makes the card
//!                                        start the device next time; backup.rs)
//!   brick-install restore --cancel       on the SD card: drops a prepared restore
//!   brick-install update <file>          checks an update file, copies it into images/ and makes
//!                                        it start next (update.rs)
//!   brick-install activate <version>     makes an installed version start next (slots.rs)
//!   brick-install slots                  what each boot slot holds, as text (slots.rs)
//!   brick-install follow                 the running task's messages, from its start until it
//!                                        ends; nothing if none runs (status.rs)
//! On the device everything is found by itself; any of these can be given instead:
//!   --target <disk or file>   the internal storage     --source <disk or file>   the SD card
//!   --running <disk or file>  the disk the system runs from (one of those two)
//!   --system <folder>  --data <folder>  --version <version>
//!   --slot <boot_a|boot_b>    the boot slot the running system was started from
//!   --keys <folder>           the trusted update keys  --power-supply <folder>  sysfs's power_supply
//!   --status <file>           (see status.rs)
//! The log goes to logs/ on the card's data partition.

mod backup;
mod cut;
mod disk;
mod env;
mod install;
mod report;
mod slots;
mod status;
mod update;

use std::path::{Path, PathBuf};

use install::Options;
use report::{Report, Result, fail};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut flag = |name: &str| args.iter().position(|a| a == name).map(|i| args.remove(i)).is_some();
    let o = Options { backup: flag("--backup"), keep_card_bootable: flag("--keep-card-bootable"), dry_run: flag("--dry-run") };
    let mut value = |name: &str| args.iter().position(|a| a == name).filter(|&i| i + 1 < args.len())
        .map(|i| { args.remove(i); args.remove(i) });
    let status = PathBuf::from(value("--status").unwrap_or_else(|| status::STATUS.into()));
    let paths = Paths::find(|name| value(name));
    let logs = paths.as_ref().ok().map(|p| p.data.join("logs"));
    let task = |name, f: &dyn Fn(&Paths, &mut Report) -> Result<String>| {
        // A dry run changes nothing, so it doesn't take the one-task lock.
        match (!o.dry_run).then(|| status::take(&status)).transpose() {
            Ok(lock) => run(logs.as_deref(), name, lock, |r| f(paths.as_ref().map_err(Clone::clone)?, r)),
            Err(e) => run(logs.as_deref(), name, None, |_| Err(e)),
        }
    };
    let code = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["offer"] => { println!("{}", offer(&paths)); 0 }
        ["install"] => task("install", &|p, r| install::install(p, &o, r)),
        ["restore", "--cancel"] => task("restore", &backup::cancel),
        ["restore", dir] => task("restore", &|p, r| backup::restore_or_prepare(p, Path::new(dir), r)),
        ["update", file] => task("update", &|p, r| update::apply(p, Path::new(file), r)),
        ["activate", version] => task("activate", &|p, r| { r.steps(1); r.step(&format!("Switching to version {version}")); slots::activate(p, version, r) }),
        ["slots"] => print(paths.as_ref().map_err(Clone::clone).and_then(slots::describe)),
        ["follow"] => print(status::follow(&status).map(|()| String::new())),
        _ => { eprintln!("usage: brick-install offer | install [--backup] [--keep-card-bootable] [--dry-run] | restore <backup folder> | restore --cancel | update <file> | activate <version> | slots | follow"); 2 }
    };
    std::process::exit(code);
}

/// Prints a command's text, or its failure to stderr; returns the exit status.
fn print(out: Result<String>) -> i32 {
    match out {
        Ok(text) => { print!("{text}"); 0 }
        Err(e) => { eprintln!("{}", e.message); 1 }
    }
}

/// Runs task `name`, reporting its end; the exit status is 0 if it succeeded. `lock`: the status
/// file, locked for this task until the process ends (None for a dry run).
fn run(logs: Option<&Path>, name: &str, lock: Option<std::fs::File>, f: impl FnOnce(&mut Report) -> Result<String>) -> i32 {
    let mut report = Report::new(logs, name, lock);
    match f(&mut report) {
        Ok(message) => { report.done(&message); 0 }
        Err(e) => { report.failed(&e); 1 }
    }
}

/// What can be done now, for Specular's settings:
///   { "install": null, or { "bytes": the internal storage's size,
///                           "backup": { "possible", "free" (bytes on the data partition) } },
///     "why_not": why installing isn't possible (with "install": null),
///     "internal": what the internal storage holds (install::holds; with "install"),
///     "backups": [{ "dir", "created", "bytes", "holds" (if known) }] (complete ones on the card,
///                 newest first),
///     "running": { "version", "disk": "card" or "internal", "slot": its boot slot, or null },
///     "previous": { "version", "slot" }: what the other boot slot holds, or null,
///     "updates": update files on the card (update::list),
///     "restore": on the installed system: { "possible": true } or { "why_not" }; else null,
///     "restore_pending": on the SD card: a prepared restore (backup.rs), or null }
/// "free" counts the room backups cut short take (the next backup deletes them).
/// Installing, and writing a backup back, run only from the SD card's system, on a device with
/// internal storage; the installed system can only prepare a restore. A backup needs as much
/// free space as the internal storage holds.
fn offer(paths: &Result<Paths>) -> serde_json::Value {
    let p = match paths {
        Ok(p) => p,
        Err(e) => return serde_json::json!({ "install": null, "why_not": e.message, "backups": [], "running": null, "previous": null,
                                             "updates": [], "restore": null, "restore_pending": null }),
    };
    let backups: Vec<_> = backup::list(&p.data).iter()
        .map(|b| serde_json::json!({ "dir": b.dir, "created": b.created, "bytes": b.bytes, "holds": b.holds })).collect();
    let updates: Vec<_> = update::list(&p.data, &p.keys, &p.version).iter()
        .map(|u| serde_json::json!({ "file": u.file, "version": u.version, "older": u.older, "problem": u.problem })).collect();
    let (slot, previous) = slots::offer(p);
    let on_card = p.on_card();
    let mut o = serde_json::json!({
        "backups": backups, "updates": updates, "previous": previous,
        "running": { "version": p.version, "disk": if on_card { "card" } else { "internal" }, "slot": slot },
        "restore": if on_card { serde_json::Value::Null } else { backup::offer_prepare(p) },
        "restore_pending": if on_card { backup::pending(&p.data) } else { serde_json::Value::Null },
    });
    let internal = if on_card { p.internal().and_then(|t| disk::Disk::open(t, false)) } else { fail("the system isn't running from an SD card", "") };
    match internal {
        Ok(t) => {
            let free = install::free_bytes(&p.data) + backup::leftovers(&p.data).1;
            o["install"] = serde_json::json!({ "bytes": t.size, "backup": { "possible": free >= t.size, "free": free } });
            o["internal"] = install::holds(&t).into();
        }
        Err(e) => { o["install"] = serde_json::Value::Null; o["why_not"] = e.message.into(); }
    }
    o
}

/// Where things are; on the device all are found by `Paths::find`, and any can be given instead
/// (e.g. image files and folders on a PC, for tests).
pub struct Paths {
    /// The internal storage (a disk device, or an image file), or why there is none.
    internal: Result<PathBuf>,
    /// The SD card, or why there is none.
    card: Result<PathBuf>,
    /// The disk the system runs from (holding /system): the card or the internal storage.
    pub running: PathBuf,
    /// The running system's partition (images/, overlay/, state/, logs/), mounted.
    pub system: PathBuf,
    /// The card's data partition (backups/, logs/, updates/).
    pub data: PathBuf,
    /// The running system's version.
    pub version: String,
    /// The boot slot the running system was started from, if given (else slots::running reads it).
    pub slot: Option<String>,
    /// The trusted update keys (update.rs).
    pub keys: PathBuf,
    /// The kernel's power supplies (sysfs's power_supply class), for the battery check.
    pub power: PathBuf,
}

impl Paths {
    /// The paths given (by option name, e.g. "--target"), the rest found on the device: the
    /// internal storage is the disk on the eMMC controller (sdc2), the card the disk on the SD
    /// card controller (sdc0); the system runs from the disk holding /system, which must be one
    /// of them; the data partition is at /mnt/SDCARD; the version is /etc/brick-version.
    fn find(mut given: impl FnMut(&str) -> Option<String>) -> Result<Self> {
        let (target, source, running, system, data, version) =
            (given("--target"), given("--source"), given("--running"), given("--system"), given("--data"), given("--version"));
        let (slot, keys, power) = (given("--slot"), given("--keys"), given("--power-supply"));
        let path = |p: Option<String>, default: &str| PathBuf::from(p.unwrap_or_else(|| default.into()));
        let internal = target.map(PathBuf::from).or_else(|| disk_on("sdc2")).map_or_else(|| fail("this device's internal storage isn't available",
            "This system can't reach the internal storage: its device tree must enable it (system/board/brick/dt-tweaks.sh)."), Ok);
        let card = source.map(PathBuf::from).or_else(|| disk_on("sdc0")).map_or_else(|| fail("there is no SD card in the device", "Insert the SD card, then try again."), Ok);
        let running = match running {
            Some(r) => PathBuf::from(r),
            None => {
                let mounts = std::fs::read_to_string("/proc/mounts").unwrap_or_default();
                let dev = mounts.lines().find_map(|l| { let mut f = l.split(' '); let d = f.next()?; (f.next()? == "/system").then(|| d.to_string()) });
                let Some(dev) = dev else { return fail("the system partition isn't mounted", "Start the device from an SD card written for this system.") };
                PathBuf::from(dev.trim_end_matches(|c: char| c.is_ascii_digit()).trim_end_matches('p'))
            }
        };
        if internal.as_ref().ok() != Some(&running) && card.as_ref().ok() != Some(&running) {
            return fail(format!("the system runs from {}, neither the SD card nor the internal storage", running.display()), report::SEE_LOG);
        }
        let version = match version {
            Some(v) => v,
            None => std::fs::read_to_string("/etc/brick-version").map(|v| v.trim().to_string())
                .map_err(|e| report::Failure { message: format!("reading /etc/brick-version: {e}"), hint: "The system is damaged: write a fresh SD card.".into() })?,
        };
        Ok(Self { internal, card, running, system: path(system, "/system"), data: path(data, "/mnt/SDCARD"), version, slot,
                  keys: path(keys, "/etc/brick/update-keys"), power: path(power, "/sys/class/power_supply") })
    }

    /// The internal storage, failing if there is none.
    pub fn internal(&self) -> Result<&Path> { self.internal.as_deref().map_err(Clone::clone) }

    /// The SD card, failing if there is none.
    pub fn card(&self) -> Result<&Path> { self.card.as_deref().map_err(Clone::clone) }

    /// Whether the system runs from the SD card (else from the internal storage).
    pub fn on_card(&self) -> bool { self.card.as_ref().ok() == Some(&self.running) }
}

/// The disk (e.g. /dev/mmcblk0) on the storage controller `controller` (a platform device: sdc0
/// is the SD card's, sdc2 the eMMC's), if any.
fn disk_on(controller: &str) -> Option<PathBuf> {
    let hosts = std::fs::read_dir(format!("/sys/bus/platform/devices/{controller}/mmc_host")).ok()?;
    for host in hosts.flatten() {
        for card in std::fs::read_dir(host.path()).ok()?.flatten() {
            if let Ok(disks) = std::fs::read_dir(card.path().join("block"))
                && let Some(d) = disks.flatten().next() { return Some(Path::new("/dev").join(d.file_name())); }
        }
    }
    None
}
