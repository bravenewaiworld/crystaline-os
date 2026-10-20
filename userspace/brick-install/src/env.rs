//! U-Boot's settings (its "environment"; the user sees "start-up settings"). TrimUI's U-Boot keeps
//! two copies, in the env and env-redund partitions, each in U-Boot's redundant format (as
//! tools/sdboot/mkenv.py writes it): the CRC-32 of bytes 5 to the end at 0, a flags byte at 4
//! (a save counter: each save adds 1, and U-Boot uses the copy saved last, see `pick`), then
//! NUL-separated "key=value" strings, ending with an empty one.
//!
//! U-Boot uses one copy (`pick`), so every change starts from that copy, not from whichever
//! partition is named env.
//! `switch` changes the settings so that a power cut at any moment leaves either the old or the
//! new settings in effect.

use crate::cut;
use crate::disk::{self, Disk, Part};
use crate::report::{REWRITE_CARD, Report, Result, SEE_LOG, fail};

/// U-Boot's settings size on the Brick.
pub const SIZE: usize = 0x20000;

/// One copy of the settings as read from disk: its flags byte, whether its CRC is good, and its settings.
pub struct Settings { pub flags: u8, pub crc_ok: bool, pub pairs: Vec<(String, String)> }

impl Settings {
    /// Reads a copy from `image` (`SIZE` bytes; a shorter one counts as a bad CRC).
    pub fn parse(image: &[u8]) -> Self {
        if image.len() < SIZE { return Self { flags: 0, crc_ok: false, pairs: Vec::new() }; }
        let d = &image[..SIZE];
        let pairs = d[5..].split(|&b| b == 0).take_while(|s| !s.is_empty())
            .map(|s| { let s = String::from_utf8_lossy(s); let (k, v) = s.split_once('=').unwrap_or((&s, "")); (k.into(), v.into()) })
            .collect();
        Self { flags: d[4], crc_ok: u32::from_le_bytes(d[..4].try_into().unwrap()) == crc32fast::hash(&d[5..]), pairs }
    }

    fn describe(&self) -> String {
        if self.crc_ok { format!("crc ok, flags {}", self.flags) } else { "crc bad".into() }
    }
}

/// One of the two copies: the one in the env partition, or in env-redund.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Which { Env, Redund }

/// Which copy TrimUI's U-Boot uses (upstream U-Boot's `env_import_redund`; TrimUI's binary was
/// checked to behave the same):
/// never one with a bad CRC; of two good ones, the one with the higher flags byte, except that 0
/// beats 255 (each save adds 1, so the byte wraps); with equal flags, env. None if neither CRC is
/// good (U-Boot then uses its built-in settings, which can't start our layout).
pub fn pick(env: &Settings, redund: &Settings) -> Option<Which> {
    match (env.crc_ok, redund.crc_ok) {
        (false, false) => None,
        (true, false) => Some(Which::Env),
        (false, true) => Some(Which::Redund),
        _ => Some(match (env.flags, redund.flags) {
            (255, 0) => Which::Redund,
            (0, 255) => Which::Env,
            (e, r) if r > e => Which::Redund,
            _ => Which::Env,
        }),
    }
}

/// The settings `current` with `changes` (key, value) applied, encoded with `flags`.
pub fn encode(current: &[(String, String)], changes: &[(&str, &str)], flags: u8) -> Result<Vec<u8>> {
    let mut pairs = current.to_vec();
    for &(key, value) in changes {
        match pairs.iter_mut().find(|(k, _)| k == key) {
            Some(p) => p.1 = value.into(),
            None => pairs.push((key.into(), value.into())),
        }
    }
    let mut data: Vec<u8> = pairs.iter().flat_map(|(k, v)| format!("{k}={v}\0").into_bytes()).collect();
    data.push(0);
    if data.len() > SIZE - 5 { return fail("the start-up settings don't fit", SEE_LOG); }
    data.resize(SIZE - 5, 0);
    let mut out = crc32fast::hash(&data).to_le_bytes().to_vec();
    out.push(flags);
    out.extend(data);
    Ok(out)
}

/// The value of `key` in `pairs`, if set.
pub fn get<'a>(pairs: &'a [(String, String)], key: &str) -> Option<&'a str> {
    pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// A copy and where it is on its disk.
type Placed = (Settings, u64);

/// Both copies on `disk` (whose partitions are `parts`).
fn read(disk: &Disk, parts: &[Part]) -> Result<[Placed; 2]> {
    let at = |name| disk::named(parts, name, &disk.path).map(|p| p.start);
    let (env_at, redund_at) = (at("env")?, at("env-redund")?);
    Ok([(Settings::parse(&disk.read_at(env_at, SIZE)?), env_at), (Settings::parse(&disk.read_at(redund_at, SIZE)?), redund_at)])
}

/// The two copies as U-Boot sees them: (the one it uses, its place), (the other, its place), and
/// both copies' state for the log.
fn picked(disk: &Disk, parts: &[Part]) -> Result<(Placed, Placed, String)> {
    let [env, redund] = read(disk, parts)?;
    let which = pick(&env.0, &redund.0);
    let state = format!("settings on {}: env {}, env-redund {}; U-Boot uses {}", disk.path.display(), env.0.describe(), redund.0.describe(),
                        match which { Some(Which::Env) => "env", Some(Which::Redund) => "env-redund", None => "neither" });
    match which {
        Some(Which::Env) => Ok((env, redund, state)),
        Some(Which::Redund) => Ok((redund, env, state)),
        None => fail(format!("both copies of the start-up settings on {} are damaged", disk.path.display()),
                     format!("This storage can't start. If it is the SD card: {REWRITE_CARD} If it is the internal storage, start from a newly written SD card and install again.")),
    }
}

