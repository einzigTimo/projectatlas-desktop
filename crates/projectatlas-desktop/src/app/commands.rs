//! Purpose: Tauri commands — the only bridge between the frontend and the project data.
//!
//! Every database read is dispatched onto a blocking worker so the `WebView` thread
//! never stalls on `SQLite`, and every handler returns `Result<_, AppError>` so a
//! missing project or unreadable database surfaces as a message instead of a panic.
//!
//! The `#[tauri::command]` macro expands into glue that discards a `#[must_use]`
//! value, so `let_underscore_must_use` is allowed for this module only. Nothing
//! hand-written below relies on that allowance.

#![allow(
    clippy::let_underscore_must_use,
    reason = "the tauri::command macro expansion triggers it, not this module's own code"
)]

use crate::app::atlas::AtlasView;
use crate::app::error::{AppError, AppResult};
use crate::app::registry::{self, ProjectSource, ProjectStatus, RegisteredProject};
use crate::app::state::{ACTIVITY_LIMIT, AppState, Payload, ProjectBadge};
use crate::app::view::{ActivityView, OverviewView, TrendView};
use crate::app::{polling, query};
use serde::Serialize;
use std::path::PathBuf;
use tauri::State;

/// Reachability of one project, flattened for the frontend.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ProjectStatusView {
    /// The database opened successfully on the last check.
    Ok,
    /// The database file no longer exists at the recorded path.
    NotFound,
    /// The database exists but failed to open.
    OpenError,
}

/// One project as shown in the sidebar.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectView {
    /// Stable identifier derived from the project root.
    pub(crate) id: String,
    /// Project root folder as a display string.
    pub(crate) root: String,
    /// Name shown in the sidebar.
    pub(crate) display_name: String,
    /// Whether the entry was auto-discovered or added manually.
    pub(crate) manual: bool,
    /// Reachability of the project database.
    pub(crate) status: ProjectStatusView,
    /// Failure reason when the status is [`ProjectStatusView::OpenError`].
    pub(crate) status_message: Option<String>,
}

/// The sidebar payload: all known projects plus the current selection.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectListView {
    /// Known projects in registry order.
    pub(crate) projects: Vec<ProjectView>,
    /// Id of the project currently displayed, if any.
    pub(crate) active_project_id: Option<String>,
}

/// Project one registry entry onto the sidebar shape.
fn project_view(project: &RegisteredProject) -> ProjectView {
    let (status, status_message) = match &project.status {
        ProjectStatus::Ok => (ProjectStatusView::Ok, None),
        ProjectStatus::NotFound => (ProjectStatusView::NotFound, None),
        ProjectStatus::OpenError { message } => {
            (ProjectStatusView::OpenError, Some(message.clone()))
        }
    };
    ProjectView {
        id: project.id.clone(),
        root: project.root.display().to_string(),
        display_name: project.display_name.clone(),
        manual: project.source == ProjectSource::Manual,
        status,
        status_message,
    }
}

/// Resolve one project id to the paths its queries need.
async fn locate(state: &State<'_, AppState>, project_id: &str) -> AppResult<(PathBuf, PathBuf)> {
    let registry = state.registry().await;
    let project = registry::find(&registry, project_id)?;
    Ok((project.db_path.clone(), project.root.clone()))
}

/// Run one blocking database read on a worker thread.
async fn blocking<T, F>(work: F) -> AppResult<T>
where
    T: Send + 'static,
    F: FnOnce() -> AppResult<T> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| AppError::Background(error.to_string()))?
}

/// Build the current sidebar payload.
pub(crate) async fn project_list(state: &State<'_, AppState>) -> ProjectListView {
    let registry = state.registry().await;
    ProjectListView {
        projects: registry.projects.iter().map(project_view).collect(),
        active_project_id: state.active_project_id().await,
    }
}

/// List every known project without touching the filesystem.
///
/// # Errors
///
/// Never fails today; the result stays fallible so the frontend contract survives
/// a future registry read that can fail.
#[tauri::command]
pub(crate) async fn list_projects(state: State<'_, AppState>) -> AppResult<ProjectListView> {
    Ok(project_list(&state).await)
}

/// Re-scan the configured roots and re-check every known project.
///
/// # Errors
///
/// Returns an error when the registry cannot be read or written.
#[tauri::command]
pub(crate) async fn rescan_projects(state: State<'_, AppState>) -> AppResult<ProjectListView> {
    let mut registry = state.registry().await;
    let scanned = blocking(move || {
        registry::rescan(&mut registry)?;
        Ok(registry)
    })
    .await?;
    state.set_registry(scanned).await;
    Ok(project_list(&state).await)
}

/// Register a project folder the user picked manually.
///
/// # Errors
///
/// Returns an error when the folder holds no `ProjectAtlas` database or the
/// registry cannot be written.
#[tauri::command]
pub(crate) async fn add_project_manual(
    state: State<'_, AppState>,
    path: String,
) -> AppResult<ProjectListView> {
    let mut registry = state.registry().await;
    let root = PathBuf::from(path);
    let updated = blocking(move || {
        registry::add_manual(&mut registry, &root)?;
        Ok(registry)
    })
    .await?;
    state.set_registry(updated).await;
    Ok(project_list(&state).await)
}

