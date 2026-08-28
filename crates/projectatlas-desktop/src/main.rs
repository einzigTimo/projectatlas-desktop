//! Purpose: Entry point for the `ProjectAtlas` Desktop Windows GUI, no-op on other platforms.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod app;

/// Launch the desktop application on Windows.
///
/// # Errors
///
/// Returns an error when the application window or `WebView` cannot be created.
#[cfg(target_os = "windows")]
fn main() -> Result<(), tauri::Error> {
    app::run()
}

/// Document why there is nothing to run outside Windows: this GUI is Windows-only by design,
/// see `crates/projectatlas-desktop/Cargo.toml` for the platform gating.
#[cfg(not(target_os = "windows"))]
fn main() {}
