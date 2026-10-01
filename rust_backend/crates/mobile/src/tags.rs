use crate::cancellation::RequestLease;
use crate::manager::{ExtensionManager, ExtensionManagerError};
use spotiflac_core::tags;
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::sync::Arc;

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum AudioTagsError {
    #[error("{message}")]
    Read { message: String },
}

impl From<String> for AudioTagsError {
    fn from(message: String) -> Self {
        Self::Read { message }
    }
}

#[uniffi::export]
impl ExtensionManager {
    pub fn set_library_cover_cache_directory(
        &self,
        directory: String,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .set_library_cover_cache_directory(&directory)
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn read_audio_metadata(
        &self,
        path: String,
        hint: String,
        cache_key: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .read_audio_metadata(&path, &hint, &cache_key, &|| check_lease(lease.as_deref()))
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn parse_cue_file_json(
        &self,
        path: String,
        audio_directory: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .parse_cue_file_json(&path, &audio_directory, &|| check_lease(lease.as_deref()))
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn parse_cue_file_json_with_resolved_audio(
        &self,
        path: String,
        audio_path: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .parse_cue_file_json_with_resolved_audio(&path, &audio_path, &|| {
                check_lease(lease.as_deref())
            })
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn scan_cue_file_for_library(
        &self,
        path: String,
        audio_directory: String,
        virtual_prefix: String,
        mod_time: i64,
        cache_key: String,
        scan_time: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .scan_cue_file_for_library(
                &path,
                &audio_directory,
                &virtual_prefix,
                mod_time,
                &cache_key,
                &scan_time,
                &|| check_lease(lease.as_deref()),
            )
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn scan_library_folder_incremental(
        &self,
        folder: String,
        existing_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .scan_library_folder_incremental(&folder, &existing_json, &|| {
                check_lease(lease.as_deref())
            })
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn scan_library_folder_incremental_from_snapshot(
        &self,
        folder: String,
        snapshot: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .scan_library_folder_incremental_from_snapshot(&folder, &snapshot, &|| {
                check_lease(lease.as_deref())
            })
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn scan_library_folder_to_ndjson_file(
        &self,
        folder: String,
        output: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<u64, ExtensionManagerError> {
        self.inner
            .scan_library_folder_to_ndjson_file(&folder, &output, &|| check_lease(lease.as_deref()))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn get_library_scan_progress(&self) -> Result<String, ExtensionManagerError> {
        self.inner
            .get_library_scan_progress()
            .map(|value| value.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn cancel_library_scan(&self) -> Result<(), ExtensionManagerError> {
        self.inner
            .cancel_library_scan()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn pause_library_scan(&self) -> Result<(), ExtensionManagerError> {
        self.inner
            .pause_library_scan()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn resume_library_scan(&self) -> Result<(), ExtensionManagerError> {
        self.inner
            .resume_library_scan()
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn rewrite_split_artist_tags(
        &self,
        path: String,
        artist: String,
        album_artist: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .rewrite_split_artist_tags(&path, &artist, &album_artist, &|| {
                check_lease(lease.as_deref())
            })
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn extract_cover_to_file(
        &self,
        audio_path: String,
        output_path: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .extract_cover_to_file(&audio_path, &output_path, &|| check_lease(lease.as_deref()))
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn download_cover_to_file_sized(
        &self,
        url: String,
        output_path: String,
        max_dimension: i64,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<(), ExtensionManagerError> {
        self.inner
            .download_cover_to_file_sized(&url, &output_path, max_dimension, &|| {
                check_lease(lease.as_deref())
            })
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn edit_file_metadata(
        &self,
        path: String,
        metadata_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .edit_file_metadata(&path, &metadata_json, &|| check_lease(lease.as_deref()))
            .map(|result| result.to_string())
            .map_err(ExtensionManagerError::Operation)
    }

    pub fn write_m4a_freeform_tags(
        &self,
        path: String,
        metadata_json: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        let check = || check_lease(lease.as_deref());
        check().map_err(ExtensionManagerError::Operation)?;
        let fields = decode_fields(&metadata_json).map_err(|error| {
            ExtensionManagerError::Operation(format!("invalid metadata JSON: {error}"))
        })?;
        self.inner
            .edit_m4a_freeform(&path, &fields, false, &check)
            .map_err(|error| {
                ExtensionManagerError::Operation(format!(
                    "failed to write M4A freeform tags: {error}"
                ))
            })?;
        Ok(r#"{"success":true,"method":"native_m4a_freeform"}"#.into())
    }

    pub fn ensure_ac4_config(
        &self,
        path: String,
        reference: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        self.inner
            .ensure_ac4_config(&path, &reference, &|| check_lease(lease.as_deref()))
            .map_err(|error| {
                ExtensionManagerError::Operation(format!(
                    "failed to finalize AC-4 container: {error}"
                ))
            })?;
        Ok(r#"{"success":true}"#.into())
    }

    pub fn write_ac4_metadata(
        &self,
        path: String,
        metadata_json: String,
        cover_path: String,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, ExtensionManagerError> {
        let handled = self
            .inner
            .write_ac4_metadata(&path, &metadata_json, &cover_path, &|| {
                check_lease(lease.as_deref())
            })
            .map_err(|error| {
                ExtensionManagerError::Operation(format!("failed to write AC-4 metadata: {error}"))
            })?;
        Ok(serde_json::json!({"success":true,"handled":handled}).to_string())
    }
}

fn decode_fields(json: &str) -> Result<BTreeMap<String, String>, String> {
    let fields: Option<BTreeMap<String, Option<String>>> =
        serde_json::from_str(json).map_err(|error| error.to_string())?;
    Ok(fields
        .unwrap_or_default()
        .into_iter()
        .map(|(key, value)| (key, value.unwrap_or_default()))
        .collect())
}

/// Complete application metadata. An empty hint is equivalent to the legacy
/// ReadFileMetadata call. Native callers retain ownership of any platform
/// descriptor referenced by `path` until this synchronous operation returns.
#[uniffi::export]
pub fn read_file_metadata(
    path: String,
    hint: String,
    lease: Option<Arc<RequestLease>>,
) -> Result<String, AudioTagsError> {
    let check = || check_lease(lease.as_deref());
    check()?;
    tags::file_metadata_extension(&path, &hint)?;
    let mut file = open_audio_file(&path)?;
    let metadata = tags::read_file_metadata(&mut file, &path, &hint, &check)?;
    serde_json::to_string(&metadata).map_err(|error| error.to_string().into())
}

pub(crate) fn check_lease(lease: Option<&RequestLease>) -> Result<(), String> {
    lease.map_or(Ok(()), |lease| {
        lease
            .inner
            .check_active()
            .map_err(|error| error.to_string())
    })
}

pub(crate) fn open_audio_file(path: &str) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Opening an accidentally supplied FIFO must not block cancellation.
        options.custom_flags(rustix::fs::OFlags::NONBLOCK.bits() as i32);
    }
    let file = options.open(path).map_err(|error| error.to_string())?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("audio tags require a regular file".into());
    }
    Ok(file)
}
