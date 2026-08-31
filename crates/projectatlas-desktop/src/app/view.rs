//! Purpose: Slim, serializable projections of the token telemetry structs for the frontend.
//!
//! The core structs (`TokenOverview`, `TokenTrendReport`, `UsageEvent`) carry many
//! fields the dashboard never renders. Projecting them here keeps the IPC payload
//! small, gives the frontend a stable shape independent of core-crate churn, and
//! yields a cheap change fingerprint for the silent polling loop (see `polling.rs`).

use projectatlas_core::telemetry::{
    TokenBucketOverview, TokenOverview, TokenTrendReport, TokenTrendWindow, UsageEvent,
};
use serde::Serialize;

/// Number of savings buckets forwarded to the attribution table.
const MAX_BUCKETS: usize = 12;
/// Calendar periods forwarded to one trend render, newest periods win.
const MAX_TREND_PERIODS: usize = 120;
/// Total attribution rows forwarded across one trend payload.
const MAX_TREND_BUCKET_ROWS: usize = 240;

/// One savings bucket row: provider, model, and baseline attribution for part of the total.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BucketView {
    /// Savings bucket label separating hard evidence from modeled avoidance.
    pub(crate) bucket: String,
    /// Provider used for token counting.
    pub(crate) provider: String,
    /// Model used for token counting.
    pub(crate) model: String,
    /// Accuracy level of the token count.
    pub(crate) accuracy: String,
    /// Baseline scenario behind the without-`ProjectAtlas` estimate.
    pub(crate) baseline_kind: String,
    /// Confidence level of the baseline scenario.
    pub(crate) confidence: String,
    /// Accounting layer separating measured deltas from modeled avoidance.
    pub(crate) accounting_layer: String,
    /// Number of tracked calls in this bucket.
    pub(crate) calls: usize,
    /// Baseline token estimate without `ProjectAtlas`.
    pub(crate) without: usize,
    /// Token estimate with `ProjectAtlas`.
    pub(crate) with: usize,
    /// Saved tokens in this bucket.
    pub(crate) saved: isize,
    /// Signed savings ratio, or `None` when the baseline estimate is zero.
    pub(crate) savings_rate: Option<f64>,
}

/// Local tokenizer calibration shown as a trust hint below the headline numbers.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CalibrationView {
    /// Tokenizer name.
    pub(crate) tokenizer: String,
    /// Provider label.
    pub(crate) provider: String,
    /// Model label.
    pub(crate) model: String,
}

/// The headline savings equation figures plus their attribution rows.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OverviewView {
    /// Counting mode for the reported numbers.
    pub(crate) estimate_kind: String,
    /// Estimator used to produce the reported numbers.
    pub(crate) estimator: String,
    /// Scope and accuracy boundary for the reported numbers.
    pub(crate) estimate_scope: String,
    /// Number of tracked calls.
    pub(crate) calls: usize,
    /// Baseline token estimate without `ProjectAtlas`.
    pub(crate) without: usize,
    /// Token estimate with `ProjectAtlas`.
    pub(crate) with: usize,
    /// Saved tokens.
    pub(crate) saved: isize,
    /// Signed savings ratio, or `None` when the baseline estimate is zero.
    pub(crate) savings_rate: Option<f64>,
    /// Observed before/after saved tokens, the hard-evidence layer.
    pub(crate) measured_tokens_saved: isize,
    /// Deduped modeled avoided-token estimate.
    pub(crate) deduped_modeled_tokens_avoided: isize,
    /// Average-policy tokens avoided estimate.
    pub(crate) average_tokens_avoided: isize,
    /// All-files maximum tokens avoided estimate.
    pub(crate) maximum_tokens_avoided: isize,
    /// Observed calls that replaced a whole-file read.
    pub(crate) observed_file_read_replacements: usize,
    /// Modeled navigation calls that likely avoided a whole-file read.
    pub(crate) modeled_file_reads_avoided: usize,
    /// Total likely whole-file reads avoided.
    pub(crate) likely_file_reads_avoided: usize,
    /// Scope label for the read-avoidance counters.
    pub(crate) read_avoidance_scope: String,
    /// Confidence label for the read-avoidance counters.
    pub(crate) read_avoidance_confidence: String,
    /// Attribution rows, capped at [`MAX_BUCKETS`].
    pub(crate) buckets: Vec<BucketView>,
    /// Optional local tokenizer calibration.
    pub(crate) calibration: Option<CalibrationView>,
    /// Whether calibration has not yet been run for this project.
    ///
    /// `true` when `calibration` is `None` **and** the project has at least one
    /// recorded call. Surfaced to the frontend so it can show a visible hint and
    /// a "Start calibration" button instead of silent zero-baseline numbers.
    pub(crate) calibration_needed: bool,
    /// Whether `<root>/.mcp.json` registers the `projectatlas` MCP server.
    ///
    /// Claude Code only auto-loads that file, so a project with a map but no
    /// registration records no telemetry; the dashboard uses this to explain
    /// all-zero overviews instead of showing silent nulls. Best-effort: a
    /// user-scoped registration outside the project is not visible here.
    pub(crate) claude_mcp_registered: bool,
}

