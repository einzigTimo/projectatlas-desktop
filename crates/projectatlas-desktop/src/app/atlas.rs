//! Purpose: Build the bounded relationship preview shown as the "Atlas Map".
//!
//! This mirrors what `load_token_atlas_preview` does for the terminal view
//! (`crates/projectatlas-cli/src/token_tui.rs`), but stays deliberately smaller:
//! the strongest hubs per relation family plus their immediate neighbours. That is
//! enough for a readable picture in a 340px panel and keeps the read cheap, so the
//! map can be refreshed on every project switch without stalling the window.
//!
//! A failing graph read is not an error here. The graph is optional — a project may
//! simply have no published relation generation yet — so the view reports itself as
//! unavailable and the panel says so, exactly like the terminal version does.

use crate::app::error::AppResult;
use projectatlas_core::graph::{
    EntitySelector, GraphEntity, GraphRelationKind, RepositoryNodePath,
};
use projectatlas_core::symbols::RelationKind;
use projectatlas_db::{AtlasStore, RepositoryGraphDirection, RepositoryGraphRelationQuery};
use serde::Serialize;
use std::collections::{BTreeSet, HashSet};
use std::path::Path;

/// Strongest endpoints requested per relation family.
const HUBS_PER_FAMILY: u32 = 2;
/// Hubs admitted into the preview across all families.
const MAX_HUBS: usize = 6;
/// Neighbour relations requested per hub.
const EDGES_PER_HUB: u32 = 10;
/// Nodes admitted into the preview.
const MAX_NODES: usize = 42;
/// Edges admitted into the preview.
const MAX_EDGES: usize = 64;
/// Longest node label forwarded to the frontend.
const MAX_LABEL: usize = 28;
/// Ranked endpoints requested per relation family for the file summary.
const SUMMARY_HUBS_PER_FAMILY: u32 = 8;
/// Unique file candidates considered for the incoming-relation summary.
const MAX_SUMMARY_CANDIDATES: usize = 24;
/// Incoming relations counted per summary candidate.
const SUMMARY_RELATIONS_PER_FILE: u32 = 128;
/// Files shown in the compact relation summary.
const MAX_RELATION_SUMMARY: usize = 5;
/// Direct neighbours returned for one explicit drill-down direction.
const DRILLDOWN_RELATIONS_PER_DIRECTION: u32 = 40;

/// One node of the relationship preview.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AtlasNode {
    /// Stable compact identity, also used as the edge endpoint id.
    pub(crate) id: String,
    /// Short human-readable name.
    pub(crate) label: String,
    /// Cluster index used for the cycling node color.
    pub(crate) cluster: usize,
    /// Whether this node is one of the strongest endpoints.
    pub(crate) hub: bool,
    /// Repository path when the entity is backed by a local file or folder.
    pub(crate) path: Option<String>,
    /// Stable entity-kind label used by the detail panel.
    pub(crate) entity_kind: String,
}

/// One resolved relation between two preview nodes.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AtlasEdge {
    /// Compact identity of the source node.
    pub(crate) source: String,
    /// Compact identity of the target node.
    pub(crate) target: String,
    /// Stable typed relation family such as `extended:documents`.
    pub(crate) relation: String,
}

/// One high-value file ranked by its incoming repository relations.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RelationSummaryEntry {
    /// Repository-relative file path.
    pub(crate) path: String,
    /// Compact display label.
    pub(crate) label: String,
    /// Number of retained incoming relations in the bounded read.
    pub(crate) incoming: usize,
    /// Stable relation families observed for the incoming rows.
    pub(crate) relation_kinds: Vec<String>,
}

/// One direct neighbour in a file relation drill-down.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FileRelationEntry {
    /// Direction relative to the selected file: `incoming` or `outgoing`.
    pub(crate) direction: String,
    /// Stable typed relation family.
    pub(crate) relation: String,
    /// Compact neighbour label.
    pub(crate) label: String,
    /// Repository path when the neighbour is local and path-backed.
    pub(crate) path: Option<String>,
    /// Stable entity-kind label.
    pub(crate) entity_kind: String,
}

/// Direct incoming and outgoing relations for one selected file.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FileRelationsView {
    /// Normalized repository-relative selected path.
    pub(crate) path: String,
    /// Direct incoming neighbours.
    pub(crate) incoming: Vec<FileRelationEntry>,
    /// Direct outgoing neighbours.
    pub(crate) outgoing: Vec<FileRelationEntry>,
    /// Whether a query ceiling omitted further relations.
    pub(crate) truncated: bool,
}

