# Token Impact Estimate Reporting Specification

## Purpose

Define how ProjectAtlas records, reports, and presents token telemetry using measured values only. The capability name is historical; reports contain no estimates, modeled baselines, or policy shares.

## Requirements

### Requirement: Reports contain only measured sizes
ProjectAtlas SHALL report every size as an exact UTF-8 byte length labeled `unit: utf8_bytes`, SHALL NOT apply a heuristic or model tokenizer to reported telemetry, and SHALL NOT report counterfactual baselines such as directory walks, candidate sets, or fixed policy shares.

#### Scenario: Structured overview
- **WHEN** a CLI JSON/TOON consumer or `atlas_token_report` reads the token overview
- **THEN** the report exposes `unit`, `measurement`, `savings_basis`, `calls`, `measured_calls`, `excluded_unmeasured_calls`, `output_bytes`, `compared_calls`, `compared_source_bytes`, `compared_output_bytes`, `saved_bytes`, `savings_rate`, and measured buckets, and exposes no `tokens_avoided`, `average_policy`, or modeled read-avoidance field

#### Scenario: Trend report
- **WHEN** a trend report groups telemetry by period
- **THEN** each period reports the same measured byte totals and only measured buckets

### Requirement: Savings require a measured counterpart in the same call
ProjectAtlas SHALL report a saving only for calls that loaded one complete file and emitted a response in the same call, computed as the exact file bytes minus the exact emitted bytes, and SHALL name that basis in the report.

#### Scenario: Summary, outline, or slice
- **WHEN** a summary, outline, or slice call loads a 10-byte file and emits 3 bytes
- **THEN** the call is a compared call with `source_bytes` 10, `output_bytes` 3, and `saved_bytes` 7

#### Scenario: Output exceeds the loaded file
- **WHEN** the emitted response is larger than the loaded file
- **THEN** the saving remains a negative signed value and is not clamped

#### Scenario: Navigation, search, or health call
- **WHEN** a call has no complete file loaded in the same call
- **THEN** only its emitted bytes are recorded in the `atlas_output` bucket, the event carries no saving value, and the call contributes no saving

### Requirement: No new modeled telemetry is recorded
ProjectAtlas SHALL NOT compute or persist modeled navigation baselines for CLI or MCP calls.

#### Scenario: Navigation call
- **WHEN** an agent calls overview, folders, files, next, symbols, symbol relations, search, health, or purpose-queue tools
- **THEN** the persisted event carries `estimate_method: utf8_bytes_exact`, `accounting_layer: observed_output`, and a zero counterpart

### Requirement: Legacy rows stay stored but are excluded from sizes
ProjectAtlas SHALL keep telemetry rows written by earlier releases without schema migration or mutation, SHALL count them in `calls` and `excluded_unmeasured_calls`, and SHALL exclude every heuristic or modeled row from all reported byte totals, buckets, trends, TUI values, and desktop projections.

#### Scenario: Database with modeled directory-walk rows
- **WHEN** a database contains legacy `directory_walk`, `selected_candidates`, or heuristic full-file rows
- **THEN** the overview, trends, CLI, MCP, TUI, and desktop views report none of their sizes while still counting their calls as excluded

#### Scenario: Raw and durable aggregate parity
- **WHEN** equivalent telemetry is reported directly from raw events and after a real SQLite write/read round trip
- **THEN** the measured totals are identical across both paths

### Requirement: TUI shows only measured values
The token overview TUI SHALL use the measured saved bytes as its hero with the complete `loaded file bytes - emitted bytes = saved bytes` equation, SHALL show total measured output bytes and a measured-call ledger, and SHALL show legacy rows only as an excluded call count.

#### Scenario: Full dashboard
- **WHEN** the token overview renders at the supported width
- **THEN** no avoided, modeled, policy, or directory-walk value is visible

#### Scenario: Compact dashboards and themes
- **WHEN** the dashboard renders below full size or in dark, light, and terminal themes
- **THEN** measured saving, output bytes, and the excluded call count remain readable and negative savings keep their warning style