/// One aggregated calendar period of the trend view.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PeriodView {
    /// Period label such as a day, week, month, or year key.
    pub(crate) period: String,
    /// Number of tracked calls in the period.
    pub(crate) calls: usize,
    /// Baseline token estimate without `ProjectAtlas`.
    pub(crate) without: usize,
    /// Token estimate with `ProjectAtlas`.
    pub(crate) with: usize,
    /// Saved tokens in the period.
    pub(crate) saved: isize,
    /// Signed savings ratio, or `None` when the baseline estimate is zero.
    pub(crate) savings_rate: Option<f64>,
    /// Attribution rows for this period, capped at [`MAX_BUCKETS`].
    pub(crate) buckets: Vec<BucketView>,
}

/// Retained savings grouped by calendar window.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TrendView {
    /// Grouping window label.
    pub(crate) window: String,
    /// Period aggregates ordered oldest to newest.
    pub(crate) periods: Vec<PeriodView>,
    /// Whether older periods or attribution rows were omitted by UI bounds.
    pub(crate) truncated: bool,
}

/// One recent call in the activity log.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ActivityView {
    /// Unix epoch seconds when the call was recorded.
    pub(crate) created_at_epoch: i64,
    /// Command or tool name that produced the saving.
    pub(crate) command: String,
    /// Optional path the command touched.
    pub(crate) path: Option<String>,
    /// Optional query text.
    pub(crate) query: Option<String>,
    /// Baseline token estimate without `ProjectAtlas`.
    pub(crate) without: Option<usize>,
    /// Token estimate with `ProjectAtlas`.
    pub(crate) with: Option<usize>,
    /// Estimated token delta.
    pub(crate) saved: Option<isize>,
    /// Savings bucket label.
    pub(crate) bucket: String,
    /// Provider used for token counting.
    pub(crate) provider: String,
    /// Model used for token counting.
    pub(crate) model: String,
    /// Confidence level of the baseline scenario.
    pub(crate) confidence: String,
}

/// Project one savings bucket onto the dashboard shape.
fn bucket_view(bucket: &TokenBucketOverview) -> BucketView {
    BucketView {
        bucket: bucket.token_savings_bucket.clone(),
        provider: bucket.provider.clone(),
        model: bucket.model.clone(),
        accuracy: bucket.accuracy.clone(),
        baseline_kind: bucket.baseline_kind.clone(),
        confidence: bucket.confidence.clone(),
        accounting_layer: bucket.accounting_layer.clone(),
        calls: bucket.calls,
        without: bucket.estimated_without_projectatlas,
        with: bucket.estimated_with_projectatlas,
        saved: bucket.estimated_saved,
        savings_rate: bucket.savings_rate,
    }
}

/// Project, rank, and bound a list of savings buckets for one dashboard section.
fn bucket_views(buckets: &[TokenBucketOverview]) -> Vec<BucketView> {
    let mut views: Vec<BucketView> = buckets.iter().map(bucket_view).collect();
    views.sort_by(|left, right| right.saved.cmp(&left.saved));
    views.truncate(MAX_BUCKETS);
    views
}

