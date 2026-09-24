//! Purpose: Render `ProjectAtlas` responses with the TOON standard encoder.

use crate::health::{HealthFinding, Severity};
use crate::outline::FileOutline;
use crate::symbols::{CodeSymbol, SymbolRelation};
use crate::telemetry::{TokenBucketOverview, TokenOverview, TokenTrendReport};
use crate::{IndexedNode, Overview, RankedNode};
use serde::Serialize;
use serde_json::{Value, json};

/// Render a repository overview as standard TOON.
#[must_use]
pub fn render_overview(overview: &Overview) -> String {
    encode_agent_payload(&json!({ "overview": overview }))
}

/// Build the agent-facing folder/file row projection used by TOON and JSON.
#[must_use]
pub fn render_node_rows(label: &str, nodes: &[IndexedNode]) -> Vec<serde_json::Value> {
    nodes
        .iter()
        .map(|node| {
            let purpose = node.purpose.purpose.as_deref().unwrap_or("");
            let content_summary = node.summary.as_deref().unwrap_or("");
            match label {
                "folders" => json!({
                    "path": node.node.path,
                    "kind": node.node.kind.to_string(),
                    "folder_purpose": purpose,
                    "content_summary": content_summary,
                    "status": node.purpose.status.to_string(),
                    "purpose_source": node.purpose.source,
                    "purpose_agent_reviewed": node.purpose.agent_reviewed(),
                }),
                "files" => json!({
                    "path": node.node.path,
                    "kind": node.node.kind.to_string(),
                    "language": node.node.language.as_deref().unwrap_or(""),
                    "file_purpose": purpose,
                    "content_summary": content_summary,
                    "status": node.purpose.status.to_string(),
                    "purpose_source": node.purpose.source,
                    "purpose_agent_reviewed": node.purpose.agent_reviewed(),
                }),
                _ => json!({
                    "path": node.node.path,
                    "kind": node.node.kind.to_string(),
                    "purpose": purpose,
                    "content_summary": content_summary,
                    "status": node.purpose.status.to_string(),
                    "purpose_source": node.purpose.source,
                    "purpose_agent_reviewed": node.purpose.agent_reviewed(),
                }),
            }
        })
        .collect()
}

/// Build the agent-facing ranked row projection with bounded reasons.
#[must_use]
pub fn render_ranked_node_rows(label: &str, nodes: &[RankedNode]) -> Vec<serde_json::Value> {
    nodes
        .iter()
        .map(|ranked| {
            let mut row = render_node_rows(label, std::slice::from_ref(&ranked.node))
                .into_iter()
                .next()
                .unwrap_or_else(|| json!({}));
            if let Some(object) = row.as_object_mut() {
                object.insert("reasons".to_string(), json!(ranked.reasons));
                object.insert("reason_codes".to_string(), json!(ranked.reason_codes));
                object.insert(
                    "connection_counts".to_string(),
                    json!(ranked.connection_counts),
                );
                object.insert("connections".to_string(), json!(ranked.connections));
                object.insert(
                    "connections_truncated".to_string(),
                    json!(ranked.connections_truncated),
                );
                object.insert("next_call".to_string(), json!(ranked.next_call));
            }
            row
        })
        .collect()
}

/// Render indexed nodes as standard TOON.
#[must_use]
pub fn render_nodes(label: &str, nodes: &[IndexedNode]) -> String {
    let rows = render_node_rows(label, nodes);
    encode_agent_payload(&json!({ label: rows }))
}

/// Render ranked indexed nodes as standard TOON.
#[must_use]
pub fn render_ranked_nodes(label: &str, nodes: &[RankedNode]) -> String {
    let rows = render_ranked_node_rows(label, nodes);
    encode_agent_payload(&json!({ label: rows }))
}

/// Render an outline as standard TOON.
#[must_use]
pub fn render_outline(outline: &FileOutline) -> String {
    encode_agent_payload(&json!({ "outline": outline }))
}

