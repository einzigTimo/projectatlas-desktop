//! Purpose: Detect installed AI coding tools and connect a registered project to them.
//!
//! The dashboard shows what an already-connected project saved, but says nothing about
//! how a colleague attaches their AI tool in the first place. This module closes that
//! gap: it reports which tools are present on the machine and runs `projectatlas init`
//! in a chosen project through the bundled sidecar, so nobody has to open a terminal.
//!
//! Detection is deliberately shallow — the presence of a tool's configuration folder,
//! nothing more. The app never reads, parses, or edits another tool's configuration.
//!
//! `projectatlas init` already writes the host configurations for every supported
//! harness in one go (`projectatlas.mcp.json`, `projectatlas.claude.mcp.json`,
//! `projectatlas.opencode.json`), and Codex reads the same shape as the standard file.
//! Connecting is therefore one call, not one call per tool.

#![allow(
    clippy::let_underscore_must_use,
    reason = "the tauri::command macro expansion triggers it, not this module's own code"
)]

use crate::app::error::{AppError, AppResult};
use crate::app::registry::{self, RegisteredProject};
use crate::app::state::AppState;
use serde::{Deserialize, Serialize};
use std::env;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::ShellExt;

/// Name of the bundled `ProjectAtlas` command-line binary, as declared in
/// `tauri.conf.json` under `bundle.externalBin`.
const SIDECAR_NAME: &str = "projectatlas-cli";
/// Folder created by `projectatlas init` inside a project root.
const ATLAS_DIR_NAME: &str = ".projectatlas";
/// Durable database created by init inside [`ATLAS_DIR_NAME`].
const ATLAS_DB_FILE_NAME: &str = "projectatlas.db";
/// Project-root MCP configuration loaded automatically by Claude Code.
const PROJECT_MCP_FILE_NAME: &str = ".mcp.json";
/// Maximum number of characters of tool output kept for a failure message.
const OUTPUT_EXCERPT_LIMIT: usize = 600;
/// Event carrying per-project progress while connecting every project at once.
const EVENT_SETUP_PROGRESS: &str = "setup-progress";

/// Configuration files `projectatlas init` writes into the project's `.projectatlas`
/// folder, paired with the tool that consumes each one.
const HOST_CONFIG_FILES: [(&str, &str); 3] = [
    ("projectatlas.mcp.json", "Codex und andere MCP-Hosts"),
    ("projectatlas.claude.mcp.json", "Claude Code"),
    ("projectatlas.opencode.json", "OpenCode"),
];

/// An AI coding tool the desktop app knows how to connect a project to.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ToolKind {
    /// Anthropic's Claude Code.
    ClaudeCode,
    /// `OpenAI`'s Codex CLI.
    Codex,
    /// The `OpenCode` agent.
    OpenCode,
}

impl ToolKind {
    /// Return the name shown in the setup screen.
    const fn display_name(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
            Self::OpenCode => "OpenCode",
        }
    }

    /// Return the configuration folders whose presence indicates the tool is installed.
    ///
    /// Each entry is a list of path segments relative to the user's profile folder,
    /// so the joined result uses native separators.
    ///
    /// `OpenCode` is checked in both of its known locations because it moved between
    /// releases.
    const fn config_dirs(self) -> &'static [&'static [&'static str]] {
        match self {
            Self::ClaudeCode => &[&[".claude"]],
            Self::Codex => &[&[".codex"]],
            Self::OpenCode => &[&[".config", "opencode"], &[".opencode"]],
        }
    }
}

/// One AI coding tool and whether it appears to be installed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DetectedTool {
    /// Which tool this entry describes.
    pub(crate) kind: ToolKind,
    /// Name shown in the setup screen.
    pub(crate) display_name: String,
    /// Whether one of the tool's configuration folders exists.
    pub(crate) installed: bool,
    /// The configuration folder that was found, for the user to recognise.
    pub(crate) config_path: Option<String>,
}

/// One host configuration file produced by connecting a project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HostConfigFile {
    /// File name inside the project's `.projectatlas` folder.
    pub(crate) name: String,
    /// Which tool reads this file.
    pub(crate) used_by: String,
    /// Whether the file exists after the connect attempt.
    pub(crate) present: bool,
}

/// Whether a project already carries a `ProjectAtlas` surface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectConnectionView {
    /// Whether the project's `.projectatlas` folder exists.
    pub(crate) initialized: bool,
    /// Host configuration files and whether each one is present.
    pub(crate) config_files: Vec<HostConfigFile>,
}