impl OverviewView {
    /// Project a core [`TokenOverview`] onto the dashboard shape.
    pub(crate) fn from_core(overview: &TokenOverview) -> Self {
        Self {
            estimate_kind: overview.estimate_kind.clone(),
            estimator: overview.estimator.clone(),
            estimate_scope: overview.estimate_scope.clone(),
            calls: overview.calls,
            without: overview.estimated_without_projectatlas,
            with: overview.estimated_with_projectatlas,
            saved: overview.estimated_saved,
            savings_rate: overview.savings_rate,
            measured_tokens_saved: overview.measured_tokens_saved,
            deduped_modeled_tokens_avoided: overview.deduped_modeled_tokens_avoided,
            average_tokens_avoided: overview.average_tokens_avoided,
            maximum_tokens_avoided: overview.maximum_tokens_avoided,
            observed_file_read_replacements: overview.observed_file_read_replacements,
            modeled_file_reads_avoided: overview.modeled_file_reads_avoided,
            likely_file_reads_avoided: overview.likely_file_reads_avoided,
            read_avoidance_scope: overview.read_avoidance_scope.clone(),
            read_avoidance_confidence: overview.read_avoidance_confidence.clone(),
            buckets: bucket_views(&overview.buckets),
            calibration: overview
                .calibration
                .as_ref()
                .map(|calibration| CalibrationView {
                    tokenizer: calibration.tokenizer.clone(),
                    provider: calibration.provider.clone(),
                    model: calibration.model.clone(),
                }),
            calibration_needed: overview.calibration.is_none() && overview.calls > 0,
            // Filesystem state, not telemetry: filled in by `query::overview`.
            claude_mcp_registered: false,
        }
    }
}

impl TrendView {
    /// Project a core [`TokenTrendReport`] onto the dashboard shape.
    pub(crate) fn from_core(report: &TokenTrendReport) -> Self {
        let first_period = report.periods.len().saturating_sub(MAX_TREND_PERIODS);
        let per_period_buckets_truncated = report.periods[first_period..]
            .iter()
            .any(|period| period.buckets.len() > MAX_BUCKETS);
        let mut periods = report
            .periods
            .iter()
            .skip(first_period)
            .map(|period| PeriodView {
                period: period.period.clone(),
                calls: period.calls,
                without: period.estimated_without_projectatlas,
                with: period.estimated_with_projectatlas,
                saved: period.estimated_saved,
                savings_rate: period.savings_rate,
                buckets: bucket_views(&period.buckets),
            })
            .collect::<Vec<_>>();
        let mut remaining_bucket_rows = MAX_TREND_BUCKET_ROWS;
        let mut bucket_rows_truncated = false;
        for period in periods.iter_mut().rev() {
            if period.buckets.len() > remaining_bucket_rows {
                period.buckets.truncate(remaining_bucket_rows);
                bucket_rows_truncated = true;
            }
            remaining_bucket_rows = remaining_bucket_rows.saturating_sub(period.buckets.len());
        }
        Self {
            window: report.window.as_str().to_string(),
            periods,
            truncated: first_period > 0 || per_period_buckets_truncated || bucket_rows_truncated,
        }
    }
}

impl ActivityView {
    /// Project one core [`UsageEvent`] onto the activity-log shape.
    pub(crate) fn from_core(event: &UsageEvent) -> Self {
        Self {
            created_at_epoch: event.created_at_epoch,
            command: event.command.clone(),
            path: event.path.clone(),
            query: event.query.clone(),
            without: event.estimated_tokens_without_projectatlas,
            with: event.estimated_tokens_with_projectatlas,
            saved: event.estimated_tokens_saved,
            bucket: event.token_savings_bucket.clone(),
            provider: event.provider.clone(),
            model: event.model.clone(),
            confidence: event.confidence.clone(),
        }
    }
}

/// Parse a frontend window label, falling back to daily grouping on unknown input.
pub(crate) fn parse_window(label: &str) -> TokenTrendWindow {
    TokenTrendWindow::parse(label).unwrap_or(TokenTrendWindow::Day)
}

#[cfg(test)]
mod tests {
    use super::*;
    use projectatlas_core::telemetry::TokenTrendPeriod;

    #[test]
    fn trend_view_reports_per_period_bucket_truncation() {
        let mut seed = TokenTrendPeriod::from_totals("seed".to_string(), 1, 10, 4);
        let bucket = seed.buckets.remove(0);
        let period =
            TokenTrendPeriod::from_buckets("2026-08-31".to_string(), vec![bucket; MAX_BUCKETS + 1]);
        let report = TokenTrendReport::new(None, TokenTrendWindow::Day, vec![period]);

        let view = TrendView::from_core(&report);

        assert!(view.truncated);
        assert_eq!(view.periods[0].buckets.len(), MAX_BUCKETS);
    }
}