/// Render health findings as standard TOON.
#[must_use]
pub fn render_health(findings: &[HealthFinding]) -> String {
    let rows = findings
        .iter()
        .map(|finding| {
            json!({
                "severity": render_severity(finding.severity),
                "id": finding.id,
                "category": finding.category,
                "path": finding.path,
                "related_path": finding.related_path.as_deref().unwrap_or(""),
                "message": finding.message,
                "recommendation": finding.recommendation,
            })
        })
        .collect::<Vec<_>>();
    encode_agent_payload(&json!({ "health_findings": rows }))
}

/// Render measured token telemetry as standard TOON.
///
/// Every size is an exact UTF-8 byte length. Savings appear only for calls that
/// loaded a complete file in the same call; legacy heuristic or modeled rows are
/// counted as excluded calls and never contribute sizes.
#[must_use]
pub fn render_token_overview(overview: &TokenOverview) -> String {
    encode_agent_payload(&json!({
        "token_savings": {
            "unit": overview.unit,
            "measurement": overview.measurement,
            "detail_availability": overview.detail_availability,
            "calls": overview.calls,
            "measured_calls": overview.measured_calls,
            "excluded_unmeasured_calls": overview.excluded_unmeasured_calls,
            "output_bytes": overview.output_bytes,
            "full_file_comparison": {
                "basis": overview.savings_basis,
                "calls": overview.compared_calls,
                "source_bytes": overview.compared_source_bytes,
                "output_bytes": overview.compared_output_bytes,
                "saved_bytes": overview.saved_bytes,
                "savings_rate": percentage_label(overview.savings_rate),
            },
            "agent_efficiency": overview.agent_efficiency,
            "calibration": overview.calibration,
            "buckets": token_bucket_rows(&overview.buckets),
        }
    }))
}

/// Render measured token telemetry trends as standard TOON.
#[must_use]
pub fn render_token_trends(report: &TokenTrendReport) -> String {
    let periods = report
        .periods
        .iter()
        .map(|period| {
            json!({
                "period": period.period,
                "calls": period.calls,
                "measured_calls": period.measured_calls,
                "output_bytes": period.output_bytes,
                "compared_calls": period.compared_calls,
                "compared_source_bytes": period.compared_source_bytes,
                "compared_output_bytes": period.compared_output_bytes,
                "saved_bytes": period.saved_bytes,
                "savings_rate": percentage_label(period.savings_rate),
                "buckets": token_bucket_rows(&period.buckets),
            })
        })
        .collect::<Vec<_>>();
    encode_agent_payload(&json!({
        "token_trends": {
            "unit": report.unit,
            "measurement": report.measurement,
            "savings_basis": report.savings_basis,
            "session": report.session.as_deref().unwrap_or("all sessions"),
            "window": report.window,
            "detail_availability": report.detail_availability,
            "periods": periods,
        }
    }))
}

/// Project measured buckets into stable agent-facing rows.
fn token_bucket_rows(buckets: &[TokenBucketOverview]) -> Vec<Value> {
    buckets
        .iter()
        .map(|bucket| {
            json!({
                "bucket": bucket.token_savings_bucket,
                "baseline_kind": bucket.baseline_kind,
                "calls": bucket.calls,
                "source_bytes": bucket.source_bytes,
                "output_bytes": bucket.output_bytes,
                "saved_bytes": bucket.saved_bytes.map_or_else(|| json!("n/a"), |saved| json!(saved)),
                "savings_rate": percentage_label(bucket.savings_rate),
            })
        })
        .collect()
}

/// Render symbols as standard TOON.
#[must_use]
pub fn render_symbols(symbols: &[CodeSymbol]) -> String {
    encode_agent_payload(&json!({ "symbols": render_symbol_rows(symbols) }))
}

