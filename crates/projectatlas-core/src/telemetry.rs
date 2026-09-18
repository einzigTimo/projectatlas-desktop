//! Purpose: Track measured `ProjectAtlas` output and savings telemetry.
//!
//! Reports contain only measured values: exact UTF-8 byte lengths of emitted
//! `ProjectAtlas` output and, where the same call also loaded a complete source
//! file, the exact byte length of that file. No tokenizer is applied and no
//! counterfactual baseline (directory walks, candidate sets, policy shares) is
//! recorded or reported. Rows persisted by older releases with heuristic or
//! modeled values stay in the database for compatibility but are excluded from
//! every reported byte total.

use serde::{Deserialize, Serialize};
use std::{borrow::Cow, collections::BTreeMap};
use thiserror::Error;

/// Unit of every reported size.
pub const TOKEN_REPORT_UNIT: &str = "utf8_bytes";
/// Measurement boundary of every reported size.
pub const TOKEN_REPORT_MEASUREMENT: &str =
    "exact_utf8_byte_lengths_without_tokenizer_or_counterfactual_baselines";
/// Basis of every reported saving.
pub const TOKEN_REPORT_SAVINGS_BASIS: &str =
    "bytes_of_complete_file_loaded_in_the_same_call_minus_bytes_emitted_by_that_call";
/// Estimate method label for exact UTF-8 byte measurement.
pub const TOKEN_ESTIMATE_METHOD_UTF8_BYTES: &str = "utf8_bytes_exact";
/// Provider label for locally measured sizes.
pub const TOKEN_PROVIDER_MEASURED: &str = "measured";
/// Model label when no model tokenizer is involved.
pub const TOKEN_MODEL_NONE: &str = "none";
/// Tokenizer backend label when no tokenizer is involved.
pub const TOKENIZER_BACKEND_NONE: &str = "none";
/// Accuracy label for exact byte lengths.
pub const TOKEN_ACCURACY_EXACT: &str = "exact";
/// Trace label for exact byte measurement.
pub const TOKEN_TRACE_UTF8_BYTES: &str = "bytes=utf8_len(text)";
/// Bucket for calls that loaded a complete file and emitted a smaller view of it.
pub const TOKEN_BUCKET_FULL_FILE_COMPRESSION: &str = "full_file_compression";
/// Bucket for calls whose emitted output is measured without any counterpart.
pub const TOKEN_BUCKET_OUTPUT_ONLY: &str = "atlas_output";
/// Baseline kind for a concrete full-file comparison.
pub const TOKEN_BASELINE_FULL_FILE: &str = "full_file";
/// Baseline kind for output-only measurements.
pub const TOKEN_BASELINE_NONE: &str = "none";
/// Confidence label for measured values.
pub const TOKEN_CONFIDENCE_OBSERVED: &str = "observed";
/// Accounting layer for a measured before/after comparison.
pub const TOKEN_ACCOUNTING_OBSERVED_DELTA: &str = "observed_delta";
/// Accounting layer for a measured output size without comparison.
pub const TOKEN_ACCOUNTING_OBSERVED_OUTPUT: &str = "observed_output";
/// Dedupe scope for measured one-off events.
pub const TOKEN_DEDUPE_SCOPE_EVENT: &str = "event";

/// Legacy label: heuristic `ceil(chars/4)` estimates written by older releases.
pub const TOKEN_ESTIMATE_METHOD_HEURISTIC: &str = "heuristic_chars_or_bytes_div_ceil_4";
/// Legacy label: heuristic provider written by older releases.
pub const TOKEN_PROVIDER_HEURISTIC: &str = "heuristic";
/// Legacy label: unknown model written by older releases.
pub const TOKEN_MODEL_UNKNOWN: &str = "unknown";
/// Legacy label: heuristic tokenizer backend written by older releases.
pub const TOKENIZER_BACKEND_HEURISTIC: &str = "chars_div_4";
/// Legacy label: heuristic accuracy written by older releases.
pub const TOKEN_ACCURACY_HEURISTIC: &str = "heuristic_estimate";
/// Legacy label: heuristic calculation trace written by older releases.
pub const TOKEN_TRACE_HEURISTIC: &str = "heuristic=ceil(chars_or_bytes/4)";
/// Legacy label: modeled navigation-avoidance bucket. Never reported.
pub const TOKEN_BUCKET_NAVIGATION_AVOIDANCE: &str = "navigation_avoidance";
/// Legacy label: modeled candidate-set baseline. Never reported.
pub const TOKEN_BASELINE_SELECTED_CANDIDATES: &str = "selected_candidates";
/// Legacy label: modeled directory-walk baseline. Never reported.
pub const TOKEN_BASELINE_DIRECTORY_WALK: &str = "directory_walk";
/// Legacy label: inferred confidence. Never reported.
pub const TOKEN_CONFIDENCE_INFERRED: &str = "inferred";
/// Legacy label: policy-estimate confidence. Never reported.
pub const TOKEN_CONFIDENCE_POLICY_ESTIMATE: &str = "policy_estimate";
/// Legacy label: modeled counterfactual accounting layer. Never reported.
pub const TOKEN_ACCOUNTING_MODELED_AVOIDANCE: &str = "modeled_avoidance";
/// Legacy label: session dedupe scope for modeled baselines.
pub const TOKEN_DEDUPE_SCOPE_SESSION: &str = "session";

/// CLI command label for file summaries.
pub const TOKEN_COMMAND_SUMMARY: &str = "summary";
/// CLI command label for file outlines.
pub const TOKEN_COMMAND_OUTLINE: &str = "outline";
/// CLI command label for source slices.
pub const TOKEN_COMMAND_SLICE: &str = "slice";
/// CLI command label for symbol slices.
pub const TOKEN_COMMAND_SYMBOL_SLICE: &str = "symbol-slice";
/// CLI command label for indexed search.
pub const TOKEN_COMMAND_SEARCH: &str = "search";
/// MCP event label for file summaries.
pub const TOKEN_COMMAND_MCP_FILE_SUMMARY: &str = "mcp.atlas_file_summary";
/// MCP event label for file outlines.
pub const TOKEN_COMMAND_MCP_OUTLINE: &str = "mcp.atlas_outline";
/// MCP event label for source slices.
pub const TOKEN_COMMAND_MCP_SLICE: &str = "mcp.atlas_slice";
/// MCP event label for indexed search.
pub const TOKEN_COMMAND_MCP_SEARCH: &str = "mcp.atlas_search";

/// Typed telemetry-domain validation failure.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum TelemetryContractError {
    /// The all-zero durable runtime identifier is reserved.
    #[error("the zero usage instance identifier is reserved")]
    ZeroUsageInstanceId,
}

/// One bounded CLI invocation or MCP process inside an authoritative project database.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct UsageInstanceId([u8; 16]);

impl UsageInstanceId {
    /// Construct an identity from its durable 16-byte representation.
    ///
    /// # Errors
    ///
    /// Returns an error for the reserved all-zero value.
    pub fn from_bytes(bytes: [u8; 16]) -> Result<Self, TelemetryContractError> {
        if bytes == [0; 16] {
            return Err(TelemetryContractError::ZeroUsageInstanceId);
        }
        Ok(Self(bytes))
    }

    /// Return the durable 16-byte representation.
    #[must_use]
    pub const fn as_bytes(self) -> [u8; 16] {
        self.0
    }
}

/// Runtime owner of one internal telemetry instance.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageInstanceOwner {
    /// One short-lived command-line invocation.
    CliInvocation,
    /// One long-lived MCP server process.
    McpProcess,
    /// One direct database-library handle retained for API compatibility.
    LibraryHandle,
    /// Historical rows compacted during a supported migration.
    MigratedLegacy,
}

