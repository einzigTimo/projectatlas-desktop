//! Purpose: Track locally known `ProjectAtlas` projects across app restarts.
//!
//! `ProjectAtlas` itself deliberately has no cross-repository project registry
//! (see `docs/projectatlas-mcp-multi-project-routing-spec.md`), so the desktop
//! app keeps its own small local list instead of relying on anything upstream.
//!
//! ## Registry migrations
//!
//! When the on-disk schema changes, `load()` applies a forward migration chain
//! before returning. Each version step is handled by a dedicated `migrate_vN`
//! function so new fields can be back-filled without losing existing entries.
//! `REGISTRY_VERSION` must be bumped and a new handler added for every
//! incompatible change.

use crate::app::error::{AppError, AppResult};
use projectatlas_core::Overview;
use projectatlas_db::AtlasStore;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;

/// Registry schema version, bumped whenever the on-disk shape changes incompatibly.
const REGISTRY_VERSION: u32 = 3;
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

/// Purpose lifecycle coverage for one project.
///
/// Built from aggregate index counters during probing so the sidebar can show
/// compact coverage badges without opening the database a second time.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub(crate) struct PurposeSummary {
    /// Number of current nodes in each durable purpose lifecycle state.
    pub(crate) by_status: BTreeMap<String, usize>,
    /// Total number of indexed file and folder nodes.
    pub(crate) total_nodes: usize,
    /// Number of nodes that currently carry a non-missing purpose.
    pub(crate) with_purpose: usize,
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
    /// Purpose lifecycle coverage read from the last successful probe.
    ///
    /// `None` when the database could not be opened on the last check.
    #[serde(default)]
    pub(crate) purpose_summary: Option<PurposeSummary>,
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
/// lint (`crates/projectatlas-lints`) forbids literal `C:\Users\...`-shaped paths.
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

// ── Migrations ────────────────────────────────────────────────────────────────

/// Apply all pending migrations from `current_version` to [`REGISTRY_VERSION`].
///
/// Each `migrate_vN` function is called exactly once per version bump that is
/// still ahead of the stored version. Migrations are additive: they back-fill
/// `#[serde(default)]` fields so existing entries survive round-trips.
fn apply_migrations(file: &mut RegistryFile) -> AppResult<bool> {
    if file.version == 0 || file.version > REGISTRY_VERSION {
        return Err(AppError::Registry(format!(
            "Nicht unterstuetzte Registry-Version {} (diese App unterstuetzt Version {}).",
            file.version, REGISTRY_VERSION
        )));
    }
    let mut changed = false;
    while file.version < REGISTRY_VERSION {
        match file.version {
            1 => {
                migrate_v2(file);
                file.version = 2;
                changed = true;
            }
            2 => {
                migrate_v3(file);
                file.version = 3;
                changed = true;
            }
            version => {
                return Err(AppError::Registry(format!(
                    "Kein Registry-Migrationspfad ab Version {version} vorhanden."
                )));
            }
        }
    }
    Ok(changed)
}

/// v1 → v2: introduce the optional purpose-summary field.
///
/// The v2 preview represented free Purpose text as categories. Keep this step
/// explicit for registries produced by v1, but discard that legacy projection;
/// v3 rebuilds the field with the correct lifecycle semantics.
fn migrate_v2(file: &mut RegistryFile) {
    for project in &mut file.projects {
        project.purpose_summary = None;
    }
}

/// v2 → v3: replace legacy Purpose categories with lifecycle coverage.
///
/// One bounded aggregate read per known project hydrates the corrected shape.
/// Unreachable projects remain registered with `None`; no project index is
/// rebuilt or otherwise mutated.
fn migrate_v3(file: &mut RegistryFile) {
    for project in &mut file.projects {
        project.purpose_summary = purpose_summary_for_project(&project.db_path, &project.root);
    }
}

/// Read purpose lifecycle coverage without changing the project database.
fn purpose_summary_for_project(db_path: &Path, root: &Path) -> Option<PurposeSummary> {
    if !db_path.exists() {
        return None;
    }
    AtlasStore::open_read_only_for_project(db_path, root)
        .ok()
        .and_then(|store| build_purpose_summary(&store))
}

// ── Persistence ───────────────────────────────────────────────────────────────

/// Load the registry from disk, applying pending migrations before returning.
///
/// Returns a fresh default when no registry file exists yet.
pub(crate) fn load() -> AppResult<RegistryFile> {
    let path = registry_path()?;
    load_from_path(&path)
}

