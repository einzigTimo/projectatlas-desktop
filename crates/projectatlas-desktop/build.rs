//! Purpose: Run the Tauri asset/resource build step on Windows, no-op elsewhere.

#[cfg(target_os = "windows")]
fn main() {
    tauri_build::build();
}

#[cfg(not(target_os = "windows"))]
fn main() {}