/// The bounded relationship preview, or an explicit unavailable state.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AtlasView {
    /// Whether the optional graph read completed.
    pub(crate) available: bool,
    /// Whether a source page or a preview ceiling omitted further relations.
    pub(crate) truncated: bool,
    /// Preview nodes.
    pub(crate) nodes: Vec<AtlasNode>,
    /// Preview edges.
    pub(crate) edges: Vec<AtlasEdge>,
    /// Top local files by bounded incoming relation count.
    pub(crate) relation_summary: Vec<RelationSummaryEntry>,
}

impl AtlasView {
    /// Build the state used when the optional graph read fails or is absent.
    fn unavailable() -> Self {
        Self {
            available: false,
            truncated: false,
            nodes: Vec::new(),
            edges: Vec::new(),
            relation_summary: Vec::new(),
        }
    }
}

/// Return whether a relation belongs in the cross-entity network.
///
/// Containment is excluded for the same reason the terminal view excludes it: a
/// folder-contains-file tree crowds out the relations that actually say something.
const fn network_relation(kind: GraphRelationKind) -> bool {
    !matches!(kind, GraphRelationKind::Legacy(RelationKind::Contains))
}

/// Shorten a label to [`MAX_LABEL`] characters, keeping the tail.
fn shorten(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAX_LABEL {
        return text.to_string();
    }
    let tail: String = text.chars().skip(count - MAX_LABEL + 1).collect();
    format!("…{tail}")
}

/// Return the last path segment, or the whole path when it has none.
fn last_segment(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Derive a short display name from one entity selector.
fn label(selector: &EntitySelector) -> String {
    let raw = match selector {
        EntitySelector::Project => "Projekt".to_string(),
        EntitySelector::Folder { path } => last_segment(path.as_str()).to_string(),
        EntitySelector::File { path } => last_segment(path.as_str()).to_string(),
        EntitySelector::Package { package } => package.name.as_str().to_string(),
        EntitySelector::Symbol { symbol } => symbol.name.as_str().to_string(),
        EntitySelector::External { external } => external.identity.as_str().to_string(),
    };
    shorten(&raw)
}

/// Return a stable entity-kind label for the frontend.
const fn entity_kind(selector: &EntitySelector) -> &'static str {
    match selector {
        EntitySelector::Project => "project",
        EntitySelector::Folder { .. } => "folder",
        EntitySelector::File { .. } => "file",
        EntitySelector::Package { .. } => "package",
        EntitySelector::Symbol { .. } => "symbol",
        EntitySelector::External { .. } => "external",
    }
}

/// Return the repository path carried by a local path-backed selector.
fn selector_path(selector: &EntitySelector) -> Option<String> {
    match selector {
        EntitySelector::Folder { path } => Some(path.as_str().to_string()),
        EntitySelector::File { path } => Some(path.as_str().to_string()),
        EntitySelector::Package { package } => Some(package.manifest.as_str().to_string()),
        EntitySelector::Symbol { symbol } => Some(symbol.file.as_str().to_string()),
        EntitySelector::Project | EntitySelector::External { .. } => None,
    }
}

/// Build the compact top-file relation summary through bounded graph queries.
fn relation_summary(store: &AtlasStore) -> Option<(Vec<RelationSummaryEntry>, bool)> {
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    let mut truncated = false;
    'outer: for kind in GraphRelationKind::ALL {
        if !network_relation(kind) {
            continue;
        }
        let page = store
            .repository_graph_resolved_relation_hubs(kind, SUMMARY_HUBS_PER_FAMILY, None)
            .ok()?;
        truncated |= page.truncated;
        for entity in page.rows {
            if !matches!(entity.selector(), EntitySelector::File { .. }) {
                continue;
            }
            let digest = entity.key().digest().to_string();
            if !seen.insert(digest) {
                continue;
            }
            if candidates.len() >= MAX_SUMMARY_CANDIDATES {
                truncated = true;
                break 'outer;
            }
            candidates.push(entity);
        }
    }

    let mut entries = Vec::new();
    for entity in candidates {
        let page = store
            .repository_graph_relation_rows(
                RepositoryGraphRelationQuery::Inbound {
                    target: entity.key().clone(),
                },
                SUMMARY_RELATIONS_PER_FILE,
                None,
            )
            .ok()?;
        truncated |= page.truncated;
        let rows = page
            .rows
            .iter()
            .filter(|row| network_relation(row.relation.kind()))
            .collect::<Vec<_>>();
        if rows.is_empty() {
            continue;
        }
        let relation_kinds = rows
            .iter()
            .map(|row| row.relation.kind().as_str().to_string())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let Some(path) = selector_path(entity.selector()) else {
            continue;
        };
        entries.push(RelationSummaryEntry {
            label: label(entity.selector()),
            path,
            incoming: rows.len(),
            relation_kinds,
        });
    }
    entries.sort_by(|left, right| {
        right
            .incoming
            .cmp(&left.incoming)
            .then_with(|| left.path.cmp(&right.path))
    });
    if entries.len() > MAX_RELATION_SUMMARY {
        entries.truncate(MAX_RELATION_SUMMARY);
        truncated = true;
    }
    Some((entries, truncated))
}

