//! Prüft eine Tauri-Updater-Signatur mit dem in der App-Konfiguration hinterlegten
//! öffentlichen Schlüssel.
//!
//! Der Release-Wrapper ruft dieses Hilfsprogramm vor jedem Upload auf. Es verwendet
//! bewusst dieselbe `minisign-verify`-Crate und Base64-Hülle wie
//! `tauri-plugin-updater`, damit eine veraltete, vertauschte oder fehlerhafte
//! `.sig`-Datei den Release bereits lokal stoppt.

use std::{env, error::Error, ffi::OsString, fs, io, path::PathBuf};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use minisign_verify::{PublicKey, Signature};

/// Gibt ein erforderliches positionales Befehlszeilenargument zurück.
fn required_argument(
    arguments: &mut impl Iterator<Item = OsString>,
    name: &str,
) -> Result<OsString, io::Error> {
    arguments.next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Pflichtargument fehlt: {name}"),
        )
    })
}

/// Dekodiert die in `tauri.conf.json` und `.sig`-Dateien verwendete Base64-Hülle.
fn decode_enveloped_text(value: &str, name: &str) -> Result<String, Box<dyn Error>> {
    let bytes = STANDARD.decode(value.trim()).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{name} ist nicht gültig Base64-kodiert: {error}"),
        )
    })?;
    String::from_utf8(bytes).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{name} enthält keinen gültigen UTF-8-Text: {error}"),
        )
        .into()
    })
}

/// Prüft das vom Release-Wrapper übergebene Installer-/Signatur-/Schlüsseltupel.
fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = env::args_os().skip(1);
    let installer_path = PathBuf::from(required_argument(&mut arguments, "Installer-Pfad")?);
    let signature_path = PathBuf::from(required_argument(&mut arguments, "Signaturpfad")?);
    let config_path = PathBuf::from(required_argument(
        &mut arguments,
        "Pfad zur Tauri-Konfiguration",
    )?);
    if arguments.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unerwartete zusätzliche Argumente.",
        )
        .into());
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
                "Die Tauri-Konfiguration enthält keinen öffentlichen Updater-Schlüssel.",
            )
        })?;
    let public_key_text =
        decode_enveloped_text(public_key_envelope, "Der öffentliche Updater-Schlüssel")?;
    let signature_text = decode_enveloped_text(&signature_envelope, "Die Updater-Signatur")?;
    let public_key = PublicKey::decode(&public_key_text)?;
    let signature = Signature::decode(&signature_text)?;
    public_key.verify(&installer, &signature, true)?;
    Ok(())
}
