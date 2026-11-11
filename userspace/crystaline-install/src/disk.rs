//! A whole disk (the internal storage or the SD card), as a device or an image file: reads and
//! writes at byte offsets, and its partition table.

use std::fs::{File, OpenOptions};
use std::io::Seek;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::report::{Context, Report, Result, SEE_LOG, fail};

/// The sector size, in bytes.
pub const SECTOR: u64 = 512;
/// How much is read or written at a time.
pub const CHUNK: usize = 4 << 20;

/// An open disk (or image file) and its size in bytes.
pub struct Disk { pub path: PathBuf, file: File, pub size: u64 }

impl Disk {
    /// Opens `path`, for reading and writing if `write`.
    pub fn open(path: &Path, write: bool) -> Result<Self> {
        let file = OpenOptions::new().read(true).write(write).open(path).ctx(&format!("opening {}", path.display()))?;
        // Seeking to the end gives the size of a device as well as of a file.
        let size = (&file).seek(std::io::SeekFrom::End(0)).ctx(&format!("finding the size of {}", path.display()))?;
        Ok(Self { path: path.into(), file, size })
    }

    /// `len` bytes from `offset`.
    pub fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>> {
        let mut buf = vec![0; len];
        self.file.read_exact_at(&mut buf, offset).ctx(&format!("reading {} at byte {offset}", self.path.display()))?;
        Ok(buf)
    }

    /// Writes `data` at `offset`; refuses to write past the end.
    pub fn write_at(&self, offset: u64, data: &[u8]) -> Result<()> {
        if offset + data.len() as u64 > self.size { return fail(format!("writing past the end of {}", self.path.display()), SEE_LOG); }
        self.file.write_all_at(data, offset).ctx(&format!("writing {} at byte {offset}", self.path.display()))
    }

    /// Calls `f` with the `len` bytes from `from`, a chunk at a time, with each chunk's offset
    /// from `from`.
    pub fn each_chunk(&self, from: u64, len: u64, mut f: impl FnMut(u64, &[u8]) -> Result<()>) -> Result<()> {
        let mut done = 0;
        while done < len {
            let n = CHUNK.min((len - done) as usize);
            f(done, &self.read_at(from + done, n)?)?;
            done += n as u64;
        }
        Ok(())
    }

    /// Copies `len` bytes from `self` at `from` to `to` at `at`, reporting progress.
    pub fn copy_to(&self, from: u64, to: &Disk, at: u64, len: u64, report: &mut Report) -> Result<()> {
        self.each_chunk(from, len, |off, c| { to.write_at(at + off, c)?; report.progress(off + c.len() as u64, len); Ok(()) })
    }

    /// Its partitions, from its GPT: the header in sector 1 and the entries it points at, both
    /// checked against their CRCs (the backup table at the end isn't looked at).
    pub fn partitions(&self) -> Result<Vec<Part>> {
        match self.read_gpt() {
            Some(p) => Ok(p),
            None => fail(format!("{} has no valid partition table", self.path.display()), "This disk wasn't made for this system, or is damaged."),
        }
    }

    fn read_gpt(&self) -> Option<Vec<Part>> {
        let h = self.read_at(SECTOR, SECTOR as usize).ok()?;
        let le32 = |b: &[u8], at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap());
        let le64 = |b: &[u8], at: usize| u64::from_le_bytes(b[at..at + 8].try_into().unwrap());
        let header_len = le32(&h, 12) as usize;
        if !h.starts_with(b"EFI PART") || !(92..=512).contains(&header_len) { return None; }
        // The header's CRC is computed with its own field as 0.
        let mut unsummed = h[..header_len].to_vec();
        unsummed[16..20].fill(0);
        let (at, count, size) = (le64(&h, 72), le32(&h, 80) as usize, le32(&h, 84) as usize);
        if le32(&h, 16) != crc32fast::hash(&unsummed) || !(128..=4096).contains(&size) || count > 1024 { return None; }
        let entries = self.read_at(at * SECTOR, count * size).ok()?;
        if le32(&h, 88) != crc32fast::hash(&entries) { return None; }
        Some(entries.chunks(size).filter(|e| e[..16].iter().any(|&b| b != 0)).map(|e| {
            // The name: up to 36 UTF-16 units from byte 56, ending at the first 0.
            let units: Vec<u16> = e[56..128].chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|&u| u != 0).collect();
            let (first, last) = (le64(e, 32), le64(e, 40).max(le64(e, 32)));
            Part { name: String::from_utf16_lossy(&units), start: first * SECTOR, size: (last + 1 - first) * SECTOR }
        }).collect())
    }

    /// Writes `data` at `offset`, makes it reach the storage and reads it back, logging where, how
    /// much and its SHA-256. `what` names it in the log and in a failure.
    pub fn write_checked(&self, offset: u64, data: &[u8], what: &str, report: &mut Report) -> Result<()> {
        report.log(&format!("writing {what}: {} at byte {offset}, {} bytes, sha256 {}", self.path.display(), data.len(), crate::report::hex(&Sha256::digest(data))));
        self.write_at(offset, data)?;
        self.sync()?;
        if self.read_at(offset, data.len())? != data {
            report.log("  read back: different");
            return fail(format!("{what} on {} doesn't read back as written", self.path.display()), "Try again; if it fails again, the storage may be failing.");
        }
        report.log("  read back: same");
        Ok(())
    }

    /// Writes `len` zero bytes at `offset`.
    pub fn zero(&self, offset: u64, len: u64) -> Result<()> { self.write_at(offset, &vec![0; len as usize]) }

    /// Makes everything written so far reach the storage.
    pub fn sync(&self) -> Result<()> { self.file.sync_all().ctx(&format!("flushing {}", self.path.display())) }
}

/// A partition: its GPT name, and where it is, in bytes.
pub struct Part { pub name: String, pub start: u64, pub size: u64 }

/// The partition named `name`.
pub fn named<'a>(parts: &'a [Part], name: &str, disk: &Path) -> Result<&'a Part> {
    match parts.iter().find(|p| p.name == name) {
        Some(p) => Ok(p),
        None => fail(format!("{} has no partition named {name}", disk.display()), "This disk wasn't made for this system, or is damaged."),
    }
}
