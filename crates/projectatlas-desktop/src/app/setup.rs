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
    /// so the joined result uses native separators — a literal `".config/opencode"`
    /// would surface to the user as `C:\Users\...\.config/opencode`.
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
    let registry = state.registry().await;
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
) -> AppResult<ConnectOutcome> {
    let root = project.root.clone();
    let display_name = project.display_name.clone();

    if !root.is_dir() {
        return Ok(ConnectOutcome {
            succeeded: false,
            message: format!(
                "Der Ordner von {display_name} ist nicht erreichbar: {}",
                root.display()
            ),
            config_files: Vec::new(),
            details: None,
        });
    }

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
        .current_dir(root.clone())
        .args(args);

    let output = command.output().await?;
    let config_files = config_files_for(&root);

    if output.status.success() {
        let suffix = if scan {
            " Der Index wurde neu aufgebaut."
        } else {
            " Ohne Scan verbunden — bis zum ersten Scan bleibt der Beziehungsgraph leer."
        };
        return Ok(ConnectOutcome {
            succeeded: true,
            message: format!("{display_name} ist verbunden.{suffix}"),
            config_files,
            details: None,
        });
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let details = excerpt(&stderr).or_else(|| excerpt(&stdout));
    Ok(ConnectOutcome {
        succeeded: false,
        message: format!("{display_name} konnte nicht verbunden werden."),
        config_files,
        details,
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
    let registry = state.registry().await;
    let project = registry::find(&registry, &project_id)?.clone();
    drop(registry);

    run_init(&app, &project, scan).await
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
        let registry = state.registry().await;
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

        let outcome = run_init(&app, project, scan).await?;

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