impl UsageInstanceOwner {
    /// Return the stable `SQLite` representation.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CliInvocation => "cli_invocation",
            Self::McpProcess => "mcp_process",
            Self::LibraryHandle => "library_handle",
            Self::MigratedLegacy => "migrated_legacy",
        }
    }

    /// Parse the stable `SQLite` representation.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "cli_invocation" => Some(Self::CliInvocation),
            "mcp_process" => Some(Self::McpProcess),
            "library_handle" => Some(Self::LibraryHandle),
            "migrated_legacy" => Some(Self::MigratedLegacy),
            _ => None,
        }
    }
}

/// Truth state for caller-label and raw telemetry detail.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageDetailAvailability {
    /// Aggregate and retained recent detail are complete for the requested scope.
    Retained,
    /// Numeric aggregates remain available but some detail or dimensions were compacted.
    Partial,
    /// A bounded tombstone proves the requested label existed but its report expired.
    Expired,
    /// No retained aggregate or tombstone can establish the requested scope.
    #[default]
    Unavailable,
}

impl UsageDetailAvailability {
    /// Return the stable serialized label.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Retained => "retained",
            Self::Partial => "partial",
            Self::Expired => "expired",
            Self::Unavailable => "unavailable",
        }
    }

    /// Parse the stable `SQLite` representation.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "retained" => Some(Self::Retained),
            "partial" => Some(Self::Partial),
            "expired" => Some(Self::Expired),
            "unavailable" => Some(Self::Unavailable),
            _ => None,
        }
    }
}

/// One persisted telemetry event for a funnel command.
///
/// The numeric fields keep their historical names because they map to durable
/// `SQLite` columns. Events written by this release store exact UTF-8 byte
/// lengths there and label them with [`TOKEN_ESTIMATE_METHOD_UTF8_BYTES`].
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct UsageEvent {
    /// Optional caller-visible compatibility label, distinct from runtime identity.
    pub session_id: String,
    /// Command or tool name.
    pub command: String,
    /// Optional path affected by the command.
    pub path: Option<String>,
    /// Optional query text.
    pub query: Option<String>,
    /// Measured counterpart size (bytes of the loaded full file), or legacy baseline.
    pub estimated_tokens_without_projectatlas: Option<usize>,
    /// Measured emitted size in bytes, or legacy heuristic estimate.
    pub estimated_tokens_with_projectatlas: Option<usize>,
    /// Signed difference between both stored sizes.
    pub estimated_tokens_saved: Option<isize>,
    /// Bucket separating comparisons from output-only measurements.
    #[serde(default = "default_token_savings_bucket")]
    pub token_savings_bucket: String,
    /// Provider label.
    #[serde(default = "default_token_provider")]
    pub provider: String,
    /// Model label.
    #[serde(default = "default_token_model")]
    pub model: String,
    /// Tokenizer or measurement backend label.
    #[serde(default = "default_tokenizer_backend")]
    pub tokenizer_backend: String,
    /// Accuracy label.
    #[serde(default = "default_token_accuracy")]
    pub accuracy: String,
    /// Counterpart kind.
    #[serde(default = "default_token_baseline_kind")]
    pub baseline_kind: String,
    /// Confidence label.
    #[serde(default = "default_token_confidence")]
    pub confidence: String,
    /// Compact calculation trace.
    #[serde(default = "default_token_trace")]
    pub calculation_trace: String,
    /// Accounting layer.
    #[serde(default = "default_accounting_layer")]
    pub accounting_layer: String,
    /// Measurement or legacy estimate method.
    #[serde(default = "default_estimate_method")]
    pub estimate_method: String,
    /// Denominator represented by the counterpart.
    #[serde(default = "default_denominator_kind")]
    pub denominator_kind: String,
    /// Stable legacy baseline identity for storage deduplication.
    #[serde(default)]
    pub baseline_identity: String,
    /// Stable legacy baseline fingerprint for storage deduplication.
    #[serde(default)]
    pub baseline_fingerprint: String,
    /// Scope used by legacy modeled-baseline storage deduplication.
    #[serde(default = "default_dedupe_scope")]
    pub dedupe_scope: String,
    /// Unix epoch seconds when the event was recorded.
    #[serde(default)]
    pub created_at_epoch: i64,
}

/// Aggregated sizes for one bucket dimension.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TokenBucketOverview {
    /// Bucket label.
    pub token_savings_bucket: String,
    /// Provider label.
    pub provider: String,
    /// Model label.
    pub model: String,
    /// Tokenizer or measurement backend label.
    pub tokenizer_backend: String,
    /// Accuracy label.
    pub accuracy: String,
    /// Counterpart kind.
    pub baseline_kind: String,
    /// Confidence label.
    pub confidence: String,
    /// Number of calls in this bucket.
    pub calls: usize,
    /// Bytes of complete files loaded by these calls; zero for output-only buckets.
    pub source_bytes: usize,
    /// Bytes emitted by these calls.
    pub output_bytes: usize,
    /// Measured saving, present only for full-file comparison buckets.
    pub saved_bytes: Option<isize>,
    /// Signed saving ratio, present only for comparisons with nonzero source bytes.
    pub savings_rate: Option<f64>,
    /// Accounting layer.
    pub accounting_layer: String,
    /// Measurement or legacy estimate method.
    pub estimate_method: String,
    /// Denominator represented by the counterpart.
    pub denominator_kind: String,
    /// Dedupe scope label.
    pub dedupe_scope: String,
}

/// Measured-only token telemetry overview.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TokenOverview {
    /// Unit of every size in this report.
    pub unit: String,
    /// Measurement boundary of every size in this report.
    pub measurement: String,
    /// Basis of `saved_bytes`.
    pub savings_basis: String,
    /// All recorded calls in scope, including legacy rows without measured sizes.
    pub calls: usize,
    /// Calls with exact measured byte sizes.
    pub measured_calls: usize,
    /// Legacy calls whose stored values are heuristic or modeled and therefore excluded.
    pub excluded_unmeasured_calls: usize,
    /// Bytes emitted by all measured calls.
    pub output_bytes: usize,
    /// Measured calls that also loaded one complete file in the same call.
    pub compared_calls: usize,
    /// Bytes of the complete files loaded by compared calls.
    pub compared_source_bytes: usize,
    /// Bytes emitted by compared calls.
    pub compared_output_bytes: usize,
    /// `compared_source_bytes - compared_output_bytes`.
    pub saved_bytes: isize,
    /// Signed saving ratio of compared calls, or `None` without compared source bytes.
    pub savings_rate: Option<f64>,
    /// Measured buckets only.
    pub buckets: Vec<TokenBucketOverview>,
    /// Optional local tokenizer calibration for indexed UTF-8 files.
    pub calibration: Option<TokenCalibrationOverview>,
    /// Availability of caller-label and retained raw detail for this report.
    #[serde(default)]
    pub detail_availability: UsageDetailAvailability,
    /// Optional validated controlled benchmark evidence kept separate from live accounting.
    #[serde(default)]
    pub agent_efficiency: AgentEfficiencyComparison,
}

/// Optional local tokenizer calibration for indexed UTF-8 files.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TokenCalibrationOverview {
    /// Tokenizer name.
    pub tokenizer: String,
    /// Provider label.
    pub provider: String,
    /// Model label.
    pub model: String,
    /// Tokenizer backend label.
    pub tokenizer_backend: String,
    /// Accuracy label.
    pub accuracy: String,
    /// Indexed UTF-8 file count.
    pub files: usize,
    /// Indexed UTF-8 byte count.
    pub bytes: usize,
    /// Existing heuristic estimate over indexed UTF-8 files.
    pub heuristic_tokens: usize,
    /// Local tokenizer count over indexed UTF-8 files.
    pub calibrated_tokens: usize,
    /// Heuristic-to-calibrated ratio, or `None` when calibrated count is zero.
    pub heuristic_to_calibrated_ratio: Option<f64>,
}

/// Validation state for optional agent-efficiency benchmark evidence.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEfficiencyEvidenceState {
    /// No benchmark artifact was requested.
    #[default]
    Unavailable,
    /// The requested artifact could not be read or decoded safely.
    Failed,
    /// The artifact decoded but does not match the supported release contract.
    Incompatible,
    /// Some matched evidence is valid while retained failures remain explicit.
    Partial,
    /// All required candidate and baseline trials matched successfully.
    Compatible,
}

