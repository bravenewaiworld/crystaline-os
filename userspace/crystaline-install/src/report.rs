//! What the installer tells its caller (Specular), and its log.
//!
//! Lines on stdout, one message each:
//!   LOG-FILE <path>        where the full log is (first line, if there is a log)
//!   TASK <name>            which task this is: install, restore, update or activate
//!   STEP <i>/<n> <label>   a step started
//!   PROGRESS <0.00-1.00>   how far the current step is
//!   DONE <message>         finished; the last line
//!   FAIL <message>\t<hint> failed (what happened, what the user can do); the last line
//! The log file has every step, every command run with its exit status and output, and timings,
//! so a failure on a device can be understood (and reproduced against image files) afterwards. It
//! is flushed to the card at every step and at the end, so a power cut keeps it up to there.
//! The lines also go to the status file, if given (see status.rs).

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

/// The hint for failures whose cause only the log can tell.
pub const SEE_LOG: &str = "Details are in the log on the SD card (logs/).";
/// The fix for a damaged or outdated card: it says up front that writing a card erases it.
pub const REWRITE_CARD: &str = "Copy your games, saves and backups/ off the SD card to a PC (writing a card erases it), \
write the SD card image from github.com/bravenewaiworld/crystaline-os/releases to the card, then copy them back.";
/// Where releases (SD card images and update files) are downloaded from.
pub const RELEASES: &str = "github.com/bravenewaiworld/crystaline-os/releases";

/// A failure the user can act on: what happened, and what to do about it. `detail` is for the
/// log only (e.g. which part of the build to look at); usually empty.
#[derive(Clone, Debug, Default)]
pub struct Failure { pub message: String, pub hint: String, pub detail: String }

pub type Result<T> = std::result::Result<T, Failure>;

/// A failure with a hint for the user.
pub fn fail<T>(message: impl Into<String>, hint: impl Into<String>) -> Result<T> {
    Err(Failure { message: message.into(), hint: hint.into(), ..Default::default() })
}

/// Turns any error into a `Failure` saying what was being done.
pub trait Context<T> { fn ctx(self, doing: &str) -> Result<T>; }

impl<T, E: std::fmt::Display> Context<T> for std::result::Result<T, E> {
    fn ctx(self, doing: &str) -> Result<T> { self.map_err(|e| Failure { message: format!("{doing}: {e}"), hint: SEE_LOG.into(), ..Default::default() }) }
}

/// One task's messages (the protocol above) and its log.
pub struct Report {
    log: Option<File>,
    status: Option<File>,
    pub log_path: Option<PathBuf>,
    start: Instant,
    last_progress: i32,
    /// The current step (from 1) and how many there are.
    step: (usize, usize),
}

impl Report {
    /// The report of task `name` (the TASK line). Writes the log to
    /// `<dir>/<name>-<time>.log` (`dir` is made if missing); without a dir, or if it can't be
    /// written, there is no log file (the messages still go out). Copies the messages to `status`.
    pub fn new(dir: Option<&Path>, name: &str, status: Option<File>) -> Self {
        let path = dir.map(|d| d.join(format!("{name}-{}.log", timestamp())));
        let log = path.as_ref().and_then(|p| { let _ = std::fs::create_dir_all(p.parent()?); File::create(p).ok() });
        let path = log.is_some().then_some(path).flatten();
        let mut r = Self { log, status, log_path: path, start: Instant::now(), last_progress: -1, step: (0, 0) };
        if let Some(p) = r.log_path.clone() { r.say(&format!("LOG-FILE {}", p.display())); }
        r.say(&format!("TASK {name}"));
        r
    }

    /// A line in the log only.
    pub fn log(&mut self, text: &str) {
        let t = self.start.elapsed().as_secs_f32();
        if let Some(f) = &mut self.log { let _ = writeln!(f, "[{t:7.1}] {text}"); }
    }

    /// How many steps there are, before the first.
    pub fn steps(&mut self, n: usize) { self.step = (0, n); }

    /// The next step started.
    pub fn step(&mut self, label: &str) {
        self.step.0 += 1;
        let (i, n) = self.step;
        self.log(&format!("== step {i}/{n}: {label}"));
        self.flush_log();
        self.last_progress = -1;
        self.say(&format!("STEP {i}/{n} {label}"));
    }

    /// How far the current step is, `done` of `total`; sent at most once per whole percent.
    pub fn progress(&mut self, done: u64, total: u64) {
        let pct = (done.min(total) * 100).checked_div(total).unwrap_or(100) as i32;
        if pct == self.last_progress { return; }
        self.last_progress = pct;
        self.say(&format!("PROGRESS {:.2}", pct as f32 / 100.0));
    }

    /// The task succeeded: the DONE line, which ends the report.
    pub fn done(&mut self, message: &str) {
        self.log(&format!("== done: {message}"));
        self.flush_log();
        self.say(&format!("DONE {message}"));
    }

    /// The task failed: the FAIL line, which ends the report.
    pub fn failed(&mut self, f: &Failure) {
        self.log(&format!("== failed: {}\n   hint: {}", f.message, f.hint));
        if !f.detail.is_empty() { self.log(&format!("   detail: {}", f.detail)); }
        self.flush_log();
        self.say(&format!("FAIL {}\t{}", f.message.replace(['\n', '\t'], " "), f.hint.replace(['\n', '\t'], " ")));
    }

    /// Runs a program and logs it with its exit status and output. Returns its stdout; if it
    /// fails, the failure holds its exit status and stderr.
    pub fn run(&mut self, program: &str, args: &[&str]) -> Result<String> {
        self.log(&format!("$ {program} {}", args.join(" ")));
        let out = std::process::Command::new(program).args(args).output().ctx(&format!("starting {program}"))?;
        let (stdout, stderr) = (String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
        for line in stdout.lines().chain(stderr.lines()) { self.log(&format!("  {line}")); }
        self.log(&format!("  -> {}", out.status));
        if out.status.success() { return Ok(stdout.into_owned()); }
        fail(format!("{program} {}: {} {}", args.join(" "), out.status, stderr.trim()), SEE_LOG)
    }

    /// A message, to stdout and the status file. Errors are ignored: with Specular gone (stdout
    /// closed) the task goes on.
    fn say(&mut self, line: &str) {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
        // Each line in one write, so a reader rarely sees half a line (status::follow copes with
        // that anyway).
        if let Some(f) = &mut self.status { let _ = f.write_all(format!("{line}\n").as_bytes()); }
    }

    fn flush_log(&mut self) {
        if let Some(f) = &self.log { let _ = f.sync_data(); }
    }
}

/// Reads a JSON file; `what` names it in a failure.
pub fn read_json(path: &Path, what: &str) -> Result<serde_json::Value> {
    let data = std::fs::read(path).ctx(&format!("reading {what}"))?;
    serde_json::from_slice(&data).ctx(&format!("reading {what}"))
}

/// The time now, as YYYYMMDD-HHMMSS in UTC (the device's clock knows no time zone).
pub fn timestamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs()) as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::gmtime_r(&secs, &mut tm) };
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

/// Bytes as lower-case hex, e.g. a SHA-256 as manifests write it.
pub fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }

/// "7.8 GB".
pub fn gb(bytes: u64) -> String { format!("{:.1} GB", bytes as f64 / 1e9) }