/// Progress of a run that connects every registered project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SetupProgressView {
    /// Zero-based position of the project currently being connected.
    pub(crate) index: usize,
    /// How many projects the run covers in total.
    pub(crate) total: usize,
    /// Name of the project this event is about.
    pub(crate) display_name: String,
    /// Whether this project is done, as opposed to just starting.
    pub(crate) finished: bool,
    /// Outcome of the project, set once it finished.
    pub(crate) succeeded: Option<bool>,
}

/// Result of one connect attempt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConnectOutcome {
    /// Whether `projectatlas init` finished successfully.
    pub(crate) succeeded: bool,
    /// Message shown to the user, already in German and free of raw tool jargon.
    pub(crate) message: String,
    /// Host configuration files after the attempt.
    pub(crate) config_files: Vec<HostConfigFile>,
    /// Trimmed tool output, present only when the attempt failed.
    pub(crate) details: Option<String>,
    /// Canonical project root confirmed by the bundled CLI after a successful init.
    pub(crate) root: Option<String>,
}

/// Status values emitted by the structured `projectatlas init` report.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
enum InitPhaseStatus {
    /// Artifact was created by this init run.
    Created,
    /// Artifact already existed and was retained.
    Exists,
    /// Phase completed and was verified.
    Verified,
    /// Phase was deliberately skipped.
    Skipped,
    /// Phase failed.
    Failed,
}

impl InitPhaseStatus {
    /// Whether this status proves that a required persistent artifact is ready.
    const fn artifact_ready(self) -> bool {
        matches!(self, Self::Created | Self::Exists | Self::Verified)
    }
}

/// One path result from the structured CLI init report.
#[derive(Debug, Deserialize)]
struct InitPathReport {
    /// Completion state reported for the path.
    status: InitPhaseStatus,
    /// Absolute or normalized path emitted by the CLI.
    path: String,
}

/// One generated host configuration from the structured CLI init report.
#[derive(Debug, Deserialize)]
struct InitHostConfigReport {
    /// Stable CLI name of the target harness.
    harness: String,
    /// Completion state of the generated configuration.
    status: InitPhaseStatus,
    /// Path where the configuration was written.
    path: String,
    /// Phase-specific error, absent after success.
    error: Option<String>,
}

/// Scan phase from the structured CLI init report.
#[derive(Debug, Deserialize)]
struct InitScanReport {
    /// Completion state of the scan phase.
    status: InitPhaseStatus,
    /// Whether the CLI says a scan was requested.
    requested: bool,
    /// Scan error, absent after success or deliberate skipping.
    error: Option<String>,
}

/// Minimum contract the desktop app requires from `projectatlas --format json init`.
#[derive(Debug, Deserialize)]
struct InitReport {
    /// CLI aggregate success flag.
    ok: bool,
    /// Canonical project root selected by the CLI.
    root: String,
    /// Project-local `.projectatlas` directory result.
    project_dir: InitPathReport,
    /// Project-local config result.
    config: InitPathReport,
    /// Non-source metadata result.
    nonsource_files: InitPathReport,
    /// Durable database result.
    db: InitPathReport,
    /// Generated host integration results.
    host_configs: Vec<InitHostConfigReport>,
    /// Requested index phase result.
    scan: InitScanReport,
}

/// Internal result that retains the CLI-confirmed root until registration is complete.
struct InitAttempt {
    /// User-facing outcome returned through Tauri.
    outcome: ConnectOutcome,
    /// CLI-confirmed root, present only after full success.
    canonical_root: Option<PathBuf>,
}

/// Return the user's profile folder.
fn user_profile() -> AppResult<PathBuf> {
    env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .ok_or(AppError::MissingEnvVar("USERPROFILE"))
}

/// Keep the leading characters of `text`, marking that it was shortened.
///
/// Cuts on a character boundary rather than a byte offset, so tool output containing
/// umlauts or box-drawing characters cannot split mid-character.
fn excerpt(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    let Some((cut, _)) = trimmed.char_indices().nth(OUTPUT_EXCERPT_LIMIT) else {
        return Some(trimmed.to_string());
    };
    let mut shortened = trimmed.get(..cut).unwrap_or(trimmed).trim_end().to_string();
    shortened.push_str(" …");
    Some(shortened)
}