impl AgentEfficiencyEvidenceState {
    /// Return the stable serialized label.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unavailable => "unavailable",
            Self::Failed => "failed",
            Self::Incompatible => "incompatible",
            Self::Partial => "partial",
            Self::Compatible => "compatible",
        }
    }
}

/// Baseline arm compared with the `v0.4` candidate.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEfficiencyBaseline {
    /// Frozen `ProjectAtlas` `v0.3.26` runtime and packaged skill.
    FrozenProjectAtlasV0326,
    /// Codex navigation without `ProjectAtlas`.
    PlainCodex,
}

/// Identity retained from one validated benchmark artifact.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentEfficiencyArtifactIdentity {
    /// Supported benchmark schema version.
    pub schema_version: u32,
    /// Digest algorithm used for `artifact_digest`.
    pub artifact_digest_kind: String,
    /// Digest of the exact validated artifact bytes.
    pub artifact_digest: String,
    /// Candidate runtime semantic version.
    pub candidate_version: String,
    /// Candidate runtime SHA-256 identity.
    pub candidate_runtime_sha256: String,
    /// Descriptive source checkout commit recorded by the benchmark.
    #[serde(default)]
    pub candidate_source_head: String,
    /// Compatibility identity key; descriptive only and mirrors `candidate_source_head`.
    #[serde(default)]
    pub candidate_functional_head: String,
    /// Compatibility identity key; descriptive only and mirrors `candidate_source_head`.
    #[serde(default)]
    pub candidate_checklist_head: String,
    /// Frozen `ProjectAtlas` runtime semantic version.
    pub frozen_version: String,
    /// Frozen `ProjectAtlas` runtime `SHA-256` identity.
    pub frozen_runtime_sha256: String,
}

/// Closed navigation metric projected from matched benchmark trials.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEfficiencyMetricKind {
    /// All tool calls made by the agent.
    TotalToolCalls,
    /// Calls made through the `ProjectAtlas` MCP server.
    ProjectAtlasCalls,
    /// Productive folder selections.
    ProductiveFolders,
    /// Productive file selections.
    ProductiveFiles,
    /// Productive relation selections.
    ProductiveRelations,
    /// Wrong folder selections.
    WrongFolders,
    /// Wrong file selections.
    WrongFiles,
    /// Wrong relation selections.
    WrongRelations,
    /// Broad source reads.
    BroadReads,
    /// Full source-file reads.
    FullReads,
    /// Navigation backtracks.
    Backtracks,
    /// Gross navigation-context bytes.
    GrossNavigationBytes,
    /// Net navigation-context bytes including setup material.
    NetNavigationBytes,
    /// Gross navigation-context heuristic tokens.
    GrossNavigationTokens,
    /// Net navigation-context heuristic tokens including setup material.
    NetNavigationTokens,
    /// Candidate setup wall time.
    SetupWallSeconds,
    /// Per-task runtime wall time after setup.
    RuntimeWallSeconds,
    /// Persistent bytes retained after the trial.
    PersistentBytes,
}

/// Candidate and baseline distribution summary for one navigation metric.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AgentEfficiencyMetricComparison {
    /// Metric represented by this row.
    pub metric: AgentEfficiencyMetricKind,
    /// Median across matched candidate trials.
    pub candidate_median: f64,
    /// Median across matched baseline trials.
    pub baseline_median: f64,
    /// Observed maximum across matched candidate trials.
    pub candidate_maximum: f64,
    /// Observed maximum across matched baseline trials.
    pub baseline_maximum: f64,
    /// Lower-is-better median percentage saving, absent for a zero denominator.
    pub median_percent_saving: Option<f64>,
}

/// Workload-specific setup/runtime break-even truth.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentEfficiencyBreakEven {
    /// Validated benchmark workload name.
    pub workload: String,
    /// Tasks required to repay setup wall time, or `None` when no positive saving exists.
    pub wall_time_tasks: Option<u64>,
}

/// Provider counter represented only as descriptive benchmark context.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEfficiencyProviderMetricKind {
    /// Provider input-token counter.
    InputTokens,
    /// Provider cached-input-token counter.
    CachedInputTokens,
    /// Provider cache-write input-token counter.
    CacheWriteInputTokens,
    /// Provider output-token counter.
    OutputTokens,
    /// Provider reasoning-output-token counter.
    ReasoningOutputTokens,
}

/// Descriptive-only candidate and baseline provider counter.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AgentEfficiencyProviderMetric {
    /// Provider counter represented by this row.
    pub metric: AgentEfficiencyProviderMetricKind,
    /// Candidate median reported by the provider.
    pub candidate_median: f64,
    /// Baseline median reported by the provider.
    pub baseline_median: f64,
    /// Candidate observed maximum reported by the provider.
    pub candidate_maximum: f64,
    /// Baseline observed maximum reported by the provider.
    pub baseline_maximum: f64,
    /// Always false because provider counters do not prove navigation causality.
    pub causal_attribution: bool,
}

/// One matched baseline comparison projected from the benchmark artifact.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AgentEfficiencyBaselineRow {
    /// Compared baseline arm.
    pub baseline: AgentEfficiencyBaseline,
    /// Evidence state for this baseline.
    pub state: AgentEfficiencyEvidenceState,
    /// Candidate and baseline trials that completed the same workload and repeat.
    pub matched_trials: usize,
    /// Failed candidate trials retained outside matched denominators.
    pub candidate_failed_trials: usize,
    /// Failed baseline trials retained outside matched denominators.
    pub baseline_failed_trials: usize,
    /// Completed trials without a completed counterpart.
    pub unmatched_trials: usize,
    /// Bounded matched navigation distributions.
    pub metrics: Vec<AgentEfficiencyMetricComparison>,
    /// Workload-specific setup/runtime break-even truth.
    pub break_even: Vec<AgentEfficiencyBreakEven>,
    /// Provider counters retained as descriptive-only context.
    pub provider_usage_descriptive_only: Vec<AgentEfficiencyProviderMetric>,
}

/// Durable `ProjectAtlas` navigation capability represented in the benchmark.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentEfficiencyCapability {
    /// Initial project, purpose, and connection discovery.
    Discovery,
    /// Summary, outline, and exact-slice compression.
    SummaryAndSlice,
    /// Lexical search narrowing.
    Search,
    /// Symbol and relation navigation.
    SymbolsAndRelations,
    /// Trace-completed `ProjectAtlas` calls outside the supported named groups.
    Other,
}

/// Trace-completed `v0.4` MCP calls grouped by navigation responsibility.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentEfficiencyCapabilityContribution {
    /// Capability responsibility represented by this row.
    pub capability: AgentEfficiencyCapability,
    /// Trace-completed `ProjectAtlas` MCP calls.
    pub calls: usize,
    /// Bytes emitted by those MCP calls.
    pub emitted_bytes: u64,
}

/// Optional controlled benchmark comparison attached to live token telemetry.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct AgentEfficiencyComparison {
    /// Overall evidence state.
    pub state: AgentEfficiencyEvidenceState,
    /// Bounded explanation for unavailable, failed, incompatible, or partial evidence.
    pub reason: Option<String>,
    /// Validated artifact and runtime identity.
    pub artifact: Option<AgentEfficiencyArtifactIdentity>,
    /// Frozen-v0.3.26 and plain-control rows.
    pub baselines: Vec<AgentEfficiencyBaselineRow>,
    /// Trace-completed candidate MCP calls grouped without causal token attribution.
    pub capabilities: Vec<AgentEfficiencyCapabilityContribution>,
    /// Whether provider counters are explicitly non-causal.
    pub provider_counters_descriptive_only: bool,
}

impl Default for AgentEfficiencyComparison {
    fn default() -> Self {
        Self {
            state: AgentEfficiencyEvidenceState::Unavailable,
            reason: Some("benchmark artifact not supplied".to_string()),
            artifact: None,
            baselines: Vec::new(),
            capabilities: Vec::new(),
            provider_counters_descriptive_only: true,
        }
    }
}

