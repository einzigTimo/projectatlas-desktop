//! Purpose: Replace the heuristic token estimate with a real local tokenizer count.
//!
//! Without calibration the dashboard divides byte counts by four — cheap, but only an
//! estimate, and a tool whose whole point is to *prove* savings should not guess when it
//! can count. This module runs a real tokenizer over the indexed file texts and reports
//! both numbers, so the ratio between them is visible.
//!
//! Deliberately NOT wired into the polling loop: it tokenizes every indexed UTF-8 file,
//! which on a large project means tens of megabytes of text. It runs once when the user
//! asks for it, and the result is then kept in the app state and attached to later
//! overviews.
//!
//! Honest limitation, stated in the UI as well: `o200k_base` and `cl100k_base` are
//! `OpenAI` encodings. Claude tokenizes differently, so a calibrated count is a far
//! better figure than the byte heuristic, but still not exact for a Claude workload.

use crate::app::error::{AppError, AppResult};
use projectatlas_core::telemetry::TokenCalibrationOverview;
use projectatlas_db::AtlasStore;

/// Tokenizers this build can calibrate against, in the order shown to the user.
pub(crate) const SUPPORTED_TOKENIZERS: [&str; 2] = ["o200k_base", "cl100k_base"];

/// Bytes the heuristic assumes per token, mirroring the CLI's `byte_count_to_tokens`.
const HEURISTIC_BYTES_PER_TOKEN: usize = 4;

/// Estimate source tokens from a byte count, exactly as the uncalibrated report does.
///
/// Kept identical to `projectatlas-cli`'s helper on purpose: the calibration is only
/// meaningful if the heuristic it is compared against is the same one the headline
/// numbers were built from.
const fn byte_count_to_tokens(bytes: usize) -> usize {
    if bytes == 0 {
        0
    } else {
        bytes.div_ceil(HEURISTIC_BYTES_PER_TOKEN)
    }
}

/// Count tokens across one project's indexed file texts with a real tokenizer.
///
/// # Errors
///
/// Returns an error when the tokenizer name is unknown or the index cannot be read.
pub(crate) fn build(store: &AtlasStore, tokenizer: &str) -> AppResult<TokenCalibrationOverview> {
    let encoding = tiktoken::get_encoding(tokenizer).ok_or_else(|| {
        AppError::Registry(format!(
            "Unbekannter Tokenizer {tokenizer:?}. Möglich sind: {}.",
            SUPPORTED_TOKENIZERS.join(", ")
        ))
    })?;

    let mut files = 0usize;
    let mut bytes = 0usize;
    let mut heuristic_tokens = 0usize;
    let mut calibrated_tokens = 0usize;

    store.visit_file_texts_for_search(None, false, |text| {
        files = files.saturating_add(1);
        bytes = bytes.saturating_add(text.byte_count);
        heuristic_tokens = heuristic_tokens.saturating_add(byte_count_to_tokens(text.byte_count));
        calibrated_tokens = calibrated_tokens.saturating_add(encoding.count(&text.content));
        Ok(true)
    })?;

    Ok(TokenCalibrationOverview {
        tokenizer: tokenizer.to_string(),
        provider: "local_tiktoken".to_string(),
        model: "tokenizer_calibration".to_string(),
        tokenizer_backend: tokenizer.to_string(),
        accuracy: "calibrated_local_tokenizer".to_string(),
        files,
        bytes,
        heuristic_tokens,
        calibrated_tokens,
        heuristic_to_calibrated_ratio: if calibrated_tokens == 0 {
            None
        } else {
            #[expect(
                clippy::cast_precision_loss,
                reason = "a ratio of two token counts does not need more precision than f64 gives"
            )]
            Some(heuristic_tokens as f64 / calibrated_tokens as f64)
        },
    })
}
