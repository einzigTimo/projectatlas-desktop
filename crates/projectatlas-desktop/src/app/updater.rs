//! Purpose: Check for, download, and install a new version of the app.
//!
//! Updates are never forced. The user sees that one exists, reads what changed, and
//! decides when to install — the app only restarts itself once the install finished
//! and the user asked for it.
//!
//! The signing key and release endpoint live in `tauri.conf.json` under
//! `plugins.updater`. While that block is absent — before the Ed25519 key pair exists —
//! every check reports "not configured" in plain German instead of failing silently,
//! so a half-set-up build is obvious rather than mysterious.

use crate::app::error::{AppError, AppResult};
use serde::Serialize;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::Mutex;

/// Event carrying download progress to the update screen.
const EVENT_PROGRESS: &str = "update-progress";

/// Result of one update check.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct UpdateStatusView {
    /// Version this build reports.
    pub(crate) current_version: String,
    /// Whether a newer version is available.
    pub(crate) available: bool,
    /// Version offered by the release endpoint.
    pub(crate) version: Option<String>,
    /// Release notes for the offered version.
    pub(crate) notes: Option<String>,
    /// Publication date reported by the release manifest.
    pub(crate) published: Option<String>,
    /// Set when the updater is not configured yet, explaining why no check ran.
    pub(crate) unconfigured_reason: Option<String>,
}

/// Download progress forwarded to the update screen.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProgressView {
    /// Bytes received so far.
    downloaded: u64,
    /// Total bytes, when the server announced a length.
    total: Option<u64>,
    /// Whether the download finished and the installer took over.
    finished: bool,
}

/// Holds the update found by the last successful check.
///
/// `Update` carries no `Debug`, so this type derives only `Default` and prints
/// nothing useful — it is state, never a diagnostic.
#[derive(Default)]
pub(crate) struct PendingUpdate {
    /// The offered update, kept so the install step does not re-check.
    inner: Mutex<Option<Update>>,
}

impl PendingUpdate {
    /// Store the update offered by a check.
    async fn set(&self, update: Option<Update>) {
        *self.inner.lock().await = update;
    }

    /// Take the stored update, leaving none behind.
    async fn take(&self) -> Option<Update> {
        self.inner.lock().await.take()
    }
}

/// Return this build's own version.
fn current_version(app: &AppHandle) -> String {
    app.package_info().version.to_string()
}

/// Report the version this build carries.
///
/// Exists so the window never states a version that was typed into the markup by hand:
/// a hard-coded number keeps claiming the old release after an update installed.
#[tauri::command]
pub(crate) async fn app_version(app: AppHandle) -> String {
    current_version(&app)
}

/// Build the status reported while no release endpoint or key is configured.
fn unconfigured(app: &AppHandle, reason: &str) -> UpdateStatusView {
    UpdateStatusView {
        current_version: current_version(app),
        available: false,
        version: None,
        notes: None,
        published: None,
        unconfigured_reason: Some(reason.to_string()),
    }
}

/// Ask the release endpoint whether a newer version exists.
///
/// # Errors
///
/// Returns an error when the endpoint is unreachable or its manifest is invalid.
/// A missing updater configuration is reported inside the result, not as an error.
#[tauri::command]
pub(crate) async fn check_for_update(app: AppHandle) -> AppResult<UpdateStatusView> {
    let Ok(updater) = app.updater() else {
        return Ok(unconfigured(
            &app,
            "Die Update-Prüfung ist in dieser Ausgabe noch nicht eingerichtet.",
        ));
    };

    let found = updater.check().await?;
    let status = found.as_ref().map_or_else(
        || UpdateStatusView {
            current_version: current_version(&app),
            available: false,
            version: None,
            notes: None,
            published: None,
            unconfigured_reason: None,
        },
        |update| UpdateStatusView {
            current_version: current_version(&app),
            available: true,
            version: Some(update.version.clone()),
            notes: update.body.clone(),
            published: update.date.map(|date| date.to_string()),
            unconfigured_reason: None,
        },
    );

    app.state::<PendingUpdate>().set(found).await;
    Ok(status)
}

/// Download and install the update found by the last check, then restart.
///
/// # Errors
///
/// Returns an error when no update is pending, the download fails, or the signature
/// does not verify against the public key compiled into this build.
#[tauri::command]
pub(crate) async fn install_update(app: AppHandle) -> AppResult<()> {
    let Some(update) = app.state::<PendingUpdate>().take().await else {
        return Err(AppError::Registry(
            "Es liegt keine geprüfte Aktualisierung bereit. Bitte zuerst nach Updates suchen."
                .to_string(),
        ));
    };

    // The progress callback is synchronous and runs on the download thread, so the
    // running total lives in an atomic rather than an async lock.
    let downloaded = Arc::new(AtomicU64::new(0));
    let counter = Arc::clone(&downloaded);
    let progress_app = app.clone();
    let finish_app = app.clone();
    update
        .download_and_install(
            move |chunk, total| {
                let chunk = chunk as u64;
                let so_far = counter.fetch_add(chunk, Ordering::Relaxed) + chunk;
                drop(progress_app.emit(
                    EVENT_PROGRESS,
                    ProgressView {
                        downloaded: so_far,
                        total,
                        finished: false,
                    },
                ));
            },
            move || {
                drop(finish_app.emit(
                    EVENT_PROGRESS,
                    ProgressView {
                        downloaded: 0,
                        total: None,
                        finished: true,
                    },
                ));
            },
        )
        .await?;

    app.restart();
}
