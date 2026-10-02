//! Metadata from a descriptor already opened by the native document provider.
//! This entry point is not exposed to extensions and does not grant filesystem roots.

use crate::cancellation::RequestLease;
use crate::tags::{AudioTagsError, check_lease, open_audio_file};
use spotiflac_core::{cover, tags};
use std::sync::Arc;

#[derive(uniffi::Record)]
pub struct DescriptorLibraryMetadata {
    pub metadata_json: String,
    pub cover_bytes: Vec<u8>,
    pub cover_mime: String,
}

/// The caller keeps the descriptor open until this synchronous read returns.
/// Duplicating its descriptor preserves SAF access, including single-open
/// AppFuse proxies, without resolving a protected path or copying the audio.
#[uniffi::export]
pub fn read_library_metadata_from_descriptor(
    descriptor: i32,
    hint: String,
    scan_time: String,
    include_cover: bool,
    lease: Option<Arc<RequestLease>>,
) -> Result<DescriptorLibraryMetadata, AudioTagsError> {
    if descriptor < 0 {
        return Err("invalid audio descriptor".to_owned().into());
    }
    let check = || check_lease(lease.as_deref());
    check()?;
    let directory = if cfg!(any(target_os = "android", target_os = "linux")) {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let path = format!("{directory}/{descriptor}");
    let mut file = open_audio_file(&path)?;
    let format = tags::library_extension(&path, &hint);
    let (metadata, mut artwork) = if include_cover && format == "flac" {
        tags::read_library_metadata_with_cover(&mut file, &path, &hint, &scan_time, 0, &check)?
    } else {
        let metadata = tags::read_library_metadata(&mut file, &path, &hint, &scan_time, 0, &check)?;
        let artwork = if include_cover {
            let format = if matches!(format.as_str(), "mp4" | "aac") {
                "m4a"
            } else {
                &format
            };
            tags::extract_cover(&mut file, format, &check).ok()
        } else {
            None
        };
        (metadata, artwork)
    };
    if let Some(artwork) = artwork.as_mut()
        && let Ok(resized) = cover::library_thumbnail(&artwork.data, &check)
    {
        artwork.mime = if resized.starts_with(b"\x89PNG") {
            "image/png"
        } else if resized.starts_with(b"\xff\xd8") {
            "image/jpeg"
        } else {
            &artwork.mime
        }
        .into();
        artwork.data = resized.to_vec();
    }
    check()?;
    let (cover_bytes, cover_mime) = artwork.map_or_else(
        || (Vec::new(), String::new()),
        |artwork| (artwork.data, artwork.mime),
    );
    Ok(DescriptorLibraryMetadata {
        metadata_json: metadata.to_string(),
        cover_bytes,
        cover_mime,
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::fd::AsRawFd;

    #[test]
    fn descriptor_remains_open_and_audio_does_not_need_a_path_grant() {
        let path = std::env::temp_dir().join(format!("library-fd-{}.wav", std::process::id()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let mut wav = b"RIFF".to_vec();
        wav.extend(38_u32.to_le_bytes());
        wav.extend(b"WAVEfmt ");
        wav.extend(16_u32.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(1_u16.to_le_bytes());
        wav.extend(44100_u32.to_le_bytes());
        wav.extend(88200_u32.to_le_bytes());
        wav.extend(2_u16.to_le_bytes());
        wav.extend(16_u16.to_le_bytes());
        wav.extend(b"data");
        wav.extend(2_u32.to_le_bytes());
        wav.extend(0_i16.to_le_bytes());
        file.write_all(&wav).unwrap();
        drop(file);
        let source = File::open(&path).unwrap();
        let read = read_library_metadata_from_descriptor(
            source.as_raw_fd(),
            "Track.wav".into(),
            "2026-09-30T00:00:00Z".into(),
            true,
            None,
        );
        std::fs::remove_file(path).unwrap();
        let metadata = read.unwrap();
        let json: serde_json::Value = serde_json::from_str(&metadata.metadata_json).unwrap();
        assert_eq!(json["format"], "wav");
        assert_eq!(json["sampleRate"], 44100);
        assert_eq!(json["bitDepth"], 16);
        assert!(metadata.cover_bytes.is_empty());
        assert!(source.metadata().unwrap().is_file());
        assert!(
            read_library_metadata_from_descriptor(-1, "x.flac".into(), "".into(), false, None)
                .is_err()
        );
    }
}