/// Parse and validate the machine-readable init report.
///
/// A zero process exit alone is deliberately insufficient: registration is allowed
/// only after the CLI confirms all durable files, every host configuration, and the
/// requested scan mode in its structured report.
fn parse_init_report(stdout: &[u8], scan_requested: bool) -> Result<InitReport, String> {
    let report: InitReport = serde_json::from_slice(stdout)
        .map_err(|error| format!("Der Init-Bericht ist kein gueltiges JSON: {error}"))?;

    if !report.ok {
        return Err("Der Init-Bericht meldet mindestens eine fehlgeschlagene Phase.".to_string());
    }
    if report.root.trim().is_empty() {
        return Err("Der Init-Bericht enthaelt keinen kanonischen Projekt-Root.".to_string());
    }

    for (label, path) in [
        ("Projektverzeichnis", &report.project_dir),
        ("Konfiguration", &report.config),
        ("Nicht-Quellcode-Liste", &report.nonsource_files),
        ("Datenbank", &report.db),
    ] {
        if !path.status.artifact_ready() || path.path.trim().is_empty() {
            return Err(format!(
                "{label} wurde vom Init-Bericht nicht als bereit bestaetigt."
            ));
        }
    }

    for required in ["mcp_json", "claude_code", "opencode", "claude_code_project"] {
        let host = report
            .host_configs
            .iter()
            .find(|host| host.harness == required)
            .ok_or_else(|| {
                format!("Der Init-Bericht bestaetigt die Host-Konfiguration {required} nicht.")
            })?;
        if !host.status.artifact_ready() || host.path.trim().is_empty() || host.error.is_some() {
            return Err(format!(
                "Die Host-Konfiguration {required} wurde nicht vollstaendig erstellt."
            ));
        }
    }

    let expected_scan_status = if scan_requested {
        InitPhaseStatus::Verified
    } else {
        InitPhaseStatus::Skipped
    };
    if report.scan.requested != scan_requested
        || report.scan.status != expected_scan_status
        || report.scan.error.is_some()
    {
        return Err(if scan_requested {
            "Der angeforderte lokale Index wurde nicht erfolgreich aufgebaut.".to_string()
        } else {
            "Der Init-Bericht bestaetigt den gewaehlten Modus ohne Scan nicht.".to_string()
        });
    }

    Ok(report)
}

/// Verify that the CLI-confirmed root owns the folder the user actually selected.
///
/// Registration keeps the normalized root string returned by the CLI, while the
/// canonicalized containment check permits choosing a Git subfolder (the CLI promotes it
/// to the repository root) while preventing an unexpected sidecar response from silently
/// registering an unrelated or nested foreign folder.
fn confirmed_cli_root(requested_root: &Path, cli_root: &str) -> AppResult<PathBuf> {
    let reported = PathBuf::from(cli_root);
    if !reported.is_absolute() {
        return Err(AppError::Registry(
            "Der Init-Bericht enthaelt keinen absoluten Projekt-Root.".to_string(),
        ));
    }
    let requested = requested_root.canonicalize()?;
    let confirmed = reported.canonicalize()?;
    if requested != confirmed && !requested.starts_with(&confirmed) {
        return Err(AppError::Registry(format!(
            "Der ausgewaehlte Ordner ({}) liegt nicht im vom CLI bestaetigten Root ({}).",
            requested.display(),
            confirmed.display()
        )));
    }
    Ok(confirmed)
}

/// Report which host configuration files exist inside a project root.
fn config_files_for(root: &Path) -> Vec<HostConfigFile> {
    let atlas_dir = root.join(ATLAS_DIR_NAME);
    HOST_CONFIG_FILES
        .iter()
        .map(|&(name, used_by)| HostConfigFile {
            name: name.to_string(),
            used_by: used_by.to_string(),
            present: atlas_dir.join(name).is_file(),
        })
        .collect()
}

/// Report which AI coding tools are present on this machine.
///
/// Presence means only that the tool's configuration folder exists. Nothing inside it
/// is opened, so a tool that is installed but never started may read as missing — that
/// is deliberate, and better than touching another tool's private configuration.
///
/// # Errors
///
/// Returns an error when `%USERPROFILE%` is not set in the environment.
#[tauri::command]
pub(crate) async fn detect_ai_tools() -> AppResult<Vec<DetectedTool>> {
    let profile = user_profile()?;
    let tools = [ToolKind::ClaudeCode, ToolKind::Codex, ToolKind::OpenCode]
        .into_iter()
        .map(|kind| {
            let found = kind
                .config_dirs()
                .iter()
                .map(|segments| {
                    segments
                        .iter()
                        .fold(profile.clone(), |path, segment| path.join(segment))
                })
                .find(|candidate| candidate.is_dir());
            DetectedTool {
                kind,
                display_name: kind.display_name().to_string(),
                installed: found.is_some(),
                config_path: found.map(|path| path.display().to_string()),
            }
        })
        .collect();
    Ok(tools)
}