/// Remove one project from the registry.
///
/// # Errors
///
/// Returns an error when the id is unknown or the registry cannot be written.
#[tauri::command]
pub(crate) async fn remove_project(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<ProjectListView> {
    let mut registry = state.registry().await;
    let id = project_id.clone();
    let updated = blocking(move || {
        registry::remove(&mut registry, &id)?;
        Ok(registry)
    })
    .await?;
    state.forget_fingerprints(&project_id).await;
    state.set_registry(updated).await;
    Ok(project_list(&state).await)
}

/// Switch which project the content area shows.
///
/// # Errors
///
/// Returns an error when the id is unknown.
#[tauri::command]
pub(crate) async fn switch_active_project(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<ProjectListView> {
    let registry = state.registry().await;
    registry::find(&registry, &project_id)?;
    state.set_active_project_id(project_id).await;
    Ok(project_list(&state).await)
}

/// Load one project's all-time savings overview.
///
/// # Errors
///
/// Returns an error when the id is unknown or the database cannot be read.
#[tauri::command]
pub(crate) async fn get_overview(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<OverviewView> {
    let (db_path, root) = locate(&state, &project_id).await?;
    let calibration = state.calibration(&project_id).await;
    let overview = blocking(move || query::overview(&db_path, &root, calibration)).await?;
    state
        .record_fingerprint(
            &project_id,
            Payload::Overview,
            crate::app::state::overview_fingerprint(&overview),
        )
        .await;
    Ok(overview)
}

/// Load one project's retained savings trend for the requested window.
///
/// # Errors
///
/// Returns an error when the id is unknown or the database cannot be read.
#[tauri::command]
pub(crate) async fn get_trend(
    state: State<'_, AppState>,
    project_id: String,
    window: String,
) -> AppResult<TrendView> {
    let (db_path, root) = locate(&state, &project_id).await?;
    state.set_trend_window(window.clone()).await;
    let trend = blocking(move || query::trend(&db_path, &root, &window)).await?;
    state
        .record_fingerprint(
            &project_id,
            Payload::Trend,
            crate::app::state::trend_fingerprint(&trend),
        )
        .await;
    Ok(trend)
}

/// Load one project's most recent calls, newest first.
///
/// # Errors
///
/// Returns an error when the id is unknown or the database cannot be read.
#[tauri::command]
pub(crate) async fn get_recent_activity(
    state: State<'_, AppState>,
    project_id: String,
    limit: Option<u32>,
) -> AppResult<Vec<ActivityView>> {
    let (db_path, root) = locate(&state, &project_id).await?;
    let limit = limit.unwrap_or(ACTIVITY_LIMIT).clamp(1, 500);
    let activity = blocking(move || query::recent_activity(&db_path, &root, limit)).await?;
    state
        .record_fingerprint(
            &project_id,
            Payload::Activity,
            crate::app::state::activity_fingerprint(&activity),
        )
        .await;
    Ok(activity)
}

/// Load one project's bounded relationship preview for the Atlas Map panel.
///
/// # Errors
///
/// Returns an error when the id is unknown or the database cannot be opened. A
/// project without a published relation graph yields an unavailable view, not an
/// error.
#[tauri::command]
pub(crate) async fn get_atlas_map(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<AtlasView> {
    let (db_path, root) = locate(&state, &project_id).await?;
    blocking(move || crate::app::atlas::atlas_map(&db_path, &root)).await
}

/// Load the headline numbers of every reachable project for the sidebar badges.
///
/// # Errors
///
/// Never fails as a whole: projects that cannot be read are omitted instead of
/// failing the badge refresh for all of them.
#[tauri::command]
pub(crate) async fn get_project_badges(state: State<'_, AppState>) -> AppResult<Vec<ProjectBadge>> {
    let registry = state.registry().await;
    Ok(polling::collect_badges(registry).await)
}

/// Measure one project's indexed text with a real local tokenizer.
///
/// This walks every indexed UTF-8 file and tokenizes it, so it is deliberately a
/// separate, user-triggered command rather than part of the silent refresh. The result
/// is kept in the app state and attached to every later overview of that project.
///
/// # Errors
///
/// Returns an error when the id is unknown, the database cannot be read, or the
/// tokenizer name is not one this build supports.
#[tauri::command]
pub(crate) async fn calibrate_project(
    state: State<'_, AppState>,
    project_id: String,
    tokenizer: String,
) -> AppResult<OverviewView> {
    let (db_path, root) = locate(&state, &project_id).await?;

    let calibration_tokenizer = tokenizer.clone();
    let calibration_db = db_path.clone();
    let calibration_root = root.clone();
    let calibration = blocking(move || {
        query::calibrate(&calibration_db, &calibration_root, &calibration_tokenizer)
    })
    .await?;

    state
        .set_calibration(project_id.clone(), calibration.clone())
        .await;

    let overview = blocking(move || query::overview(&db_path, &root, Some(calibration))).await?;
    state
        .record_fingerprint(
            &project_id,
            Payload::Overview,
            crate::app::state::overview_fingerprint(&overview),
        )
        .await;
    Ok(overview)
}
