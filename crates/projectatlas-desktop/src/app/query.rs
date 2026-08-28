//! Purpose: Blocking read-only queries against one project's `ProjectAtlas` database.
//!
//! Every function opens its own short-lived read-only store instead of caching an
//! open connection in shared state: `AtlasStore` wraps a `SQLite` connection that is
//! not shareable across threads, and a read-only open is cheap compared to the
//! report query itself. Callers must run these off the UI thread (see `commands.rs`).

use crate::app::error::{AppError, AppResult};
use crate::app::view::{ActivityView, OverviewView, TrendView};
use projectatlas_core::telemetry::TokenCalibrationOverview;
use projectatlas_db::AtlasStore;
use projectatlas_service::{TokenReport, TokenReportRequest, load_token_report};
use std::path::Path;

/// Open one project's database for bounded read-only queries.
fn open(db_path: &Path, root: &Path) -> AppResult<AtlasStore> {
    Ok(AtlasStore::open_read_only_for_project(db_path, root)?)
}

/// Load the all-time savings overview for one project.
///
/// `calibration` is attached when the user has already had this project measured with a
/// real tokenizer; it is never computed here, because walking the whole index would make
/// the poll loop unusably slow (see `calibration::build`).
pub(crate) fn overview(
    db_path: &Path,
    root: &Path,
    calibration: Option<TokenCalibrationOverview>,
) -> AppResult<OverviewView> {
    let store = open(db_path, root)?;
    let report = load_token_report(
        &store,
        TokenReportRequest::Overview {
            caller_label: None,
            benchmark_results: None,
        },
    )?;
    match report {
        TokenReport::Overview(mut overview) => {
            if let Some(calibration) = calibration {
                overview.set_calibration(calibration);
            }
            let mut view = OverviewView::from_core(&overview);
            view.claude_mcp_registered = claude_mcp_registered(root);
            Ok(view)
        }
        TokenReport::Trends(_) => Err(AppError::UnexpectedReport("Overview")),
    }
}

/// Best-effort check whether Claude Code will load the `projectatlas` MCP server.
///
/// Claude Code only auto-loads `<root>/.mcp.json`; the configs generated under
/// `.projectatlas/` are not enough on their own. This never errors: an absent,
/// unreadable, or invalid file counts as "not registered" so the overview can
/// show its setup hint instead of silent zeros. A user-scoped registration
/// stored outside the project cannot be detected here, which is why the hint
/// is only shown while the project has zero recorded calls.
fn claude_mcp_registered(root: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(root.join(".mcp.json")) else {
        return false;
    };
    serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|document| {
            document
                .get("mcpServers")
                .and_then(|servers| servers.get("projectatlas"))
                .map(|_| true)
        })
        .unwrap_or(false)
}

/// Count one project's indexed text with a real tokenizer.
///
/// # Errors
///
/// Returns an error when the database cannot be opened or the tokenizer is unknown.
pub(crate) fn calibrate(
    db_path: &Path,
    root: &Path,
    tokenizer: &str,
) -> AppResult<TokenCalibrationOverview> {
    let store = open(db_path, root)?;
    crate::app::calibration::build(&store, tokenizer)
}

/// Load the retained savings trend for one project and calendar window.
pub(crate) fn trend(db_path: &Path, root: &Path, window: &str) -> AppResult<TrendView> {
    let store = open(db_path, root)?;
    let report = load_token_report(
        &store,
        TokenReportRequest::Trends {
            caller_label: None,
            window: crate::app::view::parse_window(window),
        },
    )?;
    match report {
        TokenReport::Trends(trends) => Ok(TrendView::from_core(&trends)),
        TokenReport::Overview(_) => Err(AppError::UnexpectedReport("Trends")),
    }
}

/// Load the most recent calls for one project, newest first.
pub(crate) fn recent_activity(
    db_path: &Path,
    root: &Path,
    limit: u32,
) -> AppResult<Vec<ActivityView>> {
    let store = open(db_path, root)?;
    Ok(store
        .recent_usage_events(None, limit)?
        .iter()
        .map(ActivityView::from_core)
        .collect())
}