/// Project symbols into the stable agent-facing row shape.
#[must_use]
pub fn render_symbol_rows(symbols: &[CodeSymbol]) -> Vec<Value> {
    symbols
        .iter()
        .map(|symbol| {
            let mut row = json!({
                "path": symbol.path,
                "kind": symbol.kind.to_string(),
                "name": symbol.name,
                "start": symbol.line_start,
                "end": symbol.line_end,
                "parent": symbol.parent.as_deref().unwrap_or(""),
                "parser": symbol.parser.to_string(),
                "signature": symbol.signature,
                "exported": symbol.exported,
                "documentation": symbol.documentation.as_deref().unwrap_or(""),
            });
            if let (Some(object), Some(selector)) = (row.as_object_mut(), symbol.source_selector) {
                object.insert("source_selector".to_string(), json!(selector));
            }
            row
        })
        .collect()
}

/// Render symbol relations as standard TOON.
#[must_use]
pub fn render_symbol_relations(relations: &[SymbolRelation]) -> String {
    let rows = relations
        .iter()
        .map(|relation| {
            json!({
                "path": relation.path,
                "kind": relation.kind.to_string(),
                "source": relation.source_name,
                "target": relation.target_name,
                "line": relation.line,
                "parser": relation.parser.to_string(),
                "context": relation.context,
            })
        })
        .collect::<Vec<_>>();
    encode_agent_payload(&json!({ "symbol_relations": rows }))
}

/// Encode a serializable payload through the standard TOON Rust implementation.
#[must_use]
pub fn encode_agent_payload<T>(payload: &T) -> String
where
    T: Serialize,
{
    match toon_format::encode_default(payload) {
        Ok(mut encoded) => {
            encoded.push('\n');
            encoded
        }
        Err(error) => format!("toon_error: {}\n", encode_error_text(&error.to_string())),
    }
}

/// Encode one string using TOON by wrapping it in an object and extracting text.
#[must_use]
pub fn encode_error_text(value: &str) -> String {
    match toon_format::encode_default(&json!({ "value": value })) {
        Ok(encoded) => encoded
            .strip_prefix("value: ")
            .map_or_else(|| quoted_fallback(value), ToString::to_string),
        Err(_) => quoted_fallback(value),
    }
}

/// Render a severity enum as a stable TOON value.
fn render_severity(severity: Severity) -> &'static str {
    severity.as_str()
}

/// Format an optional savings rate as a stable display label.
fn percentage_label(rate: Option<f64>) -> String {
    rate.map_or_else(
        || "unknown".to_string(),
        |value| format!("{:.1}%", value * 100.0),
    )
}