/// Token trend grouping window.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenTrendWindow {
    /// Group token telemetry by day.
    Day,
    /// Group token telemetry by week.
    Week,
    /// Group token telemetry by month.
    Month,
    /// Group token telemetry by year.
    Year,
}

impl TokenTrendWindow {
    /// Parse a stable window label.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "day" => Some(Self::Day),
            "week" => Some(Self::Week),
            "month" => Some(Self::Month),
            "year" => Some(Self::Year),
            _ => None,
        }
    }

    /// Return the stable CLI/MCP label.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Day => "day",
            Self::Week => "week",
            Self::Month => "month",
            Self::Year => "year",
        }
    }
}

impl std::fmt::Display for TokenTrendWindow {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Measured aggregate for one trend period.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TokenTrendPeriod {
    /// Period label such as `2026-06-29`, `2026-W26`, `2026-06`, or `2026`.
    pub period: String,
    /// All recorded calls in the period, including excluded legacy rows.
    pub calls: usize,
    /// Calls with exact measured byte sizes.
    pub measured_calls: usize,
    /// Bytes emitted by all measured calls.
    pub output_bytes: usize,
    /// Measured calls that also loaded one complete file in the same call.
    pub compared_calls: usize,
    /// Bytes of the complete files loaded by compared calls.
    pub compared_source_bytes: usize,
    /// Bytes emitted by compared calls.
    pub compared_output_bytes: usize,
    /// `compared_source_bytes - compared_output_bytes`.
    pub saved_bytes: isize,
    /// Signed saving ratio of compared calls, or `None` without compared source bytes.
    pub savings_rate: Option<f64>,
    /// Measured buckets only.
    pub buckets: Vec<TokenBucketOverview>,
}

/// Measured-only token trend report.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TokenTrendReport {
    /// Unit of every size in this report.
    pub unit: String,
    /// Measurement boundary of every size in this report.
    pub measurement: String,
    /// Basis of every `saved_bytes` value.
    pub savings_basis: String,
    /// Optional caller-visible compatibility-label filter.
    pub session: Option<String>,
    /// Grouping window.
    pub window: TokenTrendWindow,
    /// Period aggregates ordered oldest to newest.
    pub periods: Vec<TokenTrendPeriod>,
    /// Availability of the requested retained trend scope.
    #[serde(default)]
    pub detail_availability: UsageDetailAvailability,
}

impl UsageEvent {
    /// Return whether this event is a measured output size without any counterpart.
    #[must_use]
    pub fn is_output_only(&self) -> bool {
        is_output_only_event(self)
    }

    /// Return whether this event represents a before/after source comparison.
    #[must_use]
    pub fn is_observed(&self) -> bool {
        is_observed_event(self)
    }

    /// Return whether this event is a legacy modeled navigation-avoidance row.
    #[must_use]
    pub fn is_modeled(&self) -> bool {
        is_modeled_event(self)
    }

    /// Return whether this observed event replaced a whole-file read.
    #[must_use]
    pub fn is_observed_file_read_replacement(&self, baseline_size: usize) -> bool {
        is_observed_read_replacement_event(self, baseline_size)
    }

    /// Return whether this legacy modeled event claimed whole-file read avoidance.
    #[must_use]
    pub fn is_modeled_file_read_avoidance(&self, baseline_size: usize) -> bool {
        is_modeled_read_avoidance_event(self, baseline_size)
    }

    /// Return the normalized accounting layer used by bucket dimensions.
    #[must_use]
    pub fn report_accounting_layer(&self) -> &str {
        if self.is_observed() {
            TOKEN_ACCOUNTING_OBSERVED_DELTA
        } else {
            &self.accounting_layer
        }
    }

    /// Return the normalized denominator used by bucket dimensions.
    #[must_use]
    pub fn report_denominator_kind(&self) -> &str {
        if self.is_observed() {
            TOKEN_BASELINE_FULL_FILE
        } else {
            &self.denominator_kind
        }
    }

    /// Return the normalized deduplication scope used by bucket dimensions.
    #[must_use]
    pub fn report_dedupe_scope(&self) -> &str {
        if self.is_observed() || self.is_output_only() {
            TOKEN_DEDUPE_SCOPE_EVENT
        } else {
            &self.dedupe_scope
        }
    }

    /// Return the stored baseline identity, including the legacy fallback.
    #[must_use]
    pub fn effective_baseline_identity(&self) -> Cow<'_, str> {
        if self.baseline_identity.is_empty() {
            Cow::Owned(default_baseline_identity(
                &self.command,
                self.path.as_deref(),
                self.query.as_deref(),
                &self.baseline_kind,
            ))
        } else {
            Cow::Borrowed(&self.baseline_identity)
        }
    }

    /// Return the stored baseline fingerprint, including the legacy fallback.
    #[must_use]
    pub fn effective_baseline_fingerprint(&self) -> Cow<'_, str> {
        if self.baseline_fingerprint.is_empty() {
            self.effective_baseline_identity()
        } else {
            Cow::Borrowed(&self.baseline_fingerprint)
        }
    }

    /// Return the fixed collision-resistant storage key for one legacy baseline witness.
    #[must_use]
    pub fn modeled_baseline_key(&self) -> [u8; 32] {
        let identity = self.effective_baseline_identity();
        let fingerprint = if self.baseline_fingerprint.is_empty() {
            identity.as_ref()
        } else {
            self.baseline_fingerprint.as_str()
        };
        let mut hasher = blake3::Hasher::new();
        for value in [
            identity.as_ref(),
            fingerprint,
            self.denominator_kind.as_str(),
        ] {
            let bytes = value.as_bytes();
            hasher.update(&(bytes.len() as u64).to_le_bytes());
            hasher.update(bytes);
        }
        *hasher.finalize().as_bytes()
    }
}

/// Wide measured totals shared by overview and trend periods.
#[derive(Default)]
struct MeasuredTotals {
    /// All calls, including excluded legacy rows.
    calls: u128,
    /// Calls with exact measured sizes.
    measured_calls: u128,
    /// Bytes emitted by measured calls.
    output_bytes: u128,
    /// Measured full-file comparison calls.
    compared_calls: u128,
    /// Loaded full-file bytes of compared calls.
    compared_source_bytes: u128,
    /// Emitted bytes of compared calls.
    compared_output_bytes: u128,
}

impl MeasuredTotals {
    /// Sum measured totals while counting every call.
    fn from_buckets(buckets: &[TokenBucketOverview]) -> Self {
        let mut totals = Self::default();
        for bucket in buckets {
            totals.calls = totals.calls.saturating_add(bucket.calls as u128);
            if !bucket.is_measured() {
                continue;
            }
            totals.measured_calls = totals.measured_calls.saturating_add(bucket.calls as u128);
            totals.output_bytes = totals
                .output_bytes
                .saturating_add(bucket.output_bytes as u128);
            if bucket.is_full_file_comparison() {
                totals.compared_calls = totals.compared_calls.saturating_add(bucket.calls as u128);
                totals.compared_source_bytes = totals
                    .compared_source_bytes
                    .saturating_add(bucket.source_bytes as u128);
                totals.compared_output_bytes = totals
                    .compared_output_bytes
                    .saturating_add(bucket.output_bytes as u128);
            }
        }
        totals
    }

    /// Return the measured signed saving.
    fn saved_bytes(&self) -> isize {
        saturating_i128_to_isize(aggregate_delta_wide(
            self.compared_source_bytes,
            self.compared_output_bytes,
        ))
    }

    /// Return the measured signed saving ratio.
    fn savings_rate(&self) -> Option<f64> {
        signed_rate(self.compared_source_bytes, self.compared_output_bytes)
    }
}

impl TokenOverview {
    /// Build an overview from usage events.
    #[must_use]
    pub fn from_events(events: &[UsageEvent]) -> Self {
        Self::from_buckets(buckets_from_events(events))
    }

