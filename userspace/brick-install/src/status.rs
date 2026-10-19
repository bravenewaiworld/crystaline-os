//! One task (install, restore, update, activate) at a time, and a way to watch it from its start
//! by whoever comes later (Specular, restarted while the task ran). Dry runs and the read-only
//! commands (offer, slots) don't take part.
//!
//! The status file (/run/brick-install.status; /run is emptied at each start-up) holds a copy of
//! everything the running task printed (report.rs's protocol). The task holds an exclusive
//! `flock` on it from start to end, so a held lock means "running"; `sleepnow` checks the same
//! lock and doesn't sleep while it is held.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::time::Duration;

use crate::report::{Context, Result, fail};

/// The status file, unless `--status` gives another.
pub const STATUS: &str = "/run/brick-install.status";

/// Takes the lock for a new task and empties the status file, for the task's report to copy its
/// lines into. Fails if a task is running.
pub fn take(path: &Path) -> Result<File> {
    let file = OpenOptions::new().create(true).append(true).open(path).ctx(&format!("opening {}", path.display()))?;
    if !try_lock(&file, libc::LOCK_EX) {
        return fail("another install, restore or update is already running", "Wait until it has finished.");
    }
    file.set_len(0).ctx(&format!("emptying {}", path.display()))?;
    Ok(file)
}

/// If a task is running, prints what it has printed so far, then what it prints next, until it
/// ends (its last line, DONE or FAIL; missing if it was killed). Prints nothing otherwise.
pub fn follow(path: &Path) -> Result<()> {
    let Ok(mut file) = File::open(path) else { return Ok(()) };
    if try_lock(&file, libc::LOCK_SH) { return Ok(()); }
    let (mut pending, mut out) = (Vec::new(), std::io::stdout().lock());
    loop {
        // Checked before reading, so the lines written before the task ended are all read.
        let ended = try_lock(&file, libc::LOCK_SH);
        file.read_to_end(&mut pending).ctx("reading the status file")?;
        // Only whole lines: the task may be halfway through writing one.
        if let Some(end) = pending.iter().rposition(|&b| b == b'\n') {
            let _ = out.write_all(&pending[..=end]).and_then(|()| out.flush());
            pending.drain(..=end);
        }
        if ended { return Ok(()); }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// Tries to take the lock (`LOCK_EX` or `LOCK_SH`) without waiting. A file's lock is let go
/// when the process ends (or the file is closed), however that happens.
fn try_lock(file: &File, kind: i32) -> bool {
    unsafe { libc::flock(file.as_raw_fd(), kind | libc::LOCK_NB) == 0 }
}
