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

// ── P4 – Heading selectors ────────────────────────────────────────────────────

/// Extract Markdown headings from one indexed file.
///
/// Reads the stored file text (if any) and parses ATX headings (lines starting
/// with one to six `#` characters). Returns an empty list for non-Markdown files
/// or files not present in the text index.
///
/// The anchor slug follows the GitHub Markdown convention: lowercase, spaces
/// replaced with `-`, all characters outside `[a-z0-9-]` removed.
pub(crate) fn file_headings(
    db_path: &Path,
    root: &Path,
    file_path: &str,
) -> AppResult<Vec<crate::app::commands::HeadingEntry>> {
    // Only process Markdown files.
    let lower = file_path.to_lowercase();
    if !lower.ends_with(".md") && !lower.ends_with(".markdown") {
        return Ok(Vec::new());
    }
    let store = open(db_path, root)?;
    let Some(indexed) = store.load_file_text(file_path)? else {
        return Ok(Vec::new());
    };
    Ok(extract_headings(&indexed.content))
}

/// Parse ATX headings out of Markdown source text.
fn extract_headings(text: &str) -> Vec<crate::app::commands::HeadingEntry> {
    text.lines()
        .filter_map(|line| {
            // Count leading `#` characters precisely (char count, not byte count)
            // to avoid overflow on pathological inputs with many `#` characters.
            let level = line.chars().take_while(|c| *c == '#').count();
            if level == 0 || level > 6 {
                return None;
            }
            let rest = &line[level..];
            // The character after the `#` markers must be a space.
            let after = rest.strip_prefix(' ')?;
            let heading_text = after.trim().to_string();
            if heading_text.is_empty() {
                return None;
            }
            let anchor = slug_anchor(&heading_text);
            Some(crate::app::commands::HeadingEntry {
                level: level as u8,
                text: heading_text,
                anchor,
            })
        })
        .collect()
}

/// Derive a GitHub-style anchor slug from a heading text.
///
/// Lowercase, spaces → `-`, retain only `[a-z0-9-]`.
fn slug_anchor(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|ch| if ch == ' ' { '-' } else { ch })
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-')
        .collect()
}

#[cfg(test)]
mod heading_tests {
    use super::{extract_headings, slug_anchor};

    #[test]
    fn slug_spaces_become_dashes() {
        assert_eq!(slug_anchor("Quick Start"), "quick-start");
    }

    #[test]
    fn slug_strips_special_chars() {
        assert_eq!(slug_anchor("What's new?"), "whats-new");
    }

    #[test]
    fn extract_headings_levels() {
        let md = "# Title\n## Section\n### Sub\nNot a heading\n";
        let headings = extract_headings(md);
        assert_eq!(headings.len(), 3);
        assert_eq!(headings[0].level, 1);
        assert_eq!(headings[0].text, "Title");
        assert_eq!(headings[0].anchor, "title");
        assert_eq!(headings[1].level, 2);
        assert_eq!(headings[2].level, 3);
    }

    #[test]
    fn extract_headings_ignores_non_atx() {
        // No space after `#` → not a valid ATX heading.
        let md = "#NoSpace\n# Valid\n";
        let headings = extract_headings(md);
        assert_eq!(headings.len(), 1);
        assert_eq!(headings[0].text, "Valid");
    }

    #[test]
    fn extract_headings_empty_input() {
        assert!(extract_headings("").is_empty());
    }
}