    /// Build an overview from bucket rows, excluding every unmeasured bucket from sizes.
    #[must_use]
    pub fn from_buckets(buckets: Vec<TokenBucketOverview>) -> Self {
        let totals = MeasuredTotals::from_buckets(&buckets);
        let measured_calls = saturating_u128_to_usize(totals.measured_calls);
        let calls = saturating_u128_to_usize(totals.calls);
        Self {
            unit: TOKEN_REPORT_UNIT.to_string(),
            measurement: TOKEN_REPORT_MEASUREMENT.to_string(),
            savings_basis: TOKEN_REPORT_SAVINGS_BASIS.to_string(),
            calls,
            measured_calls,
            excluded_unmeasured_calls: calls.saturating_sub(measured_calls),
            output_bytes: saturating_u128_to_usize(totals.output_bytes),
            compared_calls: saturating_u128_to_usize(totals.compared_calls),
            compared_source_bytes: saturating_u128_to_usize(totals.compared_source_bytes),
            compared_output_bytes: saturating_u128_to_usize(totals.compared_output_bytes),
            saved_bytes: totals.saved_bytes(),
            savings_rate: totals.savings_rate(),
            buckets: buckets
                .into_iter()
                .filter(TokenBucketOverview::is_measured)
                .collect(),
            calibration: None,
            detail_availability: UsageDetailAvailability::Retained,
            agent_efficiency: AgentEfficiencyComparison::default(),
        }
    }

    /// Attach a local tokenizer calibration section.
    pub fn set_calibration(&mut self, calibration: TokenCalibrationOverview) {
        self.calibration = Some(calibration);
    }

    /// Attach one validated controlled benchmark comparison.
    pub fn set_agent_efficiency(&mut self, comparison: AgentEfficiencyComparison) {
        self.agent_efficiency = comparison;
    }

    /// Set the truth state for caller-label and retained raw detail.
    pub const fn set_detail_availability(&mut self, availability: UsageDetailAvailability) {
        self.detail_availability = availability;
    }
}

impl TokenBucketOverview {
    /// Build a bucket row from stored aggregate sizes.
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn from_totals(
        token_savings_bucket: String,
        provider: String,
        model: String,
        tokenizer_backend: String,
        accuracy: String,
        baseline_kind: String,
        confidence: String,
        accounting_layer: String,
        estimate_method: String,
        denominator_kind: String,
        dedupe_scope: String,
        calls: u128,
        without: u128,
        with: u128,
    ) -> Self {
        let comparison = estimate_method == TOKEN_ESTIMATE_METHOD_UTF8_BYTES
            && accounting_layer == TOKEN_ACCOUNTING_OBSERVED_DELTA;
        Self {
            token_savings_bucket,
            provider,
            model,
            tokenizer_backend,
            accuracy,
            baseline_kind,
            confidence,
            calls: saturating_u128_to_usize(calls),
            source_bytes: saturating_u128_to_usize(without),
            output_bytes: saturating_u128_to_usize(with),
            saved_bytes: comparison
                .then(|| saturating_i128_to_isize(aggregate_delta_wide(without, with))),
            savings_rate: if comparison {
                signed_rate(without, with)
            } else {
                None
            },
            accounting_layer,
            estimate_method,
            denominator_kind,
            dedupe_scope,
        }
    }

    /// Whether this bucket carries exact measured byte sizes.
    #[must_use]
    pub fn is_measured(&self) -> bool {
        self.estimate_method == TOKEN_ESTIMATE_METHOD_UTF8_BYTES
            && (self.accounting_layer == TOKEN_ACCOUNTING_OBSERVED_DELTA
                || self.accounting_layer == TOKEN_ACCOUNTING_OBSERVED_OUTPUT)
    }

    /// Whether this measured bucket compares a loaded complete file with emitted output.
    #[must_use]
    pub fn is_full_file_comparison(&self) -> bool {
        self.is_measured() && self.accounting_layer == TOKEN_ACCOUNTING_OBSERVED_DELTA
    }
}

impl TokenTrendPeriod {
    /// Build a period aggregate from bucket rows, excluding unmeasured buckets from sizes.
    #[must_use]
    pub fn from_buckets(period: String, buckets: Vec<TokenBucketOverview>) -> Self {
        let totals = MeasuredTotals::from_buckets(&buckets);
        Self {
            period,
            calls: saturating_u128_to_usize(totals.calls),
            measured_calls: saturating_u128_to_usize(totals.measured_calls),
            output_bytes: saturating_u128_to_usize(totals.output_bytes),
            compared_calls: saturating_u128_to_usize(totals.compared_calls),
            compared_source_bytes: saturating_u128_to_usize(totals.compared_source_bytes),
            compared_output_bytes: saturating_u128_to_usize(totals.compared_output_bytes),
            saved_bytes: totals.saved_bytes(),
            savings_rate: totals.savings_rate(),
            buckets: buckets
                .into_iter()
                .filter(TokenBucketOverview::is_measured)
                .collect(),
        }
    }
}

impl TokenTrendReport {
    /// Build a trend report from period aggregates.
    #[must_use]
    pub fn new(
        session: Option<String>,
        window: TokenTrendWindow,
        periods: Vec<TokenTrendPeriod>,
    ) -> Self {
        Self {
            unit: TOKEN_REPORT_UNIT.to_string(),
            measurement: TOKEN_REPORT_MEASUREMENT.to_string(),
            savings_basis: TOKEN_REPORT_SAVINGS_BASIS.to_string(),
            session,
            window,
            periods,
            detail_availability: UsageDetailAvailability::Retained,
        }
    }

    /// Set the truth state for the requested retained trend scope.
    pub const fn set_detail_availability(&mut self, availability: UsageDetailAvailability) {
        self.detail_availability = availability;
    }
}

/// Grouping key for bucket aggregation over raw events.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct TokenBucketKey {
    /// Bucket label.
    token_savings_bucket: String,
    /// Provider label.
    provider: String,
    /// Model label.
    model: String,
    /// Tokenizer or measurement backend label.
    tokenizer_backend: String,
    /// Accuracy label.
    accuracy: String,
    /// Counterpart kind.
    baseline_kind: String,
    /// Confidence label.
    confidence: String,
    /// Normalized accounting layer.
    accounting_layer: String,
    /// Measurement or legacy estimate method.
    estimate_method: String,
    /// Normalized denominator.
    denominator_kind: String,
    /// Normalized dedupe scope.
    dedupe_scope: String,
}

impl TokenBucketKey {
    /// Build a grouping key from one usage event.
    fn from(event: &UsageEvent) -> Self {
        Self {
            token_savings_bucket: event.token_savings_bucket.clone(),
            provider: event.provider.clone(),
            model: event.model.clone(),
            tokenizer_backend: event.tokenizer_backend.clone(),
            accuracy: event.accuracy.clone(),
            baseline_kind: event.baseline_kind.clone(),
            confidence: event.confidence.clone(),
            accounting_layer: event.report_accounting_layer().to_string(),
            estimate_method: event.estimate_method.clone(),
            denominator_kind: event.report_denominator_kind().to_string(),
            dedupe_scope: event.report_dedupe_scope().to_string(),
        }
    }

    /// Convert an aggregate bucket into a report row.
    fn into_overview(self, calls: u128, without: u128, with: u128) -> TokenBucketOverview {
        TokenBucketOverview::from_totals(
            self.token_savings_bucket,
            self.provider,
            self.model,
            self.tokenizer_backend,
            self.accuracy,
            self.baseline_kind,
            self.confidence,
            self.accounting_layer,
            self.estimate_method,
            self.denominator_kind,
            self.dedupe_scope,
            calls,
            without,
            with,
        )
    }
}