/// Load and, when required, migrate one explicit registry path.
fn load_from_path(path: &Path) -> AppResult<RegistryFile> {
    if !path.exists() {
        return Ok(RegistryFile::default());
    }
    let raw = fs::read_to_string(path)?;
    let mut file: RegistryFile = serde_json::from_str(&raw)?;
    if apply_migrations(&mut file)? {
        // Persist the migrated file atomically so an interrupted update leaves
        // either the complete old registry or the complete new registry.
        save_to_path(&file, path)?;
    }
    Ok(file)
}

/// Persist the registry to disk through a same-directory atomic replacement.
pub(crate) fn save(registry: &RegistryFile) -> AppResult<()> {
    let path = registry_path()?;
    save_to_path(registry, &path)
}

/// Serialize and atomically replace one explicit registry path.
fn save_to_path(registry: &RegistryFile, path: &Path) -> AppResult<()> {
    let parent = path.parent().ok_or_else(|| {
        AppError::Registry(format!(
            "Registry-Pfad ohne Verzeichnis: {}",
            path.display()
        ))
    })?;
    fs::create_dir_all(parent)?;
    let mut temporary = NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(&mut temporary, registry)?;
    temporary.write_all(b"\n")?;
    temporary.as_file_mut().sync_all()?;
    temporary
        .persist(path)
        .map_err(|error| AppError::Io(error.error))?;
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
    let (status, purpose_summary) = if db_path.exists() {
        match AtlasStore::open_read_only_for_project(&db_path, root) {
            Ok(store) => {
                let summary = build_purpose_summary(&store);
                (ProjectStatus::Ok, summary)
            }
            Err(error) => (
                ProjectStatus::OpenError {
                    message: AppError::from(error).to_string(),
                },
                None,
            ),
        }
    } else {
        (ProjectStatus::NotFound, None)
    };
    RegisteredProject {
        id: project_id(root),
        root: root.to_path_buf(),
        db_path,
        display_name,
        source,
        status,
        last_seen_epoch: now_epoch(),
        purpose_summary,
    }
}

/// Build a [`PurposeSummary`] from every indexed node in `store`.
///
/// Uses the store's aggregate overview query rather than loading every indexed
/// node. Purpose text is intentionally not treated as a category: upstream
/// purposes are free one-line responsibility descriptions.
fn build_purpose_summary(store: &AtlasStore) -> Option<PurposeSummary> {
    store
        .overview()
        .ok()
        .map(|overview| purpose_summary_from_overview(&overview))
}

