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
use projectatlas_core::graph::{EntitySelector, GraphRelationKind};
use projectatlas_core::symbols::RelationKind;
use projectatlas_db::{AtlasStore, RepositoryGraphRelationQuery};
use serde::Serialize;
use std::collections::HashSet;
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
}

/// One resolved relation between two preview nodes.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AtlasEdge {
    /// Compact identity of the source node.
    pub(crate) source: String,
    /// Compact identity of the target node.
    pub(crate) target: String,
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
}

impl AtlasView {
    /// Build the state used when the optional graph read fails or is absent.
    fn unavailable() -> Self {
        Self {
            available: false,
            truncated: false,
            nodes: Vec::new(),
            edges: Vec::new(),
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
    if hubs.is_empty() {
        return Ok(AtlasView {
            available: true,
            truncated,
            nodes: Vec::new(),
            edges: Vec::new(),
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
                });
            }
            if edges.len() >= MAX_EDGES {
                truncated = true;
                break;
            }
            if edge_keys.insert(format!("{hub_id}>{target_id}")) {
                edges.push(AtlasEdge {
                    source: hub_id.clone(),
                    target: target_id,
                });
            }
        }
    }

    Ok(AtlasView {
        available: true,
        truncated,
        nodes,
        edges,
    })
}
