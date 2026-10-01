//! Duplicate detection retains Go's cache and format-specific ISRC contracts.

mod cache;
mod native_files;
pub use cache::{FileStamp, IndexCache, IndexFiles};
pub use native_files::NativeFiles;

use std::io::{Read, Seek, SeekFrom};

pub fn supported(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "flac" | "mp3" | "m4a" | "ogg" | "opus"
            )
        })
}

pub fn read_isrc(
    reader: &mut (impl Read + Seek),
    format: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    let interrupted = std::cell::RefCell::new(None);
    let checked = || {
        let result = check();
        if let Err(error) = &result {
            *interrupted.borrow_mut() = Some(error.clone());
        }
        result
    };
    checked()?;
    let value = if format == "flac" {
        read_flac(reader, &checked).unwrap_or_default()
    } else if matches!(format, "mp3" | "m4a" | "ogg" | "opus") {
        crate::tags::read_audio_tags(reader, format, &checked)
            .map(|metadata| metadata.isrc.trim().to_owned())
            .unwrap_or_default()
    } else {
        String::new()
    };
    if let Some(error) = interrupted.into_inner() {
        return Err(error);
    }
    check()?;
    Ok(value)
}

fn read_flac(
    reader: &mut (impl Read + Seek),
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    reader.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    let mut header = [0; 4];
    reader.read_exact(&mut header).map_err(|e| e.to_string())?;
    if &header != b"fLaC" {
        return Ok(String::new());
    }
    loop {
        check()?;
        reader.read_exact(&mut header).map_err(|e| e.to_string())?;
        let length = u32::from_be_bytes([0, header[1], header[2], header[3]]);
        if header[0] & 0x7f == 4 {
            let mut payload = vec![0; length as usize];
            for chunk in payload.chunks_mut(64 * 1024) {
                check()?;
                reader.read_exact(chunk).map_err(|e| e.to_string())?;
            }
            return Ok(comment_isrc(&payload, check));
        }
        if header[0] & 0x80 != 0 {
            return Ok(String::new());
        }
        reader
            .seek(SeekFrom::Current(i64::from(length)))
            .map_err(|e| e.to_string())?;
    }
}

fn comment_isrc(mut payload: &[u8], check: &dyn Fn() -> Result<(), String>) -> String {
    fn integer(payload: &mut &[u8]) -> Option<usize> {
        let (value, rest) = payload.split_at_checked(4)?;
        *payload = rest;
        Some(u32::from_le_bytes(value.try_into().ok()?) as usize)
    }
    let mut parse = || {
        let vendor = integer(&mut payload)?;
        payload = payload.get(vendor..)?;
        let count = integer(&mut payload)?;
        for _ in 0..count {
            check().ok()?;
            let length = integer(&mut payload)?;
            let (comment, rest) = payload.split_at_checked(length)?;
            payload = rest;
            let Some(equal) = comment.iter().position(|byte| *byte == b'=') else {
                continue;
            };
            let key = std::str::from_utf8(&comment[..equal]).ok();
            if key.is_some_and(isrc_key) {
                return Some(crate::text::utf8(&comment[equal + 1..]).trim().to_owned());
            }
        }
        None
    };
    parse().unwrap_or_default()
}

fn isrc_key(key: &str) -> bool {
    // EqualFold accepts long s but not dotless i; uppercasing alone differs.
    key.chars().count() == 4
        && key.chars().zip("ISRC".chars()).all(|(actual, expected)| {
            actual.eq_ignore_ascii_case(&expected) || (actual == 'ſ' && expected == 'S')
        })
}
