//! Purpose: Wire the Windows desktop application together — state, commands, background refresh.
//!
//! The updater plugin is registered even before `plugins.updater` exists in
//! `tauri.conf.json`: the configuration is only read when a check actually runs, so the
//! app starts normally and reports "not configured yet" instead of refusing to launch.

pub(crate) mod atlas;
pub(crate) mod calibration;
pub(crate) mod commands;
pub(crate) mod error;
pub(crate) mod polling;
pub(crate) mod query;
pub(crate) mod registry;
pub(crate) mod setup;
pub(crate) mod state;
pub(crate) mod updater;
pub(crate) mod view;

use state::AppState;
use updater::PendingUpdate;

/// Build and run the desktop application.
///
/// # Errors
///
/// Returns an error when the Tauri context, window, or `WebView` cannot be created.
pub(crate) fn run() -> Result<(), tauri::Error> {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState::load_or_default())
        .manage(PendingUpdate::default())
        .invoke_handler(tauri::generate_handler![
            commands::list_projects,
            commands::rescan_projects,
            commands::add_project_manual,
            commands::remove_project,
            commands::switch_active_project,
            commands::get_overview,
            commands::get_trend,
            commands::get_recent_activity,
            commands::get_project_badges,
            commands::get_atlas_map,
            commands::calibrate_project,
            commands::get_file_headings,
            commands::list_projects_by_purpose,
            updater::app_version,
            updater::check_for_update,
            updater::install_update,
            setup::detect_ai_tools,
            setup::get_project_connection,
            setup::connect_project,
            setup::connect_all_projects,
        ])
        .setup(|app| {
            polling::spawn(app.handle().clone());
            Ok(())
        })
        .build(tauri::generate_context!())?;
    app.run(|_handle, _event| {});
    Ok(())
}
