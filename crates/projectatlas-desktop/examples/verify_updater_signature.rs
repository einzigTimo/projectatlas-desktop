//! Verify one Tauri updater signature with the public key embedded in the app config.
//!
//! The release wrapper invokes this helper before any upload. It deliberately uses the
//! same `minisign-verify` crate and base64 envelope as `tauri-plugin-updater` so a stale,
//! swapped, or malformed `.sig` file stops the release locally.

use std::{env, error::Error, ffi::OsString, fs, io, path::PathBuf};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use minisign_verify::{PublicKey, Signature};

/// Return one required positional command-line argument.
fn required_argument(
    arguments: &mut impl Iterator<Item = OsString>,
    name: &str,
) -> Result<OsString, io::Error> {
    arguments
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("missing {name}")))
}

/// Decode the base64 envelope used in `tauri.conf.json` and `.sig` files.
fn decode_enveloped_text(value: &str, name: &str) -> Result<String, Box<dyn Error>> {
    let bytes = STANDARD.decode(value.trim()).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{name} is not valid base64: {error}"),
        )
    })?;
    String::from_utf8(bytes).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{name} does not contain UTF-8 text: {error}"),
        )
        .into()
    })
}

/// Verify the exact installer/signature/public-key tuple supplied by the release wrapper.
fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = env::args_os().skip(1);
    let installer_path = PathBuf::from(required_argument(&mut arguments, "installer path")?);
    let signature_path = PathBuf::from(required_argument(&mut arguments, "signature path")?);
    let config_path = PathBuf::from(required_argument(&mut arguments, "Tauri config path")?);
    if arguments.next().is_some() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "unexpected arguments").into());
    }

    let installer = fs::read(&installer_path)?;
    let signature_envelope = fs::read_to_string(&signature_path)?;
    let config: serde_json::Value = serde_json::from_slice(&fs::read(&config_path)?)?;
    let public_key_envelope = config
        .pointer("/plugins/updater/pubkey")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Tauri config has no updater public key",
            )
        })?;
    let public_key_text = decode_enveloped_text(public_key_envelope, "updater public key")?;
    let signature_text = decode_enveloped_text(&signature_envelope, "updater signature")?;
    let public_key = PublicKey::decode(&public_key_text)?;
    let signature = Signature::decode(&signature_text)?;
    public_key.verify(&installer, &signature, true)?;
    Ok(())
}
