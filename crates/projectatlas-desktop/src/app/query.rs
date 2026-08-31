//! Purpose: Blocking read-only queries against one project's `ProjectAtlas` database.
//!
//! Every function opens its own short-lived read-only store instead of caching an
//! open connection in shared state: `AtlasStore` wraps a `SQLite` connection that is
//! not shareable across threads, and a read-only open is cheap compared to the
//! report query itself. Callers must run these off the UI thread (see `commands.rs`).

use crate::app::error::{AppError, AppResult};
use crate::app::view::{ActivityView, OverviewView, TrendView};
use projectatlas_core::graph::RepositoryNodePath;
use projectatlas_core::symbols::{CodeSymbol, SymbolKind};
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

/// Return whether one project has a current purpose containing `query`.
pub(crate) fn project_matches_purpose(db_path: &Path, root: &Path, query: &str) -> AppResult<bool> {
    let store = open(db_path, root)?;
    Ok(store.has_purpose_text_match(query)?)
}

// ── P4 – Heading selectors ────────────────────────────────────────────────────

/// Maximum persisted headings returned for one document picker.
const MAX_HEADING_SELECTORS: usize = 512;

/// Load Markdown headings already parsed and persisted for one indexed file.
///
/// The symbol index owns Setext handling, Unicode slugs, duplicate-heading
/// suffixes, and exact source locations. Reading those persisted symbols keeps
/// the desktop result identical to agent navigation and avoids reparsing text.
pub(crate) fn file_headings(
    db_path: &Path,
    root: &Path,
    file_path: &str,
) -> AppResult<Vec<crate::app::commands::HeadingEntry>> {
    // Only process Markdown files.
    let markdown_extension = Path::new(file_path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            ["md", "markdown", "mdx"]
                .iter()
                .any(|candidate| extension.eq_ignore_ascii_case(candidate))
        });
    if !markdown_extension {
        return Ok(Vec::new());
    }
    let normalized = RepositoryNodePath::new(Path::new(file_path)).map_err(|error| {
        AppError::Registry(format!("Ungueltiger Repository-Pfad {file_path}: {error}"))
    })?;
    let store = open(db_path, root)?;
    Ok(store
        .load_symbols_by_kinds(
            normalized.as_str(),
            &[SymbolKind::Heading],
            MAX_HEADING_SELECTORS,
        )?
        .into_iter()
        .map(|symbol| heading_entry(normalized.as_str(), symbol))
        .collect())
}

/// Project one persisted heading symbol onto the desktop selector shape.
fn heading_entry(file_path: &str, symbol: CodeSymbol) -> crate::app::commands::HeadingEntry {
    let normalized_path = file_path.replace('\\', "/");
    let anchor = symbol.signature;
    crate::app::commands::HeadingEntry {
        level: heading_level(symbol.detail.as_deref()),
        text: symbol.name,
        selector: format!("{normalized_path}#{anchor}"),
        anchor,
        line: symbol.line_start,
    }
}

/// Read the Markdown heading level encoded by the canonical symbol parser.
fn heading_level(detail: Option<&str>) -> u8 {
    detail
        .and_then(|detail| {
            detail
                .split(';')
                .find_map(|part| part.strip_prefix("level=")?.parse::<u8>().ok())
        })
        .filter(|level| (1..=6).contains(level))
        .unwrap_or(1)
}

#[cfg(test)]
mod heading_tests {
    use super::{heading_entry, heading_level};
    use projectatlas_core::symbols::{CodeSymbol, ParserKind, SymbolKind};

    fn heading_symbol(name: &str, signature: &str, line: usize, level: u8) -> CodeSymbol {
        CodeSymbol {
            path: "docs/guide.md".to_string(),
            language: Some("markdown".to_string()),
            name: name.to_string(),
            kind: SymbolKind::Heading,
            signature: signature.to_string(),
            exported: false,
            documentation: None,
            line_start: line,
            line_end: line,
            source_selector: None,
            parent: None,
            parser: ParserKind::Structural,
            detail: Some(format!("level={level};slug={signature};occurrence=1")),
        }
    }

    #[test]
    fn persisted_unicode_and_duplicate_signatures_become_exact_selectors() {
        let first = heading_entry(
            "docs\\guide.md",
            heading_symbol("Über Atlas", "über-atlas", 1, 1),
        );
        let duplicate = heading_entry(
            "docs\\guide.md",
            heading_symbol("Über Atlas", "über-atlas-1", 3, 2),
        );
        assert_eq!(first.level, 1);
        assert_eq!(first.text, "Über Atlas");
        assert_eq!(first.selector, "docs/guide.md#über-atlas");
        assert_eq!(duplicate.level, 2);
        assert_eq!(duplicate.anchor, "über-atlas-1");
        assert_eq!(duplicate.selector, "docs/guide.md#über-atlas-1");
    }

    #[test]
    fn malformed_or_missing_heading_level_falls_back_safely() {
        assert_eq!(heading_level(Some("level=7;slug=bad")), 1);
        assert_eq!(heading_level(Some("slug=no-level")), 1);
        assert_eq!(heading_level(Some("level=6;slug=valid")), 6);
    }
}