/// Report whether one registered project already has a `ProjectAtlas` surface.
///
/// # Errors
///
/// Returns an error when the project id is not registered.
#[tauri::command]
pub(crate) async fn get_project_connection(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<ProjectConnectionView> {
    let registry = state.registry_result().await?;
    let project = registry::find(&registry, &project_id)?;
    let root = project.root.clone();
    drop(registry);

    Ok(ProjectConnectionView {
        initialized: root.join(ATLAS_DIR_NAME).is_dir(),
        config_files: config_files_for(&root),
    })
}

/// Run `projectatlas init` in one project folder and describe what came out.
///
/// `scan` decides whether the index is rebuilt. Skipping it returns in a moment but
/// leaves the project without resolved references — the sidebar dot stays amber and the
/// Atlas Map stays empty — so the setup screen offers scanning as the normal path and
/// skipping only as the deliberate shortcut.
async fn run_init(
    app: &AppHandle,
    project: &RegisteredProject,
    scan: bool,
) -> AppResult<InitAttempt> {
    run_init_for_root(app, &project.root, &project.display_name, scan).await
}

/// Run init for a user-selected folder that may not be registered yet.
async fn run_init_for_root(
    app: &AppHandle,
    selected_root: &Path,
    display_name: &str,
    scan: bool,
) -> AppResult<InitAttempt> {
    let root = selected_root.to_path_buf();
    let display_name = display_name.to_string();

    if !root.is_dir() {
        return Ok(InitAttempt {
            outcome: ConnectOutcome {
                succeeded: false,
                message: format!(
                    "Der Ordner von {display_name} ist nicht erreichbar: {}",
                    root.display()
                ),
                config_files: Vec::new(),
                details: None,
                root: None,
            },
            canonical_root: None,
        });
    }

    // Resolve the user choice before starting the sidecar. The CLI resolves the same
    // folder independently and its returned root is compared below.
    let selected_root = root.canonicalize()?;

    let mut args = vec!["--format", "json", "init"];
    if !scan {
        args.push("--no-scan");
    }

    let command = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|source| {
            AppError::Registry(format!(
                "Die mitgelieferte ProjectAtlas-Programmdatei fehlt in dieser Ausgabe \
                 ({source}). Sie wird erst vom Release-Skript in den Installer gepackt — \
                 in einem Entwicklungsstart ist sie nicht vorhanden."
            ))
        })?
        .current_dir(selected_root.clone())
        .args(args);

    let output = command.output().await?;

    if output.status.success() {
        let report = parse_init_report(&output.stdout, scan).map_err(|message| {
            AppError::Registry(format!(
                "ProjectAtlas meldete einen erfolgreichen Start, aber keine vollstaendige Einrichtung: {message}"
            ))
        })?;
        let canonical_root = confirmed_cli_root(&selected_root, &report.root)?;
        let config_files = config_files_for(&canonical_root);
        if config_files.iter().any(|file| !file.present)
            || !canonical_root
                .join(ATLAS_DIR_NAME)
                .join(ATLAS_DB_FILE_NAME)
                .is_file()
            || !canonical_root.join(PROJECT_MCP_FILE_NAME).is_file()
        {
            return Err(AppError::Registry(
                "ProjectAtlas meldete Erfolg, aber lokale Datenbank oder Host-Konfiguration sind nicht vollstaendig vorhanden."
                    .to_string(),
            ));
        }
        let suffix = if scan {
            " Der Index wurde neu aufgebaut."
        } else {
            " Ohne Scan verbunden — bis zum ersten Scan bleibt der Beziehungsgraph leer."
        };
        return Ok(InitAttempt {
            outcome: ConnectOutcome {
                succeeded: true,
                message: format!("{display_name} ist verbunden.{suffix}"),
                config_files,
                details: None,
                root: Some(canonical_root.display().to_string()),
            },
            canonical_root: Some(canonical_root),
        });
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let details = excerpt(&stderr).or_else(|| excerpt(&stdout));
    Ok(InitAttempt {
        outcome: ConnectOutcome {
            succeeded: false,
            message: format!("{display_name} konnte nicht verbunden werden."),
            config_files: config_files_for(&selected_root),
            details,
            root: None,
        },
        canonical_root: None,
    })
}

/// Run `projectatlas init` inside one registered project through the bundled sidecar.
///
/// # Errors
///
/// Returns an error when the project id is not registered, or when the bundled
/// `projectatlas` binary is missing from this build. A non-zero exit of the tool itself
/// is reported inside the outcome rather than as an error, so the setup screen can show
/// what the tool said.
#[tauri::command]
pub(crate) async fn connect_project(
    app: AppHandle,
    state: State<'_, AppState>,
    project_id: String,
    scan: bool,
) -> AppResult<ConnectOutcome> {
    let registry = state.registry_result().await?;
    let project = registry::find(&registry, &project_id)?.clone();
    drop(registry);

    Ok(run_init(&app, &project, scan).await?.outcome)
}

/// Initialize and register a folder chosen in the desktop app.
///
/// The registry is checked before the sidecar starts, then loaded again after init so
/// a concurrent safe registry change is not overwritten. Only a fully validated CLI
/// report may reach `add_manual`; the CLI-confirmed canonical root becomes the durable
/// registry identity and active project.
///
/// # Errors
///
/// Returns an error when the selected path is empty, the bundled CLI is unavailable,
/// its structured success report is incomplete, or the registry cannot be persisted.
#[tauri::command]
pub(crate) async fn connect_project_path(
    app: AppHandle,
    state: State<'_, AppState>,
    path: String,
    scan: bool,
) -> AppResult<ConnectOutcome> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(AppError::Registry(
            "Es wurde kein Projektordner ausgewaehlt.".to_string(),
        ));
    }

    // Fail before changing the selected folder when a future/invalid registry cannot
    // safely be updated after init.
    drop(state.registry_result().await?);

    let selected_root = PathBuf::from(trimmed);
    let display_name = selected_root.file_name().map_or_else(
        || selected_root.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    );
    let mut attempt = run_init_for_root(&app, &selected_root, &display_name, scan).await?;
    if !attempt.outcome.succeeded {
        return Ok(attempt.outcome);
    }
    let canonical_root = attempt.canonical_root.take().ok_or_else(|| {
        AppError::Registry("Der bestaetigte Projekt-Root fehlt nach der Einrichtung.".to_string())
    })?;

    let mut registry = state.registry_result().await?;
    let (updated, entry) = tauri::async_runtime::spawn_blocking(move || {
        let entry = registry::add_manual(&mut registry, &canonical_root)?;
        Ok::<_, AppError>((registry, entry))
    })
    .await
    .map_err(|error| AppError::Background(error.to_string()))??;

    state.set_registry(updated).await;
    state.set_active_project_id(entry.id).await;
    attempt.outcome.message = format!(
        "{} ist eingerichtet und als aktives Projekt ausgewaehlt.{}",
        entry.display_name,
        if scan {
            " Der lokale Index ist bereit."
        } else {
            " Der lokale Index wird beim ersten Scan aufgebaut."
        }
    );
    Ok(attempt.outcome)
}