/// The settings U-Boot uses on `disk` (whose partitions are `parts`), and both copies' state for
/// the log.
pub fn current(disk: &Disk, parts: &[Part]) -> Result<(Settings, String)> {
    let (used, _, state) = picked(disk, parts)?;
    Ok((used.0, state))
}

/// Applies `changes` to the settings on `disk` so that a power cut at any moment leaves either the
/// old or the new settings in effect. With U the copy U-Boot uses now, n its flags and O the
/// other copy:
///   1. O ← new settings, flags n+1: until this write is complete O's CRC is bad or O is older,
///      so U (old) is used; once it is, O is newer, so the new settings are.
///   2. U ← new settings, flags n+2: while it is written U's CRC is bad, so O (new) is used;
///      afterwards U is the copy in use again.
///
/// Only neighbouring flag values ever meet, so the 255/0 wrap is always read right, and both
/// copies end up the same, so one going bad later still leaves the new settings.
pub fn switch(disk: &Disk, parts: &[Part], changes: &[(&str, &str)], report: &mut Report) -> Result<()> {
    let ((p, p_at), (_, q_at), state) = picked(disk, parts)?;
    report.log(&state);
    for &(key, value) in changes {
        report.log(&format!("  {key}: {} -> {value}", get(&p.pairs, key).unwrap_or("(not set)")));
    }
    for (point, at, flags) in [("env-1", q_at, p.flags.wrapping_add(1)), ("env-2", p_at, p.flags.wrapping_add(2))] {
        let image = encode(&p.pairs, changes, flags)?;
        cut::torn(point, disk, at, &image)?;
        disk.write_checked(at, &image, &format!("start-up settings (flags {flags})"), report)?;
        cut::here(point);
    }
    let (now, state) = current(disk, parts)?;
    report.log(&state);
    if changes.iter().any(|&(k, v)| get(&now.pairs, k) != Some(v)) {
        return fail("the start-up settings don't read back as written", "Try again; if it fails again, the storage may be failing.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn copy(flags: u8, crc_ok: bool) -> Settings { Settings { flags, crc_ok, pairs: Vec::new() } }

    #[test]
    fn picks_as_u_boot_does() {
        assert_eq!(pick(&copy(1, true), &copy(1, true)), Some(Which::Env));
        assert_eq!(pick(&copy(1, true), &copy(2, true)), Some(Which::Redund));
        assert_eq!(pick(&copy(3, true), &copy(2, true)), Some(Which::Env));
        assert_eq!(pick(&copy(255, true), &copy(0, true)), Some(Which::Redund));
        assert_eq!(pick(&copy(0, true), &copy(255, true)), Some(Which::Env));
        assert_eq!(pick(&copy(9, false), &copy(2, true)), Some(Which::Redund));
        assert_eq!(pick(&copy(1, true), &copy(9, false)), Some(Which::Env));
        assert_eq!(pick(&copy(1, false), &copy(1, false)), None);
    }

    #[test]
    fn encodes_with_the_changes_and_a_good_crc() {
        let pairs = vec![("bootcmd".into(), "run x".into()), ("mmc_root".into(), "UUID=old".into())];
        let c = Settings::parse(&encode(&pairs, &[("mmc_root", "UUID=new"), ("a", "b")], 7).unwrap());
        assert!(c.crc_ok);
        assert_eq!(c.flags, 7);
        assert_eq!((get(&c.pairs, "bootcmd"), get(&c.pairs, "mmc_root"), get(&c.pairs, "a")), (Some("run x"), Some("UUID=new"), Some("b")));
        let mut bad = encode(&pairs, &[], 1).unwrap();
        bad[10] ^= 1;
        assert!(!Settings::parse(&bad).crc_ok);
    }

    /// For each starting pair of flags (env, env-redund; the copy U-Boot uses has `start`), a
    /// switch leaves both copies with the new settings, neighbouring flags, and the copy U-Boot
    /// used before used again.
    #[test]
    fn switches_both_copies() {
        for (e, r) in [(1, 1), (254, 255), (255, 0), (0, 254), (5, 4)] {
            let path = std::env::temp_dir().join(format!("brick-install-env-test-{}-{e}-{r}", std::process::id()));
            std::fs::write(&path, vec![0; 2 * SIZE]).unwrap();
            let disk = Disk::open(&path, true).unwrap();
            let parts = [Part { name: "env".into(), start: 0, size: SIZE as u64 }, Part { name: "env-redund".into(), start: SIZE as u64, size: SIZE as u64 }];
            let old = vec![("boot_partition".to_string(), "boot_a".to_string())];
            disk.write_at(0, &encode(&old, &[], e).unwrap()).unwrap();
            disk.write_at(SIZE as u64, &encode(&old, &[], r).unwrap()).unwrap();
            let before = pick(&Settings::parse(&disk.read_at(0, SIZE).unwrap()), &Settings::parse(&disk.read_at(SIZE as u64, SIZE).unwrap()));
            let mut report = Report::new(None, "test", None);
            switch(&disk, &parts, &[("boot_partition", "boot_b")], &mut report).unwrap();
            let (env, redund) = (Settings::parse(&disk.read_at(0, SIZE).unwrap()), Settings::parse(&disk.read_at(SIZE as u64, SIZE).unwrap()));
            assert_eq!((get(&env.pairs, "boot_partition"), get(&redund.pairs, "boot_partition")), (Some("boot_b"), Some("boot_b")));
            assert_eq!(pick(&env, &redund), before);
            let (used, other) = if before == Some(Which::Env) { (&env, &redund) } else { (&redund, &env) };
            assert_eq!(used.flags, other.flags.wrapping_add(1));
            let _ = std::fs::remove_file(&path);
        }
    }
}
