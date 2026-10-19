//! Cut points, for tests only: built with the `cut-points` feature (only the PC build that
//! tools/system/test-installer.sh runs has it), `BRICK_INSTALL_CUT=<point>` ends the process at
//! that point, as a power cut there would. Without the feature these do nothing.

use crate::disk::{Disk, SECTOR};
use crate::report::Result;

/// Ends the process if `BRICK_INSTALL_CUT` is `point`.
pub fn here(point: &str) {
    if wanted(point) { abort(point) }
}

/// If `BRICK_INSTALL_CUT` is `<point>-torn`: writes `data` at `at` except its first sector (which
/// holds the settings' CRC), then ends the process, as a write cut short partway would. (Writing only the
/// first half instead would leave a complete copy of U-Boot's settings, whose second half is
/// padding.)
pub fn torn(point: &str, disk: &Disk, at: u64, data: &[u8]) -> Result<()> {
    let point = format!("{point}-torn");
    if wanted(&point) {
        disk.write_at(at + SECTOR, &data[SECTOR as usize..])?;
        disk.sync()?;
        abort(&point)
    }
    Ok(())
}

#[cfg(feature = "cut-points")]
fn wanted(point: &str) -> bool { std::env::var("BRICK_INSTALL_CUT").is_ok_and(|v| v == point) }

#[cfg(not(feature = "cut-points"))]
fn wanted(_: &str) -> bool { false }

/// Ends the process at once, with no cleaning up. SIGKILL rather than abort(): the same for the
/// test, without a core dump each time.
fn abort(point: &str) -> ! {
    eprintln!("brick-install: cut at {point} (BRICK_INSTALL_CUT)");
    unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
    unreachable!()
}
