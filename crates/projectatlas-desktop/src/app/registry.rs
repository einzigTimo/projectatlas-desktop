//! Purpose: Track locally known `ProjectAtlas` projects across app restarts.
//!
//! `ProjectAtlas` itself deliberately has no cross-repository project registry
//! (see `docs/projectatlas-mcp-multi-project-routing-spec.md`), so the desktop
//! app keeps its own small local list instead of relying on anything upstream.

use crate::app::error::{AppError, AppResult};
use projectatlas_db::AtlasStore;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Registry schema version, bumped whenever the on-disk shape changes incompatibly.
const REGISTRY_VERSION: u32 = 1;
/// Registry directory name under `%LOCALAPPDATA%`.
const REGISTRY_DIR_NAME: &str = "ProjectAtlasDesktop";
/// Registry file name inside [`REGISTRY_DIR_NAME`].
const REGISTRY_FILE_NAME: &str = "registry.json";
/// Relative path from a candidate project root to its `ProjectAtlas` database.
const PROJECT_DB_RELATIVE_PATH: &str = ".projectatlas/projectatlas.db";
/// Maximum directory depth walked below a scan root while auto-discovering projects.
const AUTO_SCAN_MAX_DEPTH: usize = 4;

/// Where a registered project entry came from.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ProjectSource {
    /// Discovered by scanning a configured root folder.
    Auto,
    /// Added explicitly by the user through the folder picker.
    Manual,
}

/// Current reachability of a registered project's database.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub(crate) enum ProjectStatus {
    /// The database opened successfully on the last check.
    Ok,
    /// The database file no longer exists at the recorded path.
    NotFound,
    /// The database exists but failed to open (e.g. moved, corrupted, wrong root).
    OpenError {
        /// Human-readable failure reason.
        message: String,
    },
}

/// One project known to the desktop app.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct RegisteredProject {
    /// Stable identifier derived from the project's canonical root path.
    pub(crate) id: String,
    /// Project root folder.
    pub(crate) root: PathBuf,
    /// Path to the project's `ProjectAtlas` `SQLite` database.
    pub(crate) db_path: PathBuf,
    /// Name shown in the sidebar, defaulting to the root folder name.
    pub(crate) display_name: String,
    /// Where this entry came from.
    pub(crate) source: ProjectSource,
    /// Reachability recorded on the last scan or manual check.
    pub(crate) status: ProjectStatus,
    /// Unix epoch seconds when this entry was last confirmed reachable.
    pub(crate) last_seen_epoch: i64,
}

/// The full on-disk registry contents.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct RegistryFile {
    /// Schema version of this file.
    pub(crate) version: u32,
    /// Folders scanned automatically for `.projectatlas` databases.
    pub(crate) scan_roots: Vec<PathBuf>,
    /// Known projects, both auto-discovered and manually added.
    pub(crate) projects: Vec<RegisteredProject>,
}

impl Default for RegistryFile {
    fn default() -> Self {
        Self {
            version: REGISTRY_VERSION,
            scan_roots: default_scan_root().into_iter().collect(),
            projects: Vec::new(),
        }
    }
}

/// Return the default folder to auto-scan, derived from `%USERPROFILE%` at runtime.
///
/// Never hardcode a concrete home-directory path in source: the `strict-strings`
/// lint (`crates/projectatlas-lints`) forbids literal home-directory paths (for
/// example `%USERPROFILE%\Projects` resolved to a concrete user folder).
fn default_scan_root() -> Option<PathBuf> {
    env::var_os("USERPROFILE").map(|home| Path::new(&home).join("Projects"))
}

/// Return the path to the registry JSON file, creating its directory if needed.
fn registry_path() -> AppResult<PathBuf> {
    let local_app_data =
        env::var_os("LOCALAPPDATA").ok_or(AppError::MissingEnvVar("LOCALAPPDATA"))?;
    let dir = Path::new(&local_app_data).join(REGISTRY_DIR_NAME);
    fs::create_dir_all(&dir)?;
    Ok(dir.join(REGISTRY_FILE_NAME))
}

/// Load the registry from disk, returning a fresh default when none exists yet.
pub(crate) fn load() -> AppResult<RegistryFile> {
    let path = registry_path()?;
    if !path.exists() {
        return Ok(RegistryFile::default());
    }
    let raw = fs::read_to_string(&path)?;
    Ok(serde_json::from_str(&raw)?)
}