/// Collect the strongest endpoints across every network relation family.
fn collect_hubs(store: &AtlasStore) -> Option<(Vec<projectatlas_core::graph::GraphEntity>, bool)> {
    let mut hubs = Vec::new();
    let mut seen = HashSet::new();
    let mut truncated = false;
    for kind in GraphRelationKind::ALL {
        if !network_relation(kind) {
            continue;
        }
        let page = store
            .repository_graph_resolved_relation_hubs(kind, HUBS_PER_FAMILY, None)
            .ok()?;
        truncated |= page.truncated;
        for entity in page.rows {
            if hubs.len() >= MAX_HUBS {
                truncated = true;
                break;
            }
            if seen.insert(entity.key().digest().to_string()) {
                hubs.push(entity);
            }
        }
    }
    Some((hubs, truncated))
}

/// Load the bounded relationship preview for one project.
///
/// # Errors
///
/// Returns an error only when the project database itself cannot be opened. A
/// missing or failing graph generation yields an unavailable view instead.
pub(crate) fn atlas_map(db_path: &Path, root: &Path) -> AppResult<AtlasView> {
    let store = AtlasStore::open_read_only_for_project(db_path, root)?;
    let Some((hubs, mut truncated)) = collect_hubs(&store) else {
        return Ok(AtlasView::unavailable());
    };
    let (relation_summary, summary_truncated) =
        relation_summary(&store).unwrap_or_else(|| (Vec::new(), true));
    truncated |= summary_truncated;
    if hubs.is_empty() {
        return Ok(AtlasView {
            available: true,
            truncated,
            nodes: Vec::new(),
            edges: Vec::new(),
            relation_summary,
        });
    }

    let mut nodes: Vec<AtlasNode> = Vec::new();
    let mut edges: Vec<AtlasEdge> = Vec::new();
    let mut node_ids = HashSet::new();
    let mut edge_keys = HashSet::new();

    for (cluster, hub) in hubs.iter().enumerate() {
        let hub_id = hub.key().digest().to_string();
        if node_ids.insert(hub_id.clone()) && nodes.len() < MAX_NODES {
            nodes.push(AtlasNode {
                id: hub_id.clone(),
                label: label(hub.selector()),
                cluster,
                hub: true,
                path: selector_path(hub.selector()),
                entity_kind: entity_kind(hub.selector()).to_string(),
            });
        }

        let Ok(page) = store.repository_graph_relation_rows(
            RepositoryGraphRelationQuery::Outbound {
                source: hub.key().clone(),
            },
            EDGES_PER_HUB,
            None,
        ) else {
            truncated = true;
            continue;
        };
        truncated |= page.truncated;

        for row in page.rows {
            if !network_relation(row.relation.kind()) {
                continue;
            }
            let relation = row.relation.kind().as_str().to_string();
            let Some(target) = row.target else {
                continue;
            };
            let target_id = target.key().digest().to_string();
            if target_id == hub_id {
                continue;
            }
            if !node_ids.contains(&target_id) {
                if nodes.len() >= MAX_NODES {
                    truncated = true;
                    continue;
                }
                node_ids.insert(target_id.clone());
                nodes.push(AtlasNode {
                    id: target_id.clone(),
                    label: label(target.selector()),
                    cluster,
                    hub: false,
                    path: selector_path(target.selector()),
                    entity_kind: entity_kind(target.selector()).to_string(),
                });
            }
            if edges.len() >= MAX_EDGES {
                truncated = true;
                break;
            }
            if edge_keys.insert(format!("{hub_id}>{target_id}:{relation}")) {
                edges.push(AtlasEdge {
                    source: hub_id.clone(),
                    target: target_id,
                    relation,
                });
            }
        }
    }

    Ok(AtlasView {
        available: true,
        truncated,
        nodes,
        edges,
        relation_summary,
    })
}

