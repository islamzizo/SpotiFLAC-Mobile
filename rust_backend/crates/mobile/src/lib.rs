//! Migration APIs. Instances here are not connected to the app's Go-owned work.

mod cancellation;
mod extensions;
mod ffmpeg;
mod filename;
mod hires;
mod library_metadata;
mod logging;
mod lyrics;
mod manager;
mod metadata;
mod progress;
mod repository;
mod tags;
mod usb_audio;

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn sanitize_filename(filename: String) -> String {
    spotiflac_core::filename::sanitize_filename(&filename)
}
