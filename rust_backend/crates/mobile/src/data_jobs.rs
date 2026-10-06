//! CPU and file work submitted by Flutter. Platform dispatch owns the worker
//! thread and the cancellation lease; widgets continue to own presentation.
use crate::cancellation::RequestLease;
use crate::manager::ExtensionManager;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, sync::Arc};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum NativeDataJobError {
    #[error("{0}")]
    Operation(String),
}

#[uniffi::export]
pub fn run_native_data_job(
    request_json: String,
    bytes: Vec<u8>,
    lease: Option<Arc<RequestLease>>,
) -> Result<String, NativeDataJobError> {
    run(&request_json, &bytes, lease.as_deref(), None)
}

#[uniffi::export]
impl ExtensionManager {
    pub fn run_native_data_job(
        &self,
        request_json: String,
        bytes: Vec<u8>,
        lease: Option<Arc<RequestLease>>,
    ) -> Result<String, NativeDataJobError> {
        run(&request_json, &bytes, lease.as_deref(), Some(self))
    }
}

fn run(
    request_json: &str,
    bytes: &[u8],
    lease: Option<&RequestLease>,
    manager: Option<&ExtensionManager>,
) -> Result<String, NativeDataJobError> {
    let check = || crate::tags::check_lease(lease);
    check().map_err(NativeDataJobError::Operation)?;
    let request: Value = serde_json::from_str(request_json)
        .map_err(|error| NativeDataJobError::Operation(error.to_string()))?;
    let value = execute(&request, bytes, &check, manager).map_err(NativeDataJobError::Operation)?;
    if value.get("committed") != Some(&Value::Bool(true)) {
        check().map_err(NativeDataJobError::Operation)?;
    }
    serde_json::to_string(&value).map_err(|error| NativeDataJobError::Operation(error.to_string()))
}

fn execute(
    request: &Value,
    _bytes: &[u8],
    check: &(dyn Fn() -> Result<(), String> + Sync),
    _manager: Option<&ExtensionManager>,
) -> Result<Value, String> {
    let operation = string(request, "operation")?;
    match operation {
        "hash_file" => Ok(json!({"sha256": hash_file(string(request, "path")?, check)?})),
        _ => Err(format!("Unknown native data operation: {operation}")),
    }
}

pub(crate) fn string<'a>(request: &'a Value, name: &str) -> Result<&'a str, String> {
    request
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing native data field: {name}"))
}

pub(crate) fn hash_file(
    path: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<String, String> {
    check()?;
    if !std::fs::metadata(path)
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("Hash input must be a regular file".into());
    }
    let mut file = File::open(path).map_err(|error| error.to_string())?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err("Hash input must be a regular file".into());
    }
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    loop {
        check()?;
        let count = file.read(&mut buffer).map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    check()?;
    Ok(hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn hashes_streamed_files_and_obeys_cancellation() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"abc").unwrap();
        assert_eq!(
            hash_file(file.path().to_str().unwrap(), &|| Ok(())).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(hash_file(file.path().to_str().unwrap(), &|| Err("cancelled".into())).is_err());
    }
}