/// Return a direct bounded relation drill-down for one repository file.
///
/// # Errors
///
/// Returns an error when the database cannot be opened, the path is invalid,
/// or a graph query fails. A valid file without a published graph entity yields
/// an empty view.
pub(crate) fn file_relations(
    db_path: &Path,
    root: &Path,
    file_path: &str,
) -> AppResult<FileRelationsView> {
    let store = AtlasStore::open_read_only_for_project(db_path, root)?;
    let normalized = RepositoryNodePath::new(Path::new(file_path)).map_err(|error| {
        crate::app::error::AppError::Registry(format!(
            "Ungueltiger Repository-Pfad {file_path}: {error}"
        ))
    })?;
    let mut view = FileRelationsView {
        path: normalized.as_str().to_string(),
        incoming: Vec::new(),
        outgoing: Vec::new(),
        truncated: false,
    };
    let Some(project) = store.project_instance_id()? else {
        return Ok(view);
    };
    let entities = store.repository_graph_entities_by_path(project, &normalized, 16)?;
    let Some(file) = entities
        .rows
        .into_iter()
        .find(|entity| matches!(entity.selector(), EntitySelector::File { .. }))
    else {
        return Ok(view);
    };

    let (incoming, incoming_truncated) = resolved_file_relations(
        &store,
        file.key(),
        RepositoryGraphDirection::Inbound,
        "incoming",
    )?;
    let (outgoing, outgoing_truncated) = resolved_file_relations(
        &store,
        file.key(),
        RepositoryGraphDirection::Outbound,
        "outgoing",
    )?;
    view.incoming = incoming;
    view.outgoing = outgoing;
    view.truncated = incoming_truncated || outgoing_truncated;
    Ok(view)
}

/// Read direct local neighbours without letting unresolved rows consume the
/// public drill-down limit. The database applies its resolution filter before
/// each bounded family page; the merged frontend result is capped afterwards.
fn resolved_file_relations(
    store: &AtlasStore,
    file: &projectatlas_core::graph::GraphEntityKey,
    direction: RepositoryGraphDirection,
    direction_label: &str,
) -> AppResult<(Vec<FileRelationEntry>, bool)> {
    let mut entries = Vec::new();
    let mut seen = HashSet::new();
    let mut truncated = false;

    for relation in GraphRelationKind::ALL {
        if !network_relation(relation) {
            continue;
        }
        let page = store.repository_graph_resolved_adjacency_page(
            std::slice::from_ref(file),
            direction,
            relation,
            None,
            DRILLDOWN_RELATIONS_PER_DIRECTION,
            None,
        )?;
        truncated |= page.truncated;
        for row in page.rows {
            let neighbour = match direction {
                RepositoryGraphDirection::Inbound => Some(&row.detail.source),
                RepositoryGraphDirection::Outbound => row.detail.target.as_ref(),
            };
            let Some(neighbour) = neighbour else {
                continue;
            };
            let key = (relation.as_str(), neighbour.key().digest().to_string());
            if seen.insert(key) {
                entries.push(relation_entry(direction_label, relation, neighbour));
            }
        }
    }

    if entries.len() > DRILLDOWN_RELATIONS_PER_DIRECTION as usize {
        entries.truncate(DRILLDOWN_RELATIONS_PER_DIRECTION as usize);
        truncated = true;
    }
    Ok((entries, truncated))
}

/// Project one hydrated graph neighbour onto the frontend contract.
fn relation_entry(
    direction: &str,
    relation: GraphRelationKind,
    neighbour: &GraphEntity,
) -> FileRelationEntry {
    FileRelationEntry {
        direction: direction.to_string(),
        relation: relation.as_str().to_string(),
        label: label(neighbour.selector()),
        path: selector_path(neighbour.selector()),
        entity_kind: entity_kind(neighbour.selector()).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_labels_keep_the_identifying_tail() {
        let shortened = shorten("a/very/long/path/whose/tail/is/important.rs");
        assert!(shortened.starts_with('…'));
        assert!(shortened.ends_with("important.rs"));
        assert_eq!(shortened.chars().count(), MAX_LABEL);
    }

    #[test]
    fn relation_view_serializes_stable_frontend_field_names() -> Result<(), serde_json::Error> {
        let value = serde_json::to_value(FileRelationsView {
            path: "docs/guide.md".to_string(),
            incoming: vec![FileRelationEntry {
                direction: "incoming".to_string(),
                relation: "extended:documents".to_string(),
                label: "lib.rs".to_string(),
                path: Some("src/lib.rs".to_string()),
                entity_kind: "file".to_string(),
            }],
            outgoing: Vec::new(),
            truncated: false,
        })?;
        if value["incoming"][0]["entityKind"] != "file"
            || value["incoming"][0]["relation"] != "extended:documents"
        {
            return Err(serde_json::Error::io(std::io::Error::other(
                "serialized relation contract changed",
            )));
        }
        Ok(())
    }
}