/// Connect every registered project in one go, reporting progress as it goes.
///
/// Runs strictly one after another rather than in parallel: each `projectatlas init`
/// saturates a disk and rebuilds an index, so several at once would fight for the same
/// resources and make every single one slower.
///
/// A project that fails does not stop the run — its outcome is collected and the next
/// project starts, so one unreachable folder cannot block the other seven.
///
/// # Errors
///
/// Returns an error only when the bundled `projectatlas` binary is missing. Per-project
/// failures are reported inside the returned outcomes.
#[tauri::command]
pub(crate) async fn connect_all_projects(
    app: AppHandle,
    state: State<'_, AppState>,
    scan: bool,
) -> AppResult<Vec<ConnectOutcome>> {
    let projects: Vec<RegisteredProject> = {
        let registry = state.registry_result().await?;
        registry.projects.clone()
    };

    let total = projects.len();
    let mut outcomes = Vec::with_capacity(total);

    for (index, project) in projects.iter().enumerate() {
        drop(app.emit(
            EVENT_SETUP_PROGRESS,
            SetupProgressView {
                index,
                total,
                display_name: project.display_name.clone(),
                finished: false,
                succeeded: None,
            },
        ));

        let outcome = run_init(&app, project, scan).await?.outcome;

        drop(app.emit(
            EVENT_SETUP_PROGRESS,
            SetupProgressView {
                index,
                total,
                display_name: project.display_name.clone(),
                finished: true,
                succeeded: Some(outcome.succeeded),
            },
        ));

        outcomes.push(outcome);
    }

    Ok(outcomes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::io;

    /// Build one complete init report and allow focused tests to alter it.
    fn valid_report(scan: bool) -> Value {
        let scan_status = if scan { "verified" } else { "skipped" };
        json!({
            "ok": true,
            "root": "C:/work/example",
            "project_dir": {"status": "created", "path": "C:/work/example/.projectatlas"},
            "config": {"status": "created", "path": "C:/work/example/.projectatlas/config.toml"},
            "nonsource_files": {"status": "created", "path": "C:/work/example/.projectatlas/projectatlas-nonsource-files.toon"},
            "db": {"status": "created", "path": "C:/work/example/.projectatlas/projectatlas.db"},
            "host_configs": [
                {"harness": "mcp_json", "status": "created", "path": "C:/work/example/.projectatlas/projectatlas.mcp.json", "error": null},
                {"harness": "claude_code", "status": "created", "path": "C:/work/example/.projectatlas/projectatlas.claude.mcp.json", "error": null},
                {"harness": "opencode", "status": "created", "path": "C:/work/example/.projectatlas/projectatlas.opencode.json", "error": null},
                {"harness": "claude_code_project", "status": "created", "path": "C:/work/example/.mcp.json", "error": null}
            ],
            "scan": {"status": scan_status, "requested": scan, "error": null}
        })
    }

    /// Require one error whose display text contains the expected fragment.
    fn require_error<T, E: ToString>(
        result: Result<T, E>,
        expected: &str,
    ) -> Result<(), io::Error> {
        match result {
            Err(error) if error.to_string().contains(expected) => Ok(()),
            Err(error) => Err(io::Error::other(format!(
                "unexpected error, expected {expected:?}: {}",
                error.to_string()
            ))),
            Ok(_) => Err(io::Error::other(format!(
                "operation succeeded, expected error containing {expected:?}"
            ))),
        }
    }

    #[test]
    fn init_report_parser_keeps_cli_canonical_root() -> Result<(), String> {
        let bytes = serde_json::to_vec(&valid_report(true)).map_err(|error| error.to_string())?;
        let report = parse_init_report(&bytes, true)?;
        if report.root != "C:/work/example" {
            return Err("CLI root was not retained".to_string());
        }
        Ok(())
    }

    #[test]
    fn init_report_parser_rejects_malformed_json() -> Result<(), io::Error> {
        require_error(parse_init_report(b"not-json", true), "kein gueltiges JSON")
    }

    #[test]
    fn init_report_parser_rejects_partial_success() -> Result<(), Box<dyn std::error::Error>> {
        let mut report = valid_report(true);
        report["ok"] = json!(false);
        let bytes = serde_json::to_vec(&report)?;
        require_error(parse_init_report(&bytes, true), "fehlgeschlagene Phase")?;
        Ok(())
    }

    #[test]
    fn init_report_parser_requires_every_host_configuration()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut report = valid_report(true);
        let hosts = report["host_configs"]
            .as_array_mut()
            .ok_or_else(|| io::Error::other("host_configs fixture is not an array"))?;
        hosts.retain(|host| host["harness"] != "opencode");
        let bytes = serde_json::to_vec(&report)?;
        require_error(parse_init_report(&bytes, true), "opencode")?;
        Ok(())
    }

    #[test]
    fn init_report_parser_requires_requested_scan_mode() -> Result<(), Box<dyn std::error::Error>> {
        let bytes = serde_json::to_vec(&valid_report(false))?;
        require_error(parse_init_report(&bytes, true), "Index")?;
        Ok(())
    }

    #[test]
    fn cli_root_accepts_nested_folder_selected_inside_repository()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let root = directory.path().join("repository");
        let nested = root.join("src").join("feature");
        std::fs::create_dir_all(&nested)?;
        let canonical_root = root.canonicalize()?;
        let reported = canonical_root.display().to_string();

        let accepted = confirmed_cli_root(&nested, &reported)?;
        if accepted.canonicalize()? != canonical_root {
            return Err(io::Error::other("nested selection did not retain the CLI root").into());
        }
        Ok(())
    }

    #[test]
    fn cli_root_rejects_unrelated_folder() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let selected = directory.path().join("selected");
        let foreign = directory.path().join("foreign");
        std::fs::create_dir_all(&selected)?;
        std::fs::create_dir_all(&foreign)?;
        let reported = foreign.canonicalize()?.display().to_string();

        require_error(confirmed_cli_root(&selected, &reported), "liegt nicht")?;
        Ok(())
    }
}
