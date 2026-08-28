//! Purpose: Background refresh that updates values without ever reloading the view.
//!
//! The loop re-reads the active project frequently and the remaining projects rarely,
//! compares each payload against its stored fingerprint (see `state.rs`), and emits a
//! Tauri event only when something actually changed. The frontend listens and patches
//! the affected text nodes, so an open dashboard never flickers, never scrolls back to
//! the top, and never loses the selected project.
//!
//! Read failures are skipped silently on purpose: a project on a disconnected drive
//! must not spam the window with error toasts every few seconds. Its state becomes
//! visible through the sidebar status on the next scan.

use crate::app::query;
use crate::app::registry::{ProjectStatus, RegistryFile};
use crate::app::state::{
    ACTIVITY_LIMIT, AppState, Payload, ProjectBadge, activity_fingerprint, overview_fingerprint,
    trend_fingerprint,
};
use serde::Serialize;
use std::path::PathBuf;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};

/// How often the active project is re-read.
const ACTIVE_INTERVAL: Duration = Duration::from_secs(4);
/// How many active-project ticks pass between two sidebar badge refreshes.
const BADGE_EVERY_N_TICKS: u32 = 15;

/// Event name for a changed savings overview.
const EVENT_OVERVIEW: &str = "token-overview-updated";
/// Event name for a changed trend report.
const EVENT_TREND: &str = "token-trend-updated";
/// Event name for a changed activity log.
const EVENT_ACTIVITY: &str = "token-activity-updated";
/// Event name for changed sidebar badges.
const EVENT_BADGES: &str = "project-badges-updated";

/// Envelope pairing one payload with the project it belongs to.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectPayload<T> {
    /// Project the payload belongs to.
    project_id: String,
    /// The changed payload itself.
    data: T,
}

/// Run one blocking database read on a worker thread, discarding failures.
async fn read_blocking<T, F>(work: F) -> Option<T>
where
    T: Send + 'static,
    F: FnOnce() -> crate::app::error::AppResult<T> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(work).await.ok()?.ok()
}

/// Load the headline numbers of every reachable project.
pub(crate) async fn collect_badges(registry: RegistryFile) -> Vec<ProjectBadge> {
    let mut badges = Vec::new();
    for project in registry.projects {
        if project.status != ProjectStatus::Ok {
            continue;
        }
        let db_path = project.db_path.clone();
        let root = project.root.clone();
        if let Some(overview) = read_blocking(move || query::overview(&db_path, &root, None)).await
        {
            badges.push(ProjectBadge {
                id: project.id,
                calls: overview.calls,
                saved: overview.saved,
            });
        }
    }
    badges
}

/// Resolve the active project's paths, if one is selected and still registered.
async fn active_paths(state: &AppState) -> Option<(String, PathBuf, PathBuf)> {
    let project_id = state.active_project_id().await?;
    let registry = state.registry().await;
    let project = registry
        .projects
        .iter()
        .find(|project| project.id == project_id)?;
    if project.status != ProjectStatus::Ok {
        return None;
    }
    Some((project_id, project.db_path.clone(), project.root.clone()))
}

/// Re-read the active project and emit only the payloads that changed.
async fn refresh_active(handle: &AppHandle, state: &AppState) {
    let Some((project_id, db_path, root)) = active_paths(state).await else {
        return;
    };

    let overview_db = db_path.clone();
    let overview_root = root.clone();
    let calibration = state.calibration(&project_id).await;
    if let Some(overview) =
        read_blocking(move || query::overview(&overview_db, &overview_root, calibration)).await
        && state
            .record_fingerprint(
                &project_id,
                Payload::Overview,
                overview_fingerprint(&overview),
            )
            .await
    {
        emit(
            handle,
            EVENT_OVERVIEW,
            ProjectPayload {
                project_id: project_id.clone(),
                data: overview,
            },
        );
    }

    let window = state.trend_window().await;
    let trend_db = db_path.clone();
    let trend_root = root.clone();
    if let Some(trend) = read_blocking(move || query::trend(&trend_db, &trend_root, &window)).await
        && state
            .record_fingerprint(&project_id, Payload::Trend, trend_fingerprint(&trend))
            .await
    {
        emit(
            handle,
            EVENT_TREND,
            ProjectPayload {
                project_id: project_id.clone(),
                data: trend,
            },
        );
    }

    if let Some(activity) =
        read_blocking(move || query::recent_activity(&db_path, &root, ACTIVITY_LIMIT)).await
        && state
            .record_fingerprint(
                &project_id,
                Payload::Activity,
                activity_fingerprint(&activity),
            )
            .await
    {
        emit(
            handle,
            EVENT_ACTIVITY,
            ProjectPayload {
                project_id,
                data: activity,
            },
        );
    }
}

/// Emit one event, ignoring a closed-window delivery failure.
fn emit<T: Serialize + Clone>(handle: &AppHandle, event: &str, payload: T) {
    drop(handle.emit(event, payload));
}

/// Start the background refresh loop for the lifetime of the application.
pub(crate) fn spawn(handle: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut ticker = tokio::time::interval(ACTIVE_INTERVAL);
        let mut tick: u32 = 0;
        loop {
            ticker.tick().await;
            let state = handle.state::<AppState>();
            refresh_active(&handle, &state).await;

            tick = tick.wrapping_add(1);
            if tick.is_multiple_of(BADGE_EVERY_N_TICKS) {
                let badges = collect_badges(state.registry().await).await;
                emit(&handle, EVENT_BADGES, badges);
            }
        }
    });
}