/// Group raw events into bucket rows.
fn buckets_from_events(events: &[UsageEvent]) -> Vec<TokenBucketOverview> {
    let mut totals = BTreeMap::<TokenBucketKey, (u128, u128, u128)>::new();
    for event in events {
        let (Some(event_without), Some(event_with)) = (
            event.estimated_tokens_without_projectatlas,
            event.estimated_tokens_with_projectatlas,
        ) else {
            continue;
        };
        let entry = totals.entry(TokenBucketKey::from(event)).or_default();
        entry.0 = entry.0.saturating_add(1);
        entry.1 = entry.1.saturating_add(event_without as u128);
        entry.2 = entry.2.saturating_add(event_with as u128);
    }
    totals
        .into_iter()
        .map(|(key, (calls, without, with))| key.into_overview(calls, without, with))
        .collect()
}

/// Create a measured comparison event for a call that loaded one complete file.
///
/// `source_text` must be the complete file content loaded by the same call and
/// `projectatlas_text` the exact emitted output. Both are measured in UTF-8 bytes.
#[must_use]
pub fn usage_from_text(
    session_id: &str,
    command: &str,
    path: Option<String>,
    query: Option<String>,
    source_text: &str,
    projectatlas_text: &str,
) -> UsageEvent {
    measured_event(
        session_id,
        command,
        path,
        query,
        source_text.len(),
        projectatlas_text.len(),
        TOKEN_BUCKET_FULL_FILE_COMPRESSION,
        TOKEN_BASELINE_FULL_FILE,
        TOKEN_ACCOUNTING_OBSERVED_DELTA,
    )
}

/// Create a measured output-only event without any counterpart or saving.
#[must_use]
pub fn usage_from_output(
    session_id: &str,
    command: &str,
    path: Option<String>,
    query: Option<String>,
    projectatlas_text: &str,
) -> UsageEvent {
    measured_event(
        session_id,
        command,
        path,
        query,
        0,
        projectatlas_text.len(),
        TOKEN_BUCKET_OUTPUT_ONLY,
        TOKEN_BASELINE_NONE,
        TOKEN_ACCOUNTING_OBSERVED_OUTPUT,
    )
}

/// Build one measured event with exact byte labels.
#[allow(clippy::too_many_arguments)]
fn measured_event(
    session_id: &str,
    command: &str,
    path: Option<String>,
    query: Option<String>,
    source_bytes: usize,
    output_bytes: usize,
    token_savings_bucket: &str,
    baseline_kind: &str,
    accounting_layer: &str,
) -> UsageEvent {
    let baseline_identity =
        default_baseline_identity(command, path.as_deref(), query.as_deref(), baseline_kind);
    UsageEvent {
        session_id: session_id.to_string(),
        command: command.to_string(),
        path,
        query,
        estimated_tokens_without_projectatlas: Some(source_bytes),
        estimated_tokens_with_projectatlas: Some(output_bytes),
        estimated_tokens_saved: (accounting_layer == TOKEN_ACCOUNTING_OBSERVED_DELTA)
            .then(|| signed_delta(source_bytes, output_bytes)),
        token_savings_bucket: token_savings_bucket.to_string(),
        provider: TOKEN_PROVIDER_MEASURED.to_string(),
        model: TOKEN_MODEL_NONE.to_string(),
        tokenizer_backend: TOKENIZER_BACKEND_NONE.to_string(),
        accuracy: TOKEN_ACCURACY_EXACT.to_string(),
        baseline_kind: baseline_kind.to_string(),
        confidence: TOKEN_CONFIDENCE_OBSERVED.to_string(),
        calculation_trace: TOKEN_TRACE_UTF8_BYTES.to_string(),
        accounting_layer: accounting_layer.to_string(),
        estimate_method: TOKEN_ESTIMATE_METHOD_UTF8_BYTES.to_string(),
        denominator_kind: baseline_kind.to_string(),
        baseline_fingerprint: baseline_identity.clone(),
        baseline_identity,
        dedupe_scope: TOKEN_DEDUPE_SCOPE_EVENT.to_string(),
        created_at_epoch: 0,
    }
}

/// Reconstruct a legacy modeled row as written by older releases.
///
/// Production code must not record these rows; they exist only to verify
/// storage compatibility and that reports exclude them.
#[doc(hidden)]
#[must_use]
pub fn usage_from_estimates(
    session_id: &str,
    command: &str,
    path: Option<String>,
    query: Option<String>,
    estimated_without_projectatlas: usize,
    estimated_with_projectatlas: usize,
) -> UsageEvent {
    usage_from_estimates_with_accounting(
        session_id,
        command,
        path,
        query,
        estimated_without_projectatlas,
        estimated_with_projectatlas,
        TOKEN_BUCKET_NAVIGATION_AVOIDANCE,
        TOKEN_BASELINE_SELECTED_CANDIDATES,
        TOKEN_CONFIDENCE_INFERRED,
        TOKEN_ACCOUNTING_MODELED_AVOIDANCE,
        TOKEN_BASELINE_SELECTED_CANDIDATES,
        TOKEN_DEDUPE_SCOPE_SESSION,
    )
}

/// Reconstruct a legacy heuristic row with explicit historical labels.
///
/// Production code must not record these rows; they exist only to verify
/// storage compatibility and that reports exclude them.
#[doc(hidden)]
#[must_use]
#[allow(clippy::too_many_arguments)]
pub fn usage_from_estimates_with_accounting(
    session_id: &str,
    command: &str,
    path: Option<String>,
    query: Option<String>,
    estimated_without_projectatlas: usize,
    estimated_with_projectatlas: usize,
    token_savings_bucket: &str,
    baseline_kind: &str,
    confidence: &str,
    accounting_layer: &str,
    denominator_kind: &str,
    dedupe_scope: &str,
) -> UsageEvent {
    let baseline_identity =
        default_baseline_identity(command, path.as_deref(), query.as_deref(), baseline_kind);
    let baseline_fingerprint = baseline_identity.clone();
    UsageEvent {
        session_id: session_id.to_string(),
        command: command.to_string(),
        path,
        query,
        estimated_tokens_without_projectatlas: Some(estimated_without_projectatlas),
        estimated_tokens_with_projectatlas: Some(estimated_with_projectatlas),
        estimated_tokens_saved: Some(signed_delta(
            estimated_without_projectatlas,
            estimated_with_projectatlas,
        )),
        token_savings_bucket: token_savings_bucket.to_string(),
        provider: default_token_provider(),
        model: default_token_model(),
        tokenizer_backend: default_tokenizer_backend(),
        accuracy: default_token_accuracy(),
        baseline_kind: baseline_kind.to_string(),
        confidence: confidence.to_string(),
        calculation_trace: default_token_trace(),
        accounting_layer: accounting_layer.to_string(),
        estimate_method: default_estimate_method(),
        denominator_kind: denominator_kind.to_string(),
        baseline_identity,
        baseline_fingerprint,
        dedupe_scope: dedupe_scope.to_string(),
        created_at_epoch: 0,
    }
}

/// Default bucket for legacy serialized usage events.
#[must_use]
pub fn default_token_savings_bucket() -> String {
    TOKEN_BUCKET_NAVIGATION_AVOIDANCE.to_string()
}

/// Default provider for legacy serialized usage events.
#[must_use]
pub fn default_token_provider() -> String {
    TOKEN_PROVIDER_HEURISTIC.to_string()
}

/// Default model for legacy serialized usage events.
#[must_use]
pub fn default_token_model() -> String {
    TOKEN_MODEL_UNKNOWN.to_string()
}

/// Default tokenizer backend for legacy serialized usage events.
#[must_use]
pub fn default_tokenizer_backend() -> String {
    TOKENIZER_BACKEND_HEURISTIC.to_string()
}

/// Default accuracy label for legacy serialized usage events.
#[must_use]
pub fn default_token_accuracy() -> String {
    TOKEN_ACCURACY_HEURISTIC.to_string()
}

/// Default baseline kind for legacy serialized usage events.
#[must_use]
pub fn default_token_baseline_kind() -> String {
    TOKEN_BASELINE_SELECTED_CANDIDATES.to_string()
}

/// Default confidence label for legacy serialized usage events.
#[must_use]
pub fn default_token_confidence() -> String {
    TOKEN_CONFIDENCE_INFERRED.to_string()
}

