//! Purpose: Shared app state — the project registry, the active selection, and the
//! change fingerprints that keep the background refresh silent.
//!
//! The fingerprints exist so the polling loop can tell "nothing changed" from "new
//! telemetry arrived" without re-rendering anything: only a changed fingerprint
//! emits an event, and only then does the frontend patch the affected text nodes.

use crate::app::error::{AppError, AppResult};
use crate::app::registry::{ProjectStatus, RegisteredProject, RegistryFile, load};
use crate::app::view::{ActivityView, OverviewView, TrendView};
use projectatlas_core::telemetry::TokenCalibrationOverview;
use serde::Serialize;
use std::collections::HashMap;
use tokio::sync::Mutex;

/// Default calendar grouping used until the frontend selects one.
pub(crate) const DEFAULT_TREND_WINDOW: &str = "day";
/// Number of recent calls kept in the activity log.
pub(crate) const ACTIVITY_LIMIT: u32 = 50;

/// Which payload a fingerprint belongs to.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum Payload {
    /// The all-time savings overview.
    Overview,
    /// The retained trend periods.
    Trend,
    /// The recent-activity log.
    Activity,
}

/// Fingerprints of the last payloads delivered for one project.
#[derive(Clone, Debug, Default)]
struct ProjectFingerprints {
    /// Fingerprint per payload kind, absent until the first successful read.
    entries: HashMap<Payload, String>,
}

/// Mutable inner state guarded by one async mutex.
#[derive(Debug)]
struct Inner {
    /// Known projects, mirrored from disk.
    registry: RegistryFile,
    /// The exact error message from [`load()`] when the registry file cannot be
    /// safely overwritten (e.g. incompatible version, unknown migration path).
    /// `None` for recoverable errors such as ordinary parse / IO failures.
    registry_blocked_reason: Option<String>,
    /// Id of the project currently shown in the content area.
    active_project_id: Option<String>,
    /// Calendar grouping the trend panel currently displays.
    trend_window: String,
    /// Change fingerprints keyed by project id.
    fingerprints: HashMap<String, ProjectFingerprints>,
    /// Tokenizer calibration per project, computed on request and reused afterwards
    /// because it walks the whole index and is far too costly for the poll loop.
    calibrations: HashMap<String, TokenCalibrationOverview>,
}

/// Application state managed by Tauri and shared with the polling task.
#[derive(Debug)]
pub(crate) struct AppState {
    /// The guarded inner state.
    inner: Mutex<Inner>,
}

/// One sidebar badge: the headline numbers of a non-active project.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectBadge {
    /// Project id the badge belongs to.
    pub(crate) id: String,
    /// Number of tracked calls.
    pub(crate) calls: usize,
    /// Saved tokens.
    pub(crate) saved: isize,
}

impl AppState {
    /// Build the state from the on-disk registry, starting empty when none exists.
    pub(crate) fn load_or_default() -> Self {
        // Only a version-incompatible registry blocks recovery commands such as
        // rescan or add_project_manual.  Ordinary parse / IO errors leave the
        // in-memory registry as the default so those commands can repair the file.
        let (registry, registry_blocked_reason) = match load() {
            Ok(registry) => (registry, None),
            Err(error @ AppError::Registry(_)) => {
                // Extract the inner message only, not error.to_string(), to avoid the
                // "Projekt-Registrierung fehlgeschlagen:" prefix appearing twice when
                // registry_result() wraps this into another AppError::Registry later.
                let inner_msg = match &error {
                    AppError::Registry(msg) => msg.clone(),
                    _ => error.to_string(),
                };
                (RegistryFile::default(), Some(inner_msg))
            }
            Err(_) => (RegistryFile::default(), None),
        };
        let active_project_id = preferred_project(&registry.projects);
        Self {
            inner: Mutex::new(Inner {
                registry,
                registry_blocked_reason,
                active_project_id,
                trend_window: DEFAULT_TREND_WINDOW.to_string(),
                fingerprints: HashMap::new(),
                calibrations: HashMap::new(),
            }),
        }
    }

    /// Return a copy of the current registry.
    pub(crate) async fn registry(&self) -> RegistryFile {
        self.inner.lock().await.registry.clone()
    }

