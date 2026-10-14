//! U-Boot's settings (its "environment"; the user sees "start-up settings"), as TrimUI's U-Boot
//! keeps them in the env and env-redund partitions, in U-Boot's redundant format (as
//! tools/sdboot/mkenv.py writes it): the CRC-32 of bytes 5 to the end at 0, a flags byte at 4,
//! then NUL-separated "key=value" strings, ending with an empty one.

use crate::report::{Result, fail};

/// U-Boot's settings size on the Brick.
pub const SIZE: usize = 0x20000;

/// The settings in `image` (at least `SIZE` bytes, CRC checked) with `key` set to `value`.
pub fn set(image: &[u8], key: &str, value: &str) -> Result<Vec<u8>> {
    let d = &image[..SIZE.min(image.len())];
    if d.len() < SIZE || u32::from_le_bytes(d[..4].try_into().unwrap()) != crc32fast::hash(&d[5..]) {
        return fail("the start-up settings on the SD card are damaged (bad checksum)", "Write a fresh SD card.");
    }
    let mut pairs: Vec<(String, String)> = d[5..].split(|&b| b == 0).take_while(|s| !s.is_empty())
        .map(|s| { let s = String::from_utf8_lossy(s); let (k, v) = s.split_once('=').unwrap_or((&s, "")); (k.into(), v.into()) })
        .collect();
    match pairs.iter_mut().find(|(k, _)| k == key) {
        Some(p) => p.1 = value.into(),
        None => pairs.push((key.into(), value.into())),
    }
    let mut data: Vec<u8> = pairs.iter().flat_map(|(k, v)| format!("{k}={v}\0").into_bytes()).collect();
    data.push(0);
    if data.len() > SIZE - 5 { return fail("the start-up settings don't fit", crate::report::SEE_LOG); }
    data.resize(SIZE - 5, 0);
    let mut out = crc32fast::hash(&data).to_le_bytes().to_vec();
    out.push(d[4]); // the flags byte, as it was
    out.extend(data);
    Ok(out)
}

/// The value of `key` in the settings `image`, if set.
#[cfg(test)]
pub fn get(image: &[u8], key: &str) -> Option<String> {
    image.get(5..SIZE)?.split(|&b| b == 0).take_while(|s| !s.is_empty())
        .find_map(|s| String::from_utf8_lossy(s).strip_prefix(&format!("{key}=")).map(str::to_string))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(pairs: &[&str]) -> Vec<u8> {
        let mut data: Vec<u8> = pairs.iter().flat_map(|p| format!("{p}\0").into_bytes()).collect();
        data.push(0);
        data.resize(SIZE - 5, 0);
        let mut out = crc32fast::hash(&data).to_le_bytes().to_vec();
        out.push(1);
        out.extend(data);
        out
    }

    #[test]
    fn replaces_a_value_and_keeps_the_rest() {
        let new = set(&image(&["bootcmd=run x", "mmc_root=UUID=old", "a=b"]), "mmc_root", "UUID=new").unwrap();
        assert_eq!(new.len(), SIZE);
        assert_eq!(u32::from_le_bytes(new[..4].try_into().unwrap()), crc32fast::hash(&new[5..]));
        assert_eq!((get(&new, "mmc_root").as_deref(), get(&new, "bootcmd").as_deref(), get(&new, "a").as_deref()),
                   (Some("UUID=new"), Some("run x"), Some("b")));
    }

    #[test]
    fn refuses_damaged_settings() {
        let mut bad = image(&["a=b"]);
        bad[10] ^= 1;
        assert!(set(&bad, "a", "c").is_err());
    }
}