/// Default calculation trace for legacy serialized usage events.
#[must_use]
pub fn default_token_trace() -> String {
    TOKEN_TRACE_HEURISTIC.to_string()
}

/// Default accounting layer for legacy serialized usage events.
#[must_use]
pub fn default_accounting_layer() -> String {
    TOKEN_ACCOUNTING_MODELED_AVOIDANCE.to_string()
}

/// Default estimate method for legacy serialized usage events.
#[must_use]
pub fn default_estimate_method() -> String {
    TOKEN_ESTIMATE_METHOD_HEURISTIC.to_string()
}

/// Default denominator kind for legacy serialized usage events.
#[must_use]
pub fn default_denominator_kind() -> String {
    TOKEN_BASELINE_SELECTED_CANDIDATES.to_string()
}

/// Default dedupe scope for legacy serialized usage events.
#[must_use]
pub fn default_dedupe_scope() -> String {
    TOKEN_DEDUPE_SCOPE_SESSION.to_string()
}

/// Build a stable baseline identity from existing event context.
#[must_use]
pub fn default_baseline_identity(
    command: &str,
    path: Option<&str>,
    query: Option<&str>,
    baseline_kind: &str,
) -> String {
    format!(
        "{baseline_kind}:command={command}:path={path}:query={query}",
        path = path.unwrap_or("*"),
        query = query.unwrap_or("*")
    )
}

/// Return a saturating signed delta.
fn signed_delta(without: usize, with: usize) -> isize {
    let without = isize::try_from(without).unwrap_or(isize::MAX);
    let with = isize::try_from(with).unwrap_or(isize::MAX);
    without.saturating_sub(with)
}

/// Return a wide signed aggregate delta and saturate only at the wide boundary.
fn aggregate_delta_wide(without: u128, with: u128) -> i128 {
    if without >= with {
        i128::try_from(without - with).unwrap_or(i128::MAX)
    } else {
        i128::try_from(with - without).map_or(i128::MIN, |delta| -delta)
    }
}

/// Return a signed saving ratio, or `None` for a zero denominator.
#[allow(clippy::cast_precision_loss)]
fn signed_rate(without: u128, with: u128) -> Option<f64> {
    (without != 0).then(|| (without as f64 - with as f64) / without as f64)
}

/// Convert a wide aggregate count to `usize` with saturation.
fn saturating_u128_to_usize(value: u128) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

/// Convert a wide signed aggregate to `isize` with saturation.
fn saturating_i128_to_isize(value: i128) -> isize {
    isize::try_from(value).unwrap_or(if value < 0 { isize::MIN } else { isize::MAX })
}

/// Whether an event is a measured output size without counterpart.
fn is_output_only_event(event: &UsageEvent) -> bool {
    event.accounting_layer == TOKEN_ACCOUNTING_OBSERVED_OUTPUT
        || event.token_savings_bucket == TOKEN_BUCKET_OUTPUT_ONLY
}

/// Whether an event represents a before/after source comparison.
fn is_observed_event(event: &UsageEvent) -> bool {
    !is_output_only_event(event)
        && (event.accounting_layer == TOKEN_ACCOUNTING_OBSERVED_DELTA
            || event.token_savings_bucket == TOKEN_BUCKET_FULL_FILE_COMPRESSION
            || event.confidence == TOKEN_CONFIDENCE_OBSERVED)
}

/// Whether an event is a legacy modeled counterfactual row.
fn is_modeled_event(event: &UsageEvent) -> bool {
    !is_output_only_event(event)
        && (event.accounting_layer == TOKEN_ACCOUNTING_MODELED_AVOIDANCE
            || !is_observed_event(event))
}

/// Whether an observed event replaced a whole-file read.
fn is_observed_read_replacement_event(event: &UsageEvent, baseline_size: usize) -> bool {
    baseline_size > 0
        && matches!(
            event.command.as_str(),
            TOKEN_COMMAND_SUMMARY
                | TOKEN_COMMAND_OUTLINE
                | TOKEN_COMMAND_SLICE
                | TOKEN_COMMAND_SYMBOL_SLICE
                | TOKEN_COMMAND_MCP_FILE_SUMMARY
                | TOKEN_COMMAND_MCP_OUTLINE
                | TOKEN_COMMAND_MCP_SLICE
        )
}

/// Whether a legacy modeled event claimed avoiding a broad file read.
fn is_modeled_read_avoidance_event(event: &UsageEvent, baseline_size: usize) -> bool {
    baseline_size > 0
        && matches!(
            event.command.as_str(),
            TOKEN_COMMAND_SEARCH | TOKEN_COMMAND_MCP_SEARCH
        )
        && event.denominator_kind == TOKEN_BASELINE_SELECTED_CANDIDATES
}

#[cfg(test)]
mod tests {
    use super::{
        AgentEfficiencyEvidenceState, TOKEN_ACCOUNTING_MODELED_AVOIDANCE,
        TOKEN_ACCOUNTING_OBSERVED_DELTA, TOKEN_BASELINE_DIRECTORY_WALK,
        TOKEN_BUCKET_FULL_FILE_COMPRESSION, TOKEN_BUCKET_NAVIGATION_AVOIDANCE,
        TOKEN_BUCKET_OUTPUT_ONLY, TOKEN_CONFIDENCE_OBSERVED, TOKEN_CONFIDENCE_POLICY_ESTIMATE,
        TOKEN_DEDUPE_SCOPE_EVENT, TOKEN_REPORT_MEASUREMENT, TOKEN_REPORT_UNIT,
        TelemetryContractError, TokenOverview, TokenTrendPeriod, TokenTrendReport,
        TokenTrendWindow, UsageDetailAvailability, UsageInstanceId, UsageInstanceOwner,
        usage_from_estimates, usage_from_estimates_with_accounting, usage_from_output,
        usage_from_text,
    };
    use std::io;