    /// Return the registry only when it is safe to modify.
    ///
    /// Blocks when the on-disk file has an incompatible or unrecognised schema
    /// version — overwriting it would silently lose unknown fields and corrupt the
    /// user's data.  The concrete error from [`load()`] is returned so the message
    /// accurately describes the actual problem (invalid version, unknown migration
    /// path, etc.) rather than always claiming the file is from a newer app version.
    ///
    /// Ordinary parse or IO errors do NOT block: the in-memory default registry is
    /// returned so commands such as `rescan_projects` and `add_project_manual` can
    /// restore the file.
    pub(crate) async fn registry_result(&self) -> AppResult<RegistryFile> {
        let inner = self.inner.lock().await;
        match &inner.registry_blocked_reason {
            Some(reason) => Err(AppError::Registry(format!(
                "Registrierungsdatei inkompatibel, schreibende Befehle werden blockiert: {reason}"
            ))),
            None => Ok(inner.registry.clone()),
        }
    }

    /// Replace the in-memory registry after a scan or manual change.
    pub(crate) async fn set_registry(&self, registry: RegistryFile) {
        let mut inner = self.inner.lock().await;
        if inner
            .active_project_id
            .as_ref()
            .is_none_or(|active| !registry.projects.iter().any(|p| &p.id == active))
        {
            inner.active_project_id = preferred_project(&registry.projects);
        }
        inner.registry = registry;
        inner.registry_blocked_reason = None;
    }

    /// Return the id of the project currently displayed, if any.
    pub(crate) async fn active_project_id(&self) -> Option<String> {
        self.inner.lock().await.active_project_id.clone()
    }

    /// Select a different project and drop its stale comparison baseline.
    pub(crate) async fn set_active_project_id(&self, project_id: String) {
        let mut inner = self.inner.lock().await;
        inner.fingerprints.remove(&project_id);
        inner.active_project_id = Some(project_id);
    }

    /// Return the calendar grouping the trend panel currently displays.
    pub(crate) async fn trend_window(&self) -> String {
        self.inner.lock().await.trend_window.clone()
    }

    /// Remember the calendar grouping so the polling loop watches the same window.
    pub(crate) async fn set_trend_window(&self, window: String) {
        let mut inner = self.inner.lock().await;
        if inner.trend_window != window {
            for fingerprints in inner.fingerprints.values_mut() {
                fingerprints.entries.remove(&Payload::Trend);
            }
            inner.trend_window = window;
        }
    }

    /// Return the stored tokenizer calibration for one project, if one was computed.
    pub(crate) async fn calibration(&self, project_id: &str) -> Option<TokenCalibrationOverview> {
        self.inner
            .lock()
            .await
            .calibrations
            .get(project_id)
            .cloned()
    }

    /// Store a freshly computed tokenizer calibration for one project.
    pub(crate) async fn set_calibration(
        &self,
        project_id: String,
        calibration: TokenCalibrationOverview,
    ) {
        self.inner
            .lock()
            .await
            .calibrations
            .insert(project_id, calibration);
    }

    /// Forget every comparison baseline recorded for one project.
    pub(crate) async fn forget_fingerprints(&self, project_id: &str) {
        self.inner.lock().await.fingerprints.remove(project_id);
    }

    /// Record a payload fingerprint, returning whether it differs from the last one.
    pub(crate) async fn record_fingerprint(
        &self,
        project_id: &str,
        payload: Payload,
        fingerprint: String,
    ) -> bool {
        let mut inner = self.inner.lock().await;
        let entries = &mut inner
            .fingerprints
            .entry(project_id.to_string())
            .or_default()
            .entries;
        match entries.get(&payload) {
            Some(previous) if previous == &fingerprint => false,
            _ => {
                entries.insert(payload, fingerprint);
                true
            }
        }
    }
}

/// Pick the project to show first: a readable one, else simply the first entry.
///
/// Without the status check the app opens on whatever happens to be first in the
/// registry — which, on a machine with one stale database, means the window greets
/// the user with an error instead of the numbers.
fn preferred_project(projects: &[RegisteredProject]) -> Option<String> {
    projects
        .iter()
        .find(|project| project.status == ProjectStatus::Ok)
        .or_else(|| projects.first())
        .map(|project| project.id.clone())
}

/// Hash any serializable payload into a compact change fingerprint.
///
/// Falls back to an empty fingerprint when serialization fails, which simply makes
/// the next poll treat the payload as changed instead of failing the refresh.
pub(crate) fn fingerprint<T: Serialize>(payload: &T) -> String {
    serde_json::to_vec(payload).map_or_else(
        |_| String::new(),
        |bytes| blake3::hash(&bytes).to_hex().to_string(),
    )
}

/// Fingerprint one overview payload.
pub(crate) fn overview_fingerprint(overview: &OverviewView) -> String {
    fingerprint(overview)
}

/// Fingerprint one trend payload.
pub(crate) fn trend_fingerprint(trend: &TrendView) -> String {
    fingerprint(trend)
}

/// Fingerprint one activity payload.
pub(crate) fn activity_fingerprint(activity: &[ActivityView]) -> String {
    fingerprint(&activity)
}