/// Persist the registry to disk.
pub(crate) fn save(registry: &RegistryFile) -> AppResult<()> {
    let path = registry_path()?;
    let raw = serde_json::to_string_pretty(registry)?;
    fs::write(path, raw)?;
    Ok(())
}

/// Derive a stable project id from its root path.
fn project_id(root: &Path) -> String {
    let normalized = root.to_string_lossy().to_lowercase();
    let normalized = normalized.trim_end_matches(['\\', '/']);
    blake3::hash(normalized.as_bytes()).to_hex().to_string()
}

/// Return the current Unix epoch in whole seconds, saturating at zero on clock errors.
fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Probe one candidate project root and build its registry entry.
fn probe_project(root: &Path, source: ProjectSource) -> RegisteredProject {
    let db_path = root.join(PROJECT_DB_RELATIVE_PATH);
    let display_name = root.file_name().map_or_else(
        || root.to_string_lossy().into_owned(),
        |name| name.to_string_lossy().into_owned(),
    );
    let status = if db_path.exists() {
        match AtlasStore::open_read_only_for_project(&db_path, root) {
            Ok(_store) => ProjectStatus::Ok,
            Err(error) => ProjectStatus::OpenError {
                // Route through AppError so an outdated schema reads as the actionable
                // German hint here too, not only in the query path.
                message: AppError::from(error).to_string(),
            },
        }
    } else {
        ProjectStatus::NotFound
    };
    RegisteredProject {
        id: project_id(root),
        root: root.to_path_buf(),
        db_path,
        display_name,
        source,
        status,
        last_seen_epoch: now_epoch(),
    }
}

/// Re-check every already-registered project's reachability without discovering new ones.
fn recheck_known(registry: &mut RegistryFile) {
    for project in &mut registry.projects {
        *project = probe_project(&project.root, project.source);
    }
}

/// Walk the configured scan roots for `.projectatlas/projectatlas.db` and merge findings.
///
/// Never removes an entry that goes missing: a project on an unmounted drive or a
/// renamed folder stays visible as [`ProjectStatus::NotFound`] instead of vanishing.
pub(crate) fn rescan(registry: &mut RegistryFile) -> AppResult<()> {
    recheck_known(registry);

    let mut discovered = Vec::new();
    for scan_root in registry.scan_roots.clone() {
        if !scan_root.exists() {
            continue;
        }
        let walker = ignore::WalkBuilder::new(&scan_root)
            .max_depth(Some(AUTO_SCAN_MAX_DEPTH))
            .hidden(false)
            .build();
        for entry in walker.filter_map(Result::ok) {
            if entry.file_type().is_some_and(|kind| kind.is_dir())
                && entry.path().join(PROJECT_DB_RELATIVE_PATH).exists()
            {
                discovered.push(entry.path().to_path_buf());
            }
        }
    }

    let known_ids: std::collections::HashSet<String> =
        registry.projects.iter().map(|p| p.id.clone()).collect();
    for root in discovered {
        let id = project_id(&root);
        if !known_ids.contains(&id) {
            registry
                .projects
                .push(probe_project(&root, ProjectSource::Auto));
        }
    }
    save(registry)
}

/// Validate and register a manually chosen project folder.
pub(crate) fn add_manual(registry: &mut RegistryFile, root: &Path) -> AppResult<RegisteredProject> {
    let db_path = root.join(PROJECT_DB_RELATIVE_PATH);
    if !db_path.exists() {
        return Err(AppError::Registry(format!(
            "Kein ProjectAtlas-Projekt in {} gefunden ({} fehlt)",
            root.display(),
            PROJECT_DB_RELATIVE_PATH
        )));
    }
    let entry = probe_project(root, ProjectSource::Manual);
    registry.projects.retain(|existing| existing.id != entry.id);
    registry.projects.push(entry.clone());
    save(registry)?;
    Ok(entry)
}

/// Remove a project from the registry by id.
pub(crate) fn remove(registry: &mut RegistryFile, project_id: &str) -> AppResult<()> {
    let before = registry.projects.len();
    registry.projects.retain(|project| project.id != project_id);
    if registry.projects.len() == before {
        return Err(AppError::UnknownProject(project_id.to_string()));
    }
    save(registry)
}

/// Look up one registered project by id.
pub(crate) fn find<'a>(
    registry: &'a RegistryFile,
    project_id: &str,
) -> AppResult<&'a RegisteredProject> {
    registry
        .projects
        .iter()
        .find(|project| project.id == project_id)
        .ok_or_else(|| AppError::UnknownProject(project_id.to_string()))
}