    fn require_eq<T: std::fmt::Debug + PartialEq>(
        actual: &T,
        expected: &T,
        label: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if actual == expected {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "{label} mismatch: expected {expected:?}, got {actual:?}"
            ))
            .into())
        }
    }

    /// Legacy rows as older releases wrote them: modeled directory walk, modeled
    /// candidate search, and a heuristic observed full-file comparison.
    fn legacy_rows() -> Vec<super::UsageEvent> {
        let mut heuristic_observed =
            usage_from_estimates("s", "summary", Some("src/lib.rs".to_string()), None, 30, 5);
        heuristic_observed.token_savings_bucket = TOKEN_BUCKET_FULL_FILE_COMPRESSION.to_string();
        heuristic_observed.accounting_layer = TOKEN_ACCOUNTING_OBSERVED_DELTA.to_string();
        heuristic_observed.confidence = TOKEN_CONFIDENCE_OBSERVED.to_string();
        vec![
            usage_from_estimates_with_accounting(
                "s",
                "folders",
                None,
                None,
                1_000_000,
                10,
                TOKEN_BUCKET_NAVIGATION_AVOIDANCE,
                TOKEN_BASELINE_DIRECTORY_WALK,
                TOKEN_CONFIDENCE_POLICY_ESTIMATE,
                TOKEN_ACCOUNTING_MODELED_AVOIDANCE,
                TOKEN_BASELINE_DIRECTORY_WALK,
                TOKEN_DEDUPE_SCOPE_EVENT,
            ),
            usage_from_estimates("s", "search", None, Some("needle".to_string()), 400, 40),
            heuristic_observed,
        ]
    }

    #[test]
    fn usage_instance_ids_validate_and_round_trip() {
        let bytes = [7; 16];
        let identity = UsageInstanceId::from_bytes(bytes);
        assert_eq!(identity.map(UsageInstanceId::as_bytes), Ok(bytes));
        assert_eq!(
            UsageInstanceId::from_bytes([0; 16]),
            Err(TelemetryContractError::ZeroUsageInstanceId)
        );
    }

    #[test]
    fn usage_states_parse_and_missing_report_state_fails_honest()
    -> Result<(), Box<dyn std::error::Error>> {
        for (value, expected) in [
            ("cli_invocation", UsageInstanceOwner::CliInvocation),
            ("mcp_process", UsageInstanceOwner::McpProcess),
            ("library_handle", UsageInstanceOwner::LibraryHandle),
            ("migrated_legacy", UsageInstanceOwner::MigratedLegacy),
        ] {
            require_eq(
                &UsageInstanceOwner::parse(value),
                &Some(expected),
                "usage instance owner parse",
            )?;
            require_eq(&expected.as_str(), &value, "usage instance owner encoding")?;
        }
        for (value, expected) in [
            ("retained", UsageDetailAvailability::Retained),
            ("partial", UsageDetailAvailability::Partial),
            ("expired", UsageDetailAvailability::Expired),
            ("unavailable", UsageDetailAvailability::Unavailable),
        ] {
            require_eq(
                &UsageDetailAvailability::parse(value),
                &Some(expected),
                "detail availability parse",
            )?;
            require_eq(&expected.as_str(), &value, "detail availability encoding")?;
        }

        let overview = TokenOverview::from_events(&[]);
        let mut overview_value = serde_json::to_value(overview)?;
        let overview_object = overview_value
            .as_object_mut()
            .ok_or_else(|| io::Error::other("serialized token overview was not an object"))?;
        overview_object.remove("detail_availability");
        overview_object.remove("agent_efficiency");
        let decoded_overview: TokenOverview = serde_json::from_value(overview_value)?;
        require_eq(
            &decoded_overview.detail_availability,
            &UsageDetailAvailability::Unavailable,
            "missing overview detail availability",
        )?;
        require_eq(
            &decoded_overview.agent_efficiency.state,
            &AgentEfficiencyEvidenceState::Unavailable,
            "missing agent-efficiency evidence state",
        )?;

        let trends = TokenTrendReport::new(None, TokenTrendWindow::Day, Vec::new());
        let mut trends_value = serde_json::to_value(trends)?;
        let trends_object = trends_value
            .as_object_mut()
            .ok_or_else(|| io::Error::other("serialized token trends were not an object"))?;
        trends_object.remove("detail_availability");
        let decoded_trends: TokenTrendReport = serde_json::from_value(trends_value)?;
        require_eq(
            &decoded_trends.detail_availability,
            &UsageDetailAvailability::Unavailable,
            "missing trend detail availability",
        )?;
        Ok(())
    }

    #[test]
    fn modeled_baseline_keys_preserve_legacy_fallback_and_component_boundaries() {
        let event = usage_from_estimates(
            "session",
            "search",
            Some("src/lib.rs".to_string()),
            Some("needle".to_string()),
            100,
            20,
        );
        let expected_key = event.modeled_baseline_key();
        let mut legacy = event.clone();
        legacy.baseline_identity.clear();
        legacy.baseline_fingerprint.clear();
        assert_eq!(legacy.modeled_baseline_key(), expected_key);

        let mut left = event.clone();
        left.baseline_identity = "ab".to_string();
        left.baseline_fingerprint = "c".to_string();
        let mut right = event;
        right.baseline_identity = "a".to_string();
        right.baseline_fingerprint = "bc".to_string();
        assert_ne!(left.modeled_baseline_key(), right.modeled_baseline_key());
    }

    #[test]
    fn text_events_measure_exact_utf8_bytes_not_tokens() {
        let event = usage_from_text("s", "outline", None, None, "äbcdefghijkl", "abcd");
        assert_eq!(event.estimated_tokens_without_projectatlas, Some(13));
        assert_eq!(event.estimated_tokens_with_projectatlas, Some(4));
        assert_eq!(event.estimated_tokens_saved, Some(9));
        assert!(event.is_observed());
        assert!(!event.is_modeled());
        assert!(!event.is_output_only());

        let output = usage_from_output("s", "mcp.atlas_search", None, None, "hits");
        assert_eq!(output.estimated_tokens_without_projectatlas, Some(0));
        assert_eq!(output.estimated_tokens_with_projectatlas, Some(4));
        assert_eq!(output.estimated_tokens_saved, None);
        assert!(output.is_output_only());
        assert!(!output.is_observed());
        assert!(!output.is_modeled());
        assert_eq!(output.report_dedupe_scope(), TOKEN_DEDUPE_SCOPE_EVENT);
    }

    #[test]
    fn overview_reports_output_and_compared_savings_from_measurements_only() {
        let overview = TokenOverview::from_events(&[
            usage_from_text("s", "summary", None, None, "0123456789", "012"),
            usage_from_output("s", "search", None, Some("q".to_string()), "12345"),
        ]);
        assert_eq!(overview.unit, TOKEN_REPORT_UNIT);
        assert_eq!(overview.measurement, TOKEN_REPORT_MEASUREMENT);
        assert_eq!(overview.calls, 2);
        assert_eq!(overview.measured_calls, 2);
        assert_eq!(overview.excluded_unmeasured_calls, 0);
        assert_eq!(overview.output_bytes, 8);
        assert_eq!(overview.compared_calls, 1);
        assert_eq!(overview.compared_source_bytes, 10);
        assert_eq!(overview.compared_output_bytes, 3);
        assert_eq!(overview.saved_bytes, 7);
        assert_eq!(overview.savings_rate, Some(0.7));
        assert_eq!(overview.buckets.len(), 2);
        let output_bucket = overview
            .buckets
            .iter()
            .find(|bucket| bucket.token_savings_bucket == TOKEN_BUCKET_OUTPUT_ONLY);
        assert_eq!(output_bucket.map(|bucket| bucket.saved_bytes), Some(None));
        assert_eq!(output_bucket.map(|bucket| bucket.savings_rate), Some(None));
    }

    #[test]
    fn negative_measured_savings_stay_signed() {
        let overview = TokenOverview::from_events(&[usage_from_text(
            "s", "slice", None, None, "ab", "abcdef",
        )]);
        assert_eq!(overview.saved_bytes, -4);
        assert_eq!(overview.savings_rate, Some(-2.0));
    }

    #[test]
    fn legacy_modeled_and_heuristic_rows_never_reach_reported_sizes() {
        let mut events = legacy_rows();
        let legacy_only = TokenOverview::from_events(&events);
        assert_eq!(legacy_only.calls, 3);
        assert_eq!(legacy_only.measured_calls, 0);
        assert_eq!(legacy_only.excluded_unmeasured_calls, 3);
        assert_eq!(legacy_only.output_bytes, 0);
        assert_eq!(legacy_only.compared_source_bytes, 0);
        assert_eq!(legacy_only.saved_bytes, 0);
        assert_eq!(legacy_only.savings_rate, None);
        assert!(legacy_only.buckets.is_empty());

        events.push(usage_from_text("s", "summary", None, None, "abcd", "a"));
        let mixed = TokenOverview::from_events(&events);
        assert_eq!(mixed.calls, 4);
        assert_eq!(mixed.measured_calls, 1);
        assert_eq!(mixed.excluded_unmeasured_calls, 3);
        assert_eq!(mixed.saved_bytes, 3);
        assert_eq!(mixed.buckets.len(), 1);

        let period = TokenTrendPeriod::from_buckets(
            "2026-09-17".to_string(),
            TokenOverview::from_events(&events).buckets,
        );
        assert_eq!(period.saved_bytes, 3);
    }

    #[test]
    fn serialized_report_contains_no_modeled_vocabulary() -> Result<(), Box<dyn std::error::Error>>
    {
        let mut events = legacy_rows();
        events.push(usage_from_output("s", "overview", None, None, "x"));
        let text = serde_json::to_string(&TokenOverview::from_events(&events))?;
        for forbidden in [
            "directory_walk",
            "policy_estimate",
            "modeled",
            "average_policy",
            "tokens_avoided",
            "heuristic",
        ] {
            if text.contains(forbidden) {
                return Err(
                    io::Error::other(format!("report contains {forbidden}: {text}")).into(),
                );
            }
        }
        Ok(())
    }
}