/// Return a conservative quoted fallback for rare encoder failures.
fn quoted_fallback(value: &str) -> String {
    let escaped = value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::{encode_agent_payload, render_symbols, render_token_overview, render_token_trends};
    use crate::symbols::{CodeSymbol, ParserKind, SymbolKind};
    use crate::telemetry::{
        TOKEN_BASELINE_DIRECTORY_WALK, TOKEN_REPORT_SAVINGS_BASIS, TokenOverview, TokenTrendReport,
        TokenTrendWindow, UsageDetailAvailability, usage_from_estimates, usage_from_output,
        usage_from_text,
    };
    use serde_json::{Value, json};

    #[test]
    fn renders_round_trippable_toon_with_standard_decoder() -> Result<(), Box<dyn std::error::Error>>
    {
        let toon = encode_agent_payload(&serde_json::json!({
            "items": [
                {"path": "src/lib.rs", "text": "alpha,beta"},
                {"path": "src/main.rs", "text": "line\nbreak"}
            ]
        }));
        let decoded: Value = toon_format::decode_default(&toon)?;
        if decoded["items"][0]["text"] != "alpha,beta" {
            return Err("first decoded item did not round-trip".into());
        }
        if decoded["items"][1]["text"] != "line\nbreak" {
            return Err("second decoded item did not round-trip".into());
        }
        Ok(())
    }

    #[test]
    fn renders_symbols_as_tabular_toon() {
        let toon = render_symbols(&[CodeSymbol {
            path: "src/lib.rs".to_string(),
            language: Some("rust".to_string()),
            name: "scan".to_string(),
            kind: SymbolKind::Function,
            signature: "fn scan()".to_string(),
            exported: false,
            documentation: None,
            line_start: 1,
            line_end: 3,
            source_selector: None,
            parent: None,
            parser: ParserKind::TreeSitter,
            detail: Some("function_item".to_string()),
        }]);
        assert!(toon.contains(
            "symbols[1]{path,kind,name,start,end,parent,parser,signature,exported,documentation}:"
        ));
    }

    #[test]
    fn renders_token_overview_with_measured_bytes_only() -> Result<(), Box<dyn std::error::Error>> {
        let mut folder = usage_from_estimates("s", "folders", None, None, 1_000_000, 20);
        folder.denominator_kind = TOKEN_BASELINE_DIRECTORY_WALK.to_string();
        let overview = TokenOverview::from_events(&[
            usage_from_text("s", "summary", None, None, "abcdefghijkl", "abcd"),
            usage_from_output("s", "search", None, Some("q".to_string()), "hit"),
            usage_from_estimates("s", "search", None, None, 100, 20),
            folder,
        ]);
        let toon = render_token_overview(&overview);
        for forbidden in [
            "directory_walk",
            "policy_estimate",
            "modeled",
            "average",
            "maximum",
            "tokens_avoided",
            "likely_file_reads",
        ] {
            if toon.contains(forbidden) {
                return Err(format!("token TOON contains {forbidden}:\n{toon}").into());
            }
        }
        let decoded: Value = toon_format::decode_default(&toon)?;
        let token_savings = &decoded["token_savings"];
        require_json_eq(&token_savings["unit"], &json!("utf8_bytes"), "unit")?;
        require_json_eq(&token_savings["calls"], &json!(4), "all calls")?;
        require_json_eq(
            &token_savings["measured_calls"],
            &json!(2),
            "measured calls",
        )?;
        require_json_eq(
            &token_savings["excluded_unmeasured_calls"],
            &json!(2),
            "excluded legacy calls",
        )?;
        require_json_eq(&token_savings["output_bytes"], &json!(7), "output bytes")?;
        let comparison = &token_savings["full_file_comparison"];
        require_json_eq(&comparison["source_bytes"], &json!(12), "source bytes")?;
        require_json_eq(&comparison["saved_bytes"], &json!(8), "saved bytes")?;
        require_json_eq(
            &comparison["basis"],
            &json!(TOKEN_REPORT_SAVINGS_BASIS),
            "savings basis",
        )?;
        Ok(())
    }

    #[test]
    fn token_toon_reports_retained_detail_truth_for_overview_and_trends()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut overview = TokenOverview::from_events(&[]);
        overview.set_detail_availability(UsageDetailAvailability::Partial);
        let overview_toon = render_token_overview(&overview);
        let decoded_overview: Value = toon_format::decode_default(&overview_toon)?;
        require_json_eq(
            &decoded_overview["token_savings"]["detail_availability"],
            &json!("partial"),
            "overview detail availability",
        )?;

        let mut trends = TokenTrendReport::new(None, TokenTrendWindow::Month, Vec::new());
        trends.set_detail_availability(UsageDetailAvailability::Expired);
        let trends_toon = render_token_trends(&trends);
        let decoded_trends: Value = toon_format::decode_default(&trends_toon)?;
        require_json_eq(
            &decoded_trends["token_trends"]["detail_availability"],
            &json!("expired"),
            "trend detail availability",
        )?;
        Ok(())
    }

    fn require_json_eq(
        actual: &Value,
        expected: &Value,
        label: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        if actual == expected {
            Ok(())
        } else {
            Err(format!("{label}: expected {expected}, got {actual}").into())
        }
    }
}