/// Project one aggregate index overview onto the persisted desktop summary.
fn purpose_summary_from_overview(overview: &Overview) -> PurposeSummary {
    let by_status = BTreeMap::from([
        ("approved".to_string(), overview.approved_purposes),
        ("suggested".to_string(), overview.suggested_purposes),
        ("stale".to_string(), overview.stale_purposes),
        ("missing".to_string(), overview.missing_purposes),
    ]);
    let with_purpose = overview
        .approved_purposes
        .saturating_add(overview.suggested_purposes)
        .saturating_add(overview.stale_purposes);
    PurposeSummary {
        by_status,
        total_nodes: overview.files.saturating_add(overview.folders),
        with_purpose,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    #[test]
    fn v1_registry_migrates_without_losing_projects() -> Result<(), Box<dyn std::error::Error>> {
        let raw = r#"{
          "version": 1,
          "scan_roots": ["D:/work"],
          "projects": [{
            "id": "one",
            "root": "D:/work/one",
            "db_path": "D:/work/one/.projectatlas/projectatlas.db",
            "display_name": "one",
            "source": "manual",
            "status": {"state": "ok"},
            "last_seen_epoch": 7
        }]
        }"#;
        let directory = tempfile::tempdir()?;
        let path = directory.path().join(REGISTRY_FILE_NAME);
        fs::write(&path, raw)?;
        let registry = load_from_path(&path)?;
        let persisted: RegistryFile = serde_json::from_str(&fs::read_to_string(&path)?)?;

        if registry.version != REGISTRY_VERSION
            || registry.projects.len() != 1
            || registry.projects[0].display_name != "one"
            || registry.projects[0].purpose_summary.is_some()
            || persisted.version != REGISTRY_VERSION
            || persisted.projects.len() != 1
        {
            return Err(io::Error::other("v1 registry migration lost project data").into());
        }
        Ok(())
    }

    #[test]
    fn legacy_v2_category_summary_migrates_to_v3_without_losing_project()
    -> Result<(), Box<dyn std::error::Error>> {
        let raw = r#"{
          "version": 2,
          "scan_roots": ["D:/work"],
          "projects": [{
            "id": "legacy-v2",
            "root": "D:/work/legacy-v2",
            "db_path": "D:/work/legacy-v2/.projectatlas/projectatlas.db",
            "display_name": "legacy-v2",
            "source": "manual",
            "status": {"state": "ok"},
            "last_seen_epoch": 9,
            "purpose_summary": {
              "byCategory": {"docs": 4},
              "totalNodes": 4
            }
          }]
        }"#;
        let directory = tempfile::tempdir()?;
        let path = directory.path().join(REGISTRY_FILE_NAME);
        fs::write(&path, raw)?;

        let registry = load_from_path(&path)?;
        if registry.version != REGISTRY_VERSION
            || registry.projects.len() != 1
            || registry.projects[0].display_name != "legacy-v2"
            || registry.projects[0].purpose_summary.is_some()
        {
            return Err(io::Error::other("legacy v2 registry migration lost project data").into());
        }
        Ok(())
    }

    #[test]
    fn v1_migration_hydrates_readable_purpose_coverage() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let root = directory.path().join("project");
        let db_path = root.join(PROJECT_DB_RELATIVE_PATH);
        fs::create_dir_all(
            db_path
                .parent()
                .ok_or_else(|| io::Error::other("test database path unexpectedly has no parent"))?,
        )?;
        let mut store = AtlasStore::open_for_project(&db_path, &root)?;
        store.replace_scan(&[projectatlas_core::Node {
            path: "src/main.rs".to_string(),
            kind: projectatlas_core::NodeKind::File,
            parent_path: projectatlas_core::normalized_parent("src/main.rs"),
            extension: Some(".rs".to_string()),
            language: Some("rust".to_string()),
            size_bytes: Some(12),
            mtime_ns: Some(7),
            content_hash: Some("hash-main".to_string()),
        }])?;
        drop(store);

        let path = directory.path().join(REGISTRY_FILE_NAME);
        save_to_path(
            &RegistryFile {
                version: 1,
                scan_roots: Vec::new(),
                projects: vec![RegisteredProject {
                    id: "project".to_string(),
                    root,
                    db_path,
                    display_name: "project".to_string(),
                    source: ProjectSource::Manual,
                    status: ProjectStatus::Ok,
                    last_seen_epoch: 7,
                    purpose_summary: None,
                }],
            },
            &path,
        )?;

        let migrated = load_from_path(&path)?;
        let summary = migrated.projects[0]
            .purpose_summary
            .as_ref()
            .ok_or_else(|| io::Error::other("purpose coverage was not hydrated"))?;
        if summary.total_nodes != 1 || summary.by_status.get("missing") != Some(&1) {
            return Err(io::Error::other("hydrated purpose coverage is incorrect").into());
        }
        Ok(())
    }

    #[test]
    fn future_registry_version_is_rejected_without_rewrite()
    -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join(REGISTRY_FILE_NAME);
        let raw = format!(
            "{{\"version\":{},\"scan_roots\":[],\"projects\":[],\"future\":true}}",
            REGISTRY_VERSION + 1
        );
        fs::write(&path, &raw)?;

        if !matches!(
            load_from_path(&path),
            Err(AppError::Registry(message)) if message.contains("Nicht unterstuetzte")
        ) {
            return Err(io::Error::other("future registry version was accepted").into());
        }
        if fs::read_to_string(&path)? != raw {
            return Err(io::Error::other("future registry file was rewritten").into());
        }
        Ok(())
    }

    #[test]
    fn purpose_summary_uses_lifecycle_counts() {
        let summary = purpose_summary_from_overview(&Overview {
            files: 8,
            folders: 2,
            missing_purposes: 3,
            stale_purposes: 1,
            approved_purposes: 4,
            suggested_purposes: 2,
        });
        assert_eq!(summary.total_nodes, 10);
        assert_eq!(summary.with_purpose, 7);
        assert_eq!(summary.by_status.get("approved"), Some(&4));
        assert_eq!(summary.by_status.get("missing"), Some(&3));
    }

    #[test]
    fn registry_save_replaces_one_complete_json_file() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join(REGISTRY_FILE_NAME);
        let mut registry = RegistryFile {
            version: REGISTRY_VERSION,
            scan_roots: vec![PathBuf::from("D:/first")],
            projects: Vec::new(),
        };

        save_to_path(&registry, &path)?;
        registry.scan_roots = vec![PathBuf::from("D:/replacement")];
        save_to_path(&registry, &path)?;
        let loaded = load_from_path(&path)?;

        if loaded.version != REGISTRY_VERSION
            || loaded.scan_roots != vec![PathBuf::from("D:/replacement")]
        {
            return Err(io::Error::other("existing registry was not replaced").into());
        }
        if fs::read_dir(directory.path())?.count() != 1 {
            return Err(io::Error::other("temporary registry file was not replaced").into());
        }
        Ok(())
    }
}
