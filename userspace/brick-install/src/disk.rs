//! A whole disk (the internal storage or the SD card), as a device or an image file: reads and
//! writes at byte offsets, and its partition table (through sfdisk).

use std::fs::{File, OpenOptions};
use std::io::Seek;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

use crate::report::{Context, Report, Result, SEE_LOG, fail};

pub const SECTOR: u64 = 512;
/// How much is read or written at a time.
pub const CHUNK: usize = 4 << 20;

pub struct Disk { pub path: PathBuf, file: File, pub size: u64 }

impl Disk {
    pub fn open(path: &Path, write: bool) -> Result<Self> {
        let file = OpenOptions::new().read(true).write(write).open(path).ctx(&format!("opening {}", path.display()))?;
        // Seeking to the end gives the size of a device as well as of a file.
        let size = (&file).seek(std::io::SeekFrom::End(0)).ctx(&format!("finding the size of {}", path.display()))?;
        Ok(Self { path: path.into(), file, size })
    }

    pub fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>> {
        let mut buf = vec![0; len];
        self.file.read_exact_at(&mut buf, offset).ctx(&format!("reading {} at byte {offset}", self.path.display()))?;
        Ok(buf)
    }

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

    /// The names of the partitions in its GPT, if it has one (its header in sector 1; the backup
    /// header at the end isn't looked at).
    pub fn gpt_names(&self) -> Option<Vec<String>> {
        let h = self.read_at(SECTOR, SECTOR as usize).ok()?;
        if !h.starts_with(b"EFI PART") { return None; }
        let le32 = |b: &[u8], at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap());
        let (at, count, size) = (u64::from_le_bytes(h[72..80].try_into().unwrap()), le32(&h, 80) as usize, le32(&h, 84) as usize);
        if !(128..=4096).contains(&size) || count > 1024 { return None; }
        let entries = self.read_at(at * SECTOR, count * size).ok()?;
        Some(entries.chunks(size).filter(|e| e[..16].iter().any(|&b| b != 0)).map(|e| {
            // The name: up to 36 UTF-16 units from byte 56, ending at the first 0.
            let units: Vec<u16> = e[56..128].chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|&u| u != 0).collect();
            String::from_utf16_lossy(&units)
        }).collect())
    }

    pub fn zero(&self, offset: u64, len: u64) -> Result<()> { self.write_at(offset, &vec![0; len as usize]) }

    /// Makes everything written so far reach the storage.
    pub fn sync(&self) -> Result<()> { self.file.sync_all().ctx(&format!("flushing {}", self.path.display())) }
}

/// A partition: its GPT name, and where it is, in bytes.
pub struct Part { pub name: String, pub start: u64, pub size: u64 }

/// The disk's partitions, from its GPT (through sfdisk, which reads devices and files alike).
pub fn partitions(path: &Path, report: &mut Report) -> Result<Vec<Part>> {
    let json = report.run("sfdisk", &["--json", &path.to_string_lossy()])?;
    let v: serde_json::Value = serde_json::from_str(&json).ctx("reading sfdisk's partition list")?;
    let parts = v["partitiontable"]["partitions"].as_array().cloned().unwrap_or_default();
    Ok(parts.iter().map(|p| Part {
        name: p["name"].as_str().unwrap_or_default().into(),
        start: p["start"].as_u64().unwrap_or(0) * SECTOR,
        size: p["size"].as_u64().unwrap_or(0) * SECTOR,
    }).collect())
}

/// The partition named `name`.
pub fn named<'a>(parts: &'a [Part], name: &str, disk: &Path) -> Result<&'a Part> {
    match parts.iter().find(|p| p.name == name) {
        Some(p) => Ok(p),
        None => fail(format!("{} has no partition named {name}", disk.display()), "This SD card wasn't made for this system, or is damaged: write a fresh one."),
    }
}
