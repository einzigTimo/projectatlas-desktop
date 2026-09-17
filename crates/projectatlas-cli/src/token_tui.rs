//! Purpose: Render token telemetry as package-backed terminal dashboards.

use projectatlas_core::graph::{GraphRelationKind, LogicalRelation};
use projectatlas_core::symbols::RelationKind;
use projectatlas_core::telemetry::{
    TokenBucketOverview, TokenOverview, TokenTrendPeriod, TokenTrendReport,
};
use ratatui::backend::TestBackend;
use ratatui::buffer::{Buffer, CellWidth};
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::symbols;
use ratatui::text::{Line, Span};
use ratatui::widgets::canvas::{Canvas, Circle, Line as CanvasLine, Points};
use ratatui::widgets::{Axis, Block, Cell, Chart, Dataset, GraphType, Paragraph, Row, Table, Wrap};
use ratatui::{Frame, Terminal};
use std::cell::Cell as StdCell;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{self, IsTerminal};
use std::num::NonZeroU16;
use std::time::{SystemTime, UNIX_EPOCH};

/// Human explanation of the only accepted measurement basis.
const MEASUREMENT_BASIS_TEXT: &str =
    "Exact UTF-8 bytes; savings only where the same call loaded the complete file";
/// Fixed terminal height for the token overview dashboard snapshot.
const DASHBOARD_HEIGHT: u16 = 50;
/// Minimum terminal width for the full token dashboards.
const DASHBOARD_MIN_WIDTH: u16 = 80;
/// Width at which the human dashboard can show the atlas without crowding impact data.
const ATLAS_DASHBOARD_MIN_WIDTH: u16 = 190;
/// Maximum human dashboard width.
const DASHBOARD_MAX_WIDTH: u16 = 200;
/// Default non-terminal dashboard width.
const DASHBOARD_DEFAULT_WIDTH: u16 = 140;
/// Stable width reserved for the token-impact column in the wide dashboard.
const TOKEN_IMPACT_COLUMN_WIDTH: u16 = 140;
/// Maximum real resolved nodes retained by the decorative atlas preview.
const ATLAS_PREVIEW_MAX_NODES: usize = 48;
/// Maximum real resolved links retained by the decorative atlas preview.
const ATLAS_PREVIEW_MAX_EDGES: usize = 64;
/// Maximum links one visual hub may consume in the decorative preview.
const ATLAS_PREVIEW_MAX_NODE_DEGREE: usize = 12;
/// Horizontal Canvas bound retaining a margin inside the atlas panel.
const ATLAS_CANVAS_X_BOUND: f64 = 33.0;
/// Vertical Canvas bound retaining a margin above the atlas footer.
const ATLAS_CANVAS_Y_BOUND: f64 = 21.0;
/// Fixed force steps keep the bounded static preview deterministic and fast.
const ATLAS_LAYOUT_ITERATIONS: usize = 120;
/// Ideal graph-space edge length for the bounded force layout.
const ATLAS_LAYOUT_IDEAL_DISTANCE: f64 = 18.0;
/// Maximum per-step node movement before deterministic cooling.
const ATLAS_LAYOUT_INITIAL_TEMPERATURE: f64 = 8.0;
/// Degree at which a node receives a small depth halo instead of a single point.
const ATLAS_NODE_HALO_DEGREE: usize = 4;
/// Fixed terminal height for the token trend dashboard snapshot.
const TREND_DASHBOARD_HEIGHT: u16 = 30;
/// Maximum human trend dashboard width.
const TREND_DASHBOARD_MAX_WIDTH: u16 = 140;
/// Reserved terminal-canvas color; overview frames leave the shell background visible.
const THEME_BG: Color = Color::Rgb(4, 10, 18);
/// Token dashboard panel background.
const THEME_PANEL: Color = Color::Rgb(5, 16, 25);
/// Token dashboard primary warm text.
const THEME_TEXT: Color = Color::Rgb(224, 198, 164);
/// Token dashboard muted label text.
const THEME_MUTED: Color = Color::Rgb(170, 143, 116);
/// Token dashboard identity ivory.
const THEME_INK_WHITE: Color = Color::Rgb(238, 234, 224);
/// Counterfactual/original-baseline blue.
const THEME_BLUE: Color = Color::Rgb(93, 143, 255);
/// Net saved/success green.
const THEME_GREEN: Color = Color::Rgb(111, 216, 100);
/// Modeled/search/estimate yellow.
const THEME_YELLOW: Color = Color::Rgb(230, 179, 55);
/// Token dashboard subtle warm panel border.
const THEME_BORDER: Color = Color::Rgb(92, 74, 55);
/// Token dashboard inactive bar cells.
const THEME_BAR_EMPTY: Color = Color::Rgb(49, 56, 57);
/// Token dashboard loss red.
const THEME_RED: Color = Color::Rgb(235, 95, 95);
/// Repository-graph test and route accent.
const THEME_PURPLE: Color = Color::Rgb(173, 127, 255);
/// Human token dashboard color mode.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TokenDashboardTheme {
    /// Reference dark dashboard theme.
    Dark,
    /// Light dashboard theme for light terminal backgrounds.
    Light,
    /// Preserve the terminal background and foreground while retaining semantic accents.
    Terminal,
}

/// One validated terminal viewport shared by loading, layout, and serialization.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TokenDashboardViewport {
    /// Available terminal columns.
    columns: NonZeroU16,
    /// Available terminal rows.
    rows: NonZeroU16,
}

impl TokenDashboardViewport {
    /// Return the selected terminal columns.
    const fn columns(self) -> u16 {
        self.columns.get()
    }

    /// Return the selected terminal rows.
    const fn rows(self) -> u16 {
        self.rows.get()
    }

    /// Return whether the full overview fits this viewport.
    const fn fits_overview(self) -> bool {
        self.columns() >= DASHBOARD_MIN_WIDTH && self.rows() >= DASHBOARD_HEIGHT
    }

    /// Return whether the full trend view fits this viewport.
    const fn fits_trend(self) -> bool {
        self.columns() >= DASHBOARD_MIN_WIDTH && self.rows() >= TREND_DASHBOARD_HEIGHT
    }

    /// Return the bounded overview render width.
    fn overview_width(self) -> u16 {
        self.columns().min(DASHBOARD_MAX_WIDTH)
    }

    /// Return the bounded trend render width.
    fn trend_width(self) -> u16 {
        self.columns().min(TREND_DASHBOARD_MAX_WIDTH)
    }
}

impl TokenDashboardTheme {
    /// Parse a token dashboard theme value.
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "dark" => Some(Self::Dark),
            "light" => Some(Self::Light),
            "terminal" => Some(Self::Terminal),
            _ => None,
        }
    }
}

/// Semantic color palette used when serializing Ratatui cells to ANSI.
#[derive(Clone, Copy)]
struct ThemePalette {
    /// Full-screen background.
    bg: Color,
    /// Panel background.
    panel: Color,
    /// Primary text.
    text: Color,
    /// Muted text.
    muted: Color,
    /// Product identity color.
    ink_white: Color,
    /// Counterfactual baseline blue.
    blue: Color,
    /// Saved/success green.
    green: Color,
    /// Modeled/estimate yellow.
    yellow: Color,
    /// Panel border.
    border: Color,
    /// Empty bar fill.
    bar_empty: Color,
    /// Negative/loss red.
    red: Color,
    /// Repository graph accent.
    purple: Color,
}

/// One real resolved relation retained by the bounded atlas preview.
#[derive(Clone, Debug, Eq, PartialEq)]
struct AtlasPreviewEdge {
    /// Stable compact source identity.
    source: String,
    /// Stable compact target identity.
    target: String,
    /// Typed relation family used for semantic color.
    kind: GraphRelationKind,
}

/// Bounded, non-interactive projection of resolved relations from the active project database.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TokenAtlasPreview {
    /// Real resolved relations admitted within the node and edge ceilings.
    edges: Vec<AtlasPreviewEdge>,
    /// Whether a source page or a preview ceiling omitted additional relations.
    truncated: bool,
    /// Whether the optional graph read completed successfully.
    available: bool,
}

/// Return whether a relation belongs in the cross-entity atlas network.
pub(crate) const fn token_atlas_network_relation(kind: GraphRelationKind) -> bool {
    !matches!(kind, GraphRelationKind::Legacy(RelationKind::Contains))
}

impl TokenAtlasPreview {
    /// Build an empty but available graph snapshot.
    #[must_use]
    pub(crate) const fn empty() -> Self {
        Self {
            edges: Vec::new(),
            truncated: false,
            available: true,
        }
    }

    /// Build the explicit state used when the optional graph read fails.
    #[must_use]
    pub(crate) const fn unavailable() -> Self {
        Self {
            edges: Vec::new(),
            truncated: false,
            available: false,
        }
    }

    /// Retain only exact local resolutions from bounded database relation pages.
    #[must_use]
    pub(crate) fn from_relations(relations: &[LogicalRelation], source_truncated: bool) -> Self {
        Self::from_resolved_edges(
            relations.iter().filter_map(|relation| {
                relation.resolution().resolved_target().map(|target| {
                    (
                        relation.source().digest().to_string(),
                        target.digest().to_string(),
                        relation.kind(),
                    )
                })
            }),
            source_truncated,
        )
    }

    /// Build the bounded projection from already resolved stable identities.
    fn from_resolved_edges(
        relations: impl IntoIterator<Item = (String, String, GraphRelationKind)>,
        source_truncated: bool,
    ) -> Self {
        let mut candidates = BTreeMap::new();
        for (source, target, kind) in relations {
            if source == target || !token_atlas_network_relation(kind) {
                continue;
            }
            candidates
                .entry((source.clone(), target.clone(), kind.as_str()))
                .or_insert(AtlasPreviewEdge {
                    source,
                    target,
                    kind,
                });
        }
        let mut degrees = BTreeMap::<String, usize>::new();
        let mut adjacency = BTreeMap::<String, BTreeSet<String>>::new();
        for edge in candidates.values() {
            *degrees.entry(edge.source.clone()).or_default() += 1;
            *degrees.entry(edge.target.clone()).or_default() += 1;
            adjacency
                .entry(edge.source.clone())
                .or_default()
                .insert(edge.target.clone());
            adjacency
                .entry(edge.target.clone())
                .or_default()
                .insert(edge.source.clone());
        }
        let mut candidates = candidates.into_values().collect::<Vec<_>>();
        candidates.sort_by(|left, right| {
            let score = |edge: &AtlasPreviewEdge| {
                degrees.get(&edge.source).copied().unwrap_or_default()
                    + degrees.get(&edge.target).copied().unwrap_or_default()
            };
            score(right)
                .cmp(&score(left))
                .then_with(|| left.source.cmp(&right.source))
                .then_with(|| left.target.cmp(&right.target))
                .then_with(|| left.kind.as_str().cmp(right.kind.as_str()))
        });

        let mut remaining = adjacency.keys().cloned().collect::<BTreeSet<_>>();
        let mut largest_component = BTreeSet::new();
        while let Some(start) = remaining.first().cloned() {
            remaining.remove(&start);
            let mut component = BTreeSet::from([start.clone()]);
            let mut frontier = VecDeque::from([start]);
            while let Some(node) = frontier.pop_front() {
                if let Some(neighbors) = adjacency.get(&node) {
                    for neighbor in neighbors {
                        if remaining.remove(neighbor) {
                            component.insert(neighbor.clone());
                            frontier.push_back(neighbor.clone());
                        }
                    }
                }
            }
            let replace = component.len() > largest_component.len()
                || (component.len() == largest_component.len()
                    && component.first() < largest_component.first());
            if replace {
                largest_component = component;
            }
        }
        let Some(hub) = largest_component
            .iter()
            .max_by(|left, right| {
                degrees
                    .get(*left)
                    .cmp(&degrees.get(*right))
                    .then_with(|| right.cmp(left))
            })
            .cloned()
        else {
            return Self {
                edges: Vec::new(),
                truncated: source_truncated,
                available: true,
            };
        };
        let omitted_disconnected = candidates.iter().any(|edge| {
            !largest_component.contains(&edge.source) || !largest_component.contains(&edge.target)
        });
        candidates.retain(|edge| {
            largest_component.contains(&edge.source) && largest_component.contains(&edge.target)
        });
        let mut branch_reach = BTreeMap::<String, BTreeMap<String, usize>>::new();
        for edge in &candidates {
            for (blocked, start) in [(&edge.source, &edge.target), (&edge.target, &edge.source)] {
                let reach = atlas_branch_reach(&adjacency, blocked, start);
                branch_reach
                    .entry(blocked.clone())
                    .or_default()
                    .insert(start.clone(), reach);
            }
        }
        let mut nodes = BTreeSet::from([hub]);
        let mut edges = Vec::new();
        let mut selected_degrees = BTreeMap::<String, usize>::new();
        while edges.len() < ATLAS_PREVIEW_MAX_EDGES {
            let can_admit = |edge: &AtlasPreviewEdge| {
                selected_degrees
                    .get(&edge.source)
                    .copied()
                    .unwrap_or_default()
                    < ATLAS_PREVIEW_MAX_NODE_DEGREE
                    && selected_degrees
                        .get(&edge.target)
                        .copied()
                        .unwrap_or_default()
                        < ATLAS_PREVIEW_MAX_NODE_DEGREE
            };
            let next_index = candidates
                .iter()
                .enumerate()
                .filter_map(|(index, edge)| {
                    let source_selected = nodes.contains(&edge.source);
                    let target_selected = nodes.contains(&edge.target);
                    if source_selected == target_selected
                        || nodes.len() >= ATLAS_PREVIEW_MAX_NODES
                        || !can_admit(edge)
                    {
                        return None;
                    }
                    let (selected, unselected) = if source_selected {
                        (&edge.source, &edge.target)
                    } else {
                        (&edge.target, &edge.source)
                    };
                    let reach = branch_reach
                        .get(selected)
                        .and_then(|by_neighbor| by_neighbor.get(unselected))
                        .copied()
                        .unwrap_or_default();
                    let expansion_degree = degrees.get(unselected).copied().unwrap_or_default();
                    Some((index, reach, expansion_degree))
                })
                .max_by(|left, right| {
                    left.1
                        .cmp(&right.1)
                        .then_with(|| left.2.cmp(&right.2))
                        .then_with(|| right.0.cmp(&left.0))
                })
                .map(|(index, _, _)| index)
                .or_else(|| {
                    candidates.iter().position(|edge| {
                        nodes.contains(&edge.source)
                            && nodes.contains(&edge.target)
                            && can_admit(edge)
                    })
                });
            let Some(next_index) = next_index else {
                break;
            };
            let edge = candidates.remove(next_index);
            nodes.insert(edge.source.clone());
            nodes.insert(edge.target.clone());
            *selected_degrees.entry(edge.source.clone()).or_default() += 1;
            *selected_degrees.entry(edge.target.clone()).or_default() += 1;
            edges.push(edge);
        }
        Self {
            edges,
            truncated: source_truncated || omitted_disconnected || !candidates.is_empty(),
            available: true,
        }
    }

    /// Return the exact number of distinct nodes drawn by this preview.
    fn node_count(&self) -> usize {
        self.edges
            .iter()
            .flat_map(|edge| [&edge.source, &edge.target])
            .collect::<BTreeSet<_>>()
            .len()
    }
}

/// Count one candidate branch without crossing back through its selected endpoint.
fn atlas_branch_reach(
    adjacency: &BTreeMap<String, BTreeSet<String>>,
    blocked: &str,
    start: &str,
) -> usize {
    let mut visited = BTreeSet::from([start.to_string()]);
    let mut frontier = VecDeque::from([start.to_string()]);
    while let Some(node) = frontier.pop_front() {
        if let Some(neighbors) = adjacency.get(&node) {
            for neighbor in neighbors {
                if neighbor != blocked && visited.insert(neighbor.clone()) {
                    frontier.push_back(neighbor.clone());
                }
            }
        }
    }
    visited.len()
}

/// Light terminal palette preserving the same semantic color roles.
const LIGHT_THEME: ThemePalette = ThemePalette {
    bg: Color::Rgb(252, 249, 241),
    panel: Color::Rgb(246, 242, 232),
    text: Color::Rgb(34, 32, 28),
    muted: Color::Rgb(96, 88, 76),
    ink_white: Color::Rgb(22, 22, 20),
    blue: Color::Rgb(37, 99, 235),
    green: Color::Rgb(22, 128, 72),
    yellow: Color::Rgb(178, 116, 0),
    border: Color::Rgb(175, 151, 111),
    bar_empty: Color::Rgb(218, 210, 196),
    red: Color::Rgb(190, 52, 52),
    purple: Color::Rgb(126, 70, 180),
};

thread_local! {
    /// Active token dashboard theme for the current render pass.
    static ACTIVE_TOKEN_THEME: StdCell<TokenDashboardTheme> = const { StdCell::new(TokenDashboardTheme::Dark) };
}

/// Render the token overview as a human terminal dashboard.
#[cfg(test)]
pub(crate) fn render_token_dashboard(overview: &TokenOverview, session: Option<&str>) -> String {
    render_token_dashboard_with_theme(overview, session, TokenDashboardTheme::Dark)
}

/// Render the token overview as a human terminal dashboard with the selected theme.
#[cfg(test)]
pub(crate) fn render_token_dashboard_with_theme(
    overview: &TokenOverview,
    session: Option<&str>,
    theme: TokenDashboardTheme,
) -> String {
    let rendered = with_token_theme(theme, || {
        render_dashboard_to_ansi_string(DASHBOARD_DEFAULT_WIDTH, DASHBOARD_HEIGHT, |frame| {
            render_overview_frame(frame, overview, session);
        })
    });
    match rendered {
        Ok(dashboard) => dashboard,
        Err(error) => unreachable!("in-memory token dashboard render failed: {error}"),
    }
}

/// Render the human token dashboard with its optional bounded live atlas.
pub(crate) fn render_token_dashboard_with_atlas(
    overview: &TokenOverview,
    session: Option<&str>,
    atlas: &TokenAtlasPreview,
    theme: TokenDashboardTheme,
    viewport: TokenDashboardViewport,
) -> io::Result<String> {
    with_token_theme(theme, || {
        if viewport.fits_overview() {
            render_dashboard_to_ansi_string(viewport.overview_width(), DASHBOARD_HEIGHT, |frame| {
                render_overview_frame_with_atlas(frame, overview, session, Some(atlas));
            })
        } else {
            render_compact_overview(overview, session, viewport)
        }
    })
}

/// Render one deterministic test dashboard with an explicit atlas width.
#[cfg(test)]
pub(crate) fn render_token_dashboard_with_atlas_at_width(
    overview: &TokenOverview,
    session: Option<&str>,
    atlas: &TokenAtlasPreview,
    width: u16,
) -> String {
    with_token_theme(TokenDashboardTheme::Dark, || {
        render_dashboard_to_string(width, DASHBOARD_HEIGHT, |frame| {
            render_overview_frame_with_atlas(frame, overview, session, Some(atlas));
        })
    })
}

/// Capture one validated viewport for token loading, rendering, and serialization.
#[must_use]
pub(crate) fn capture_token_dashboard_viewport() -> TokenDashboardViewport {
    let terminal_size = if io::stdout().is_terminal() {
        ratatui::crossterm::terminal::size().ok()
    } else {
        None
    };
    resolve_dashboard_viewport(
        terminal_size,
        dashboard_environment_dimension("COLUMNS"),
        dashboard_environment_dimension("LINES"),
    )
}

/// Return whether a captured viewport can show the optional atlas.
#[must_use]
pub(crate) fn token_dashboard_wants_atlas(viewport: TokenDashboardViewport) -> bool {
    viewport.fits_overview() && viewport.overview_width() >= ATLAS_DASHBOARD_MIN_WIDTH
}

/// Render the token overview as a plain terminal chart for agent payloads.
pub(crate) fn render_token_dashboard_plain_with_theme(
    overview: &TokenOverview,
    session: Option<&str>,
    theme: TokenDashboardTheme,
) -> String {
    let width = dashboard_width().clamp(
        usize::from(DASHBOARD_MIN_WIDTH),
        usize::from(TREND_DASHBOARD_MAX_WIDTH),
    ) as u16;
    with_token_theme(theme, || {
        render_dashboard_to_string(width, DASHBOARD_HEIGHT, |frame| {
            render_overview_frame(frame, overview, session);
        })
    })
}

/// Render token trends as a human terminal dashboard.
#[cfg(test)]
pub(crate) fn render_token_trend_dashboard(report: &TokenTrendReport) -> String {
    let rendered = render_token_trend_dashboard_with_theme_in_viewport(
        report,
        TokenDashboardTheme::Dark,
        resolve_dashboard_viewport(None, None, None),
    );
    match rendered {
        Ok(dashboard) => dashboard,
        Err(error) => unreachable!("in-memory token trend dashboard render failed: {error}"),
    }
}

/// Render token trends as a human terminal dashboard with the selected theme.
pub(crate) fn render_token_trend_dashboard_with_theme(
    report: &TokenTrendReport,
    theme: TokenDashboardTheme,
) -> io::Result<String> {
    render_token_trend_dashboard_with_theme_in_viewport(
        report,
        theme,
        capture_token_dashboard_viewport(),
    )
}

/// Render token trends inside one previously captured viewport.
pub(crate) fn render_token_trend_dashboard_with_theme_in_viewport(
    report: &TokenTrendReport,
    theme: TokenDashboardTheme,
    viewport: TokenDashboardViewport,
) -> io::Result<String> {
    with_token_theme(theme, || {
        if viewport.fits_trend() {
            render_dashboard_to_ansi_string(
                viewport.trend_width(),
                TREND_DASHBOARD_HEIGHT,
                |frame| {
                    render_trend_frame(frame, report);
                },
            )
        } else {
            render_compact_trend(report, viewport)
        }
    })
}

/// Render token trends as a plain terminal chart for agent payloads.
pub(crate) fn render_token_trend_dashboard_plain_with_theme(
    report: &TokenTrendReport,
    theme: TokenDashboardTheme,
) -> String {
    let width = dashboard_width().clamp(
        usize::from(DASHBOARD_MIN_WIDTH),
        usize::from(TREND_DASHBOARD_MAX_WIDTH),
    ) as u16;
    with_token_theme(theme, || {
        render_dashboard_to_string(width, TREND_DASHBOARD_HEIGHT, |frame| {
            render_trend_frame(frame, report);
        })
    })
}

/// Run one render closure with the selected token dashboard theme.
fn with_token_theme<R>(theme: TokenDashboardTheme, render: impl FnOnce() -> R) -> R {
    ACTIVE_TOKEN_THEME.with(|active| {
        let previous = active.replace(theme);
        let result = render();
        active.set(previous);
        result
    })
}

/// Return the active token dashboard theme.
fn active_token_theme() -> TokenDashboardTheme {
    ACTIVE_TOKEN_THEME.with(StdCell::get)
}

/// Render one Ratatui frame into a deterministic ANSI terminal buffer.
fn render_dashboard_to_ansi_string<F>(width: u16, height: u16, render: F) -> io::Result<String>
where
    F: FnOnce(&mut Frame<'_>),
{
    let backend = TestBackend::new(width, height);
    let mut terminal = Terminal::new(backend).map_err(|error| -> io::Error { match error {} })?;
    let frame = terminal
        .draw(render)
        .map_err(|error| -> io::Error { match error {} })?;
    Ok(buffer_to_ansi_string(frame.buffer))
}

/// Render the priority-ordered compact overview inside the available viewport.
fn render_compact_overview(
    overview: &TokenOverview,
    session: Option<&str>,
    viewport: TokenDashboardViewport,
) -> io::Result<String> {
    let lines = compact_overview_lines(overview, session);
    let height = viewport
        .rows()
        .min(u16::try_from(lines.len()).unwrap_or(u16::MAX));
    render_dashboard_to_ansi_string(viewport.overview_width(), height, move |frame| {
        frame.render_widget(Paragraph::new(lines), frame.area());
    })
}

/// Return compact measured overview facts in descending display priority.
fn compact_overview_lines<'a>(
    overview: &'a TokenOverview,
    session: Option<&'a str>,
) -> Vec<Line<'a>> {
    vec![
        Line::from(vec![
            Span::styled("ProjectAtlas", identity_title_style()),
            Span::styled(
                " Token Telemetry",
                Style::default().fg(THEME_BLUE).add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(vec![
            Span::styled("Measured saving: ", muted_bold_style()),
            Span::styled(
                signed_bytes(overview.saved_bytes),
                signed_savings_style(overview.saved_bytes),
            ),
        ]),
        Line::from(vec![
            Span::styled("File ", muted_style()),
            Span::styled(bytes(overview.compared_source_bytes), token_title_style()),
            Span::raw(" - Output "),
            Span::styled(bytes(overview.compared_output_bytes), identity_style()),
            Span::raw(" = Saved "),
            Span::styled(
                signed_bytes(overview.saved_bytes),
                signed_savings_style(overview.saved_bytes),
            ),
        ]),
        Line::from(vec![
            Span::styled("Atlas output: ", muted_bold_style()),
            Span::styled(bytes(overview.output_bytes), identity_style()),
            Span::raw(" in "),
            value(overview.measured_calls),
            Span::raw(" measured calls"),
        ]),
        Line::from(vec![
            Span::styled("Session: ", muted_bold_style()),
            Span::styled(session.unwrap_or("all sessions"), body_style()),
        ]),
        Line::from(vec![
            Span::styled("Calls: ", muted_bold_style()),
            value(overview.calls),
            Span::raw("   "),
            Span::styled("Excluded legacy: ", muted_bold_style()),
            value(overview.excluded_unmeasured_calls),
        ]),
        Line::from(vec![
            Span::styled("Basis: ", muted_bold_style()),
            Span::styled(MEASUREMENT_BASIS_TEXT, body_style()),
        ]),
        Line::from(Span::styled(
            format!("ProjectAtlas v{}", env!("CARGO_PKG_VERSION")),
            identity_style(),
        )),
    ]
}

/// Render the priority-ordered compact trend inside the available viewport.
fn render_compact_trend(
    report: &TokenTrendReport,
    viewport: TokenDashboardViewport,
) -> io::Result<String> {
    let lines = compact_trend_lines(report);
    let height = viewport
        .rows()
        .min(u16::try_from(lines.len()).unwrap_or(u16::MAX));
    render_dashboard_to_ansi_string(viewport.trend_width(), height, move |frame| {
        frame.render_widget(Paragraph::new(lines), frame.area());
    })
}

/// Return compact measured trend facts in descending display priority.
fn compact_trend_lines(report: &TokenTrendReport) -> Vec<Line<'_>> {
    let mut lines = vec![Line::from(Span::styled(
        "ProjectAtlas Token Trends",
        identity_title_style(),
    ))];
    if let Some(period) = report.periods.last() {
        lines.extend([
            Line::from(vec![
                Span::styled(format!("Latest {}: ", period.period), muted_bold_style()),
                Span::styled(
                    signed_bytes(period.saved_bytes),
                    signed_savings_style(period.saved_bytes),
                ),
                Span::raw(" saved"),
            ]),
            Line::from(vec![
                Span::styled("Window: ", muted_bold_style()),
                Span::styled(report.window.to_string(), body_style()),
                Span::raw("   "),
                Span::styled("Periods: ", muted_bold_style()),
                value(report.periods.len()),
            ]),
            Line::from(vec![
                Span::styled("File ", muted_style()),
                Span::styled(bytes(period.compared_source_bytes), token_title_style()),
                Span::raw(" - Output "),
                Span::styled(bytes(period.compared_output_bytes), identity_style()),
                Span::raw(" = Saved "),
                Span::styled(
                    signed_bytes(period.saved_bytes),
                    signed_savings_style(period.saved_bytes),
                ),
            ]),
            Line::from(vec![
                Span::styled("Measured calls: ", muted_bold_style()),
                value(period.measured_calls),
                Span::raw("   "),
                Span::styled("Rate: ", muted_bold_style()),
                Span::styled(rate_label(period.savings_rate), body_style()),
            ]),
        ]);
    } else {
        lines.push(Line::from(Span::styled(
            "Latest: no retained periods",
            muted_style(),
        )));
        lines.push(Line::from(vec![
            Span::styled("Window: ", muted_bold_style()),
            Span::styled(report.window.to_string(), body_style()),
            Span::raw("   "),
            Span::styled("Periods: ", muted_bold_style()),
            value(0),
        ]));
    }
    lines.push(Line::from(vec![
        Span::styled("Basis: ", muted_bold_style()),
        Span::styled(MEASUREMENT_BASIS_TEXT, body_style()),
    ]));
    lines.push(Line::from(Span::styled(
        format!("ProjectAtlas v{}", env!("CARGO_PKG_VERSION")),
        identity_style(),
    )));
    lines
}

/// Return a semantic compact savings style that preserves negative values.
fn signed_savings_style(saved: isize) -> Style {
    Style::default()
        .fg(if saved < 0 { THEME_RED } else { THEME_GREEN })
        .add_modifier(Modifier::BOLD)
}

/// Render one Ratatui frame into a deterministic plain string buffer.
fn render_dashboard_to_string<F>(width: u16, height: u16, render: F) -> String
where
    F: FnOnce(&mut Frame<'_>),
{
    let backend = TestBackend::new(width, height);
    let mut terminal =
        Terminal::new(backend).expect("in-memory token dashboard backend should initialize");
    let frame = terminal
        .draw(render)
        .expect("in-memory token dashboard should render");
    buffer_to_string(frame.buffer)
}

/// Draw the full overview dashboard frame.
fn render_overview_frame(frame: &mut Frame<'_>, overview: &TokenOverview, session: Option<&str>) {
    render_overview_frame_with_atlas(frame, overview, session, None);
}

/// Draw the overview and, when requested and wide enough, its static live atlas.
fn render_overview_frame_with_atlas(
    frame: &mut Frame<'_>,
    overview: &TokenOverview,
    session: Option<&str>,
    atlas: Option<&TokenAtlasPreview>,
) {
    let area = frame.area();
    let outer = Block::bordered()
        .border_set(symbols::border::ROUNDED)
        .border_style(Style::default().fg(THEME_TEXT))
        .style(Style::default().fg(THEME_TEXT));
    let inner = outer.inner(area);
    frame.render_widget(outer, area);
    render_window_title_bar(frame, area);

    if area.width < ATLAS_DASHBOARD_MIN_WIDTH || atlas.is_none() {
        render_overview_main(frame, inner, overview, session);
        return;
    }
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(TOKEN_IMPACT_COLUMN_WIDTH),
            Constraint::Min(48),
        ])
        .split(inner);
    render_overview_main(frame, columns[0], overview, session);
    if let Some(atlas) = atlas {
        render_atlas_map(frame, columns[1], atlas);
    }
}

/// Draw the measured-only one-screen overview.
fn render_overview_main(
    frame: &mut Frame<'_>,
    area: Rect,
    overview: &TokenOverview,
    session: Option<&str>,
) {
    let sections = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(7),
            Constraint::Length(10),
            Constraint::Length(6),
            Constraint::Min(8),
            Constraint::Length(5),
            Constraint::Length(1),
        ])
        .split(area);

    render_token_header(frame, sections[0], overview, session);
    render_token_hero(frame, sections[1], overview);
    render_output_card(frame, sections[2], overview);
    render_bucket_table(frame, sections[3], overview);
    render_measurement_notes(frame, sections[4], overview);
    render_status_bar(frame, sections[5]);
}

/// Return a screenshot-matched dashboard panel.
fn panel(title: &'static str) -> Block<'static> {
    let block = Block::bordered()
        .border_set(symbols::border::ROUNDED)
        .border_style(Style::default().fg(THEME_TEXT))
        .style(Style::default().fg(THEME_TEXT).bg(THEME_PANEL));
    if title.is_empty() {
        block
    } else {
        block.title(Span::styled(
            format!(" {} ", reference_title(title)),
            section_title_style().bg(THEME_PANEL),
        ))
    }
}

/// Draw the reference-style app title bar and window controls.
fn render_window_title_bar(frame: &mut Frame<'_>, area: Rect) {
    if area.width < 8 {
        return;
    }
    let top = Rect {
        x: area.x.saturating_add(1),
        y: area.y,
        width: area.width.saturating_sub(2),
        height: 1,
    };
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(10),
            Constraint::Min(12),
            Constraint::Length(10),
        ])
        .split(top);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ● ", Style::default().fg(THEME_RED)),
            Span::styled("● ", Style::default().fg(THEME_YELLOW)),
            Span::styled("●", Style::default().fg(THEME_GREEN)),
        ])),
        columns[0],
    );
    frame.render_widget(
        Paragraph::new("projectatlas -- measured-telemetry")
            .style(body_style())
            .alignment(Alignment::Center),
        columns[1],
    );
}

/// Draw the title band.
fn render_token_header(
    frame: &mut Frame<'_>,
    area: Rect,
    overview: &TokenOverview,
    session: Option<&str>,
) {
    frame.render_widget(
        Block::default().style(Style::default().bg(THEME_PANEL)),
        area,
    );
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Min(42),
            Constraint::Length(if area.width >= 110 { 46 } else { 34 }),
        ])
        .split(area);

    frame.render_widget(
        Paragraph::new(vec![
            Line::from(""),
            Line::from(vec![
                Span::styled("ProjectAtlas", identity_title_style()),
                Span::raw(" "),
                Span::styled("Token Telemetry", token_title_style()),
            ]),
            Line::from(Span::styled(
                "Measured values only. No estimates or counterfactual baselines.",
                body_style(),
            )),
        ])
        .style(Style::default().bg(THEME_PANEL))
        .wrap(Wrap { trim: true }),
        columns[0],
    );

    frame.render_widget(
        Paragraph::new(vec![
            Line::from(vec![
                Span::styled("Session: ", muted_bold_style()),
                Span::styled(session.unwrap_or("all"), body_style()),
            ]),
            Line::from(vec![
                Span::styled("Calls: ", muted_bold_style()),
                Span::styled(grouped_count(overview.calls), body_style()),
            ]),
            Line::from(vec![
                Span::styled("Measured: ", muted_bold_style()),
                Span::styled(grouped_count(overview.measured_calls), body_style()),
            ]),
            Line::from(vec![
                Span::styled("Excluded legacy: ", muted_bold_style()),
                Span::styled(
                    grouped_count(overview.excluded_unmeasured_calls),
                    body_style(),
                ),
            ]),
        ])
        .style(Style::default().bg(THEME_PANEL))
        .alignment(Alignment::Right)
        .wrap(Wrap { trim: true }),
        columns[1],
    );
}

/// Draw the measured full-file comparison hero panel.
fn render_token_hero(frame: &mut Frame<'_>, area: Rect, overview: &TokenOverview) {
    let block = panel("").border_style(Style::default().fg(THEME_TEXT));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Length(2),
            Constraint::Length(1),
            Constraint::Length(1),
            Constraint::Min(3),
        ])
        .split(inner);

    frame.render_widget(
        Paragraph::new(reference_title("MEASURED BYTES SAVED"))
            .style(section_title_style().bg(THEME_PANEL))
            .alignment(Alignment::Center),
        rows[0],
    );
    render_hero_value(frame, rows[1], overview.saved_bytes);
    frame.render_widget(
        Paragraph::new(format!(
            "{} calls that loaded a complete file • rate {}",
            grouped_count(overview.compared_calls),
            rate_label(overview.savings_rate)
        ))
        .style(body_style().bg(THEME_PANEL))
        .alignment(Alignment::Center),
        rows[2],
    );
    render_divider(frame, rows[3]);
    render_bytes_equation(
        frame,
        rows[4],
        overview.compared_source_bytes,
        overview.compared_output_bytes,
        overview.saved_bytes,
    );
}

/// Draw one file-minus-output measured byte equation and its three bars.
fn render_bytes_equation(
    frame: &mut Frame<'_>,
    area: Rect,
    source_bytes: usize,
    output_bytes: usize,
    saved_bytes: isize,
) {
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(30),
            Constraint::Length(3),
            Constraint::Percentage(30),
            Constraint::Length(3),
            Constraint::Percentage(30),
        ])
        .split(area);

    render_metric_column(
        frame,
        columns[0],
        bytes(source_bytes),
        "Loaded file bytes",
        THEME_BLUE,
        1.0,
    );
    frame.render_widget(center_symbol("-"), columns[1]);
    render_metric_column(
        frame,
        columns[2],
        bytes(output_bytes),
        "Emitted bytes",
        THEME_INK_WHITE,
        ratio(output_bytes, source_bytes),
    );
    frame.render_widget(center_symbol("="), columns[3]);
    render_metric_column(
        frame,
        columns[4],
        signed_bytes(saved_bytes),
        "Saved bytes",
        signed_color(saved_bytes),
        ratio(saved_bytes.unsigned_abs(), source_bytes),
    );
}

/// Draw the saved-byte headline as readable terminal text.
fn render_hero_value(frame: &mut Frame<'_>, area: Rect, value: isize) {
    let text = signed_bytes(value);
    let style = hero_value_style(value);
    let marker = hero_state_marker(value);
    let line = if area.width >= 48 {
        let mut spans = vec![Span::styled(text, style)];
        if let Some(marker) = marker {
            spans.push(Span::styled(format!("  {marker}"), style));
        }
        Line::from(spans)
    } else {
        Line::from(Span::styled(text, style))
    };
    frame.render_widget(
        Paragraph::new(line)
            .style(style)
            .alignment(Alignment::Center),
        area,
    );
}

/// Return the semantic marker used beside the saved-byte headline.
fn hero_state_marker(value: isize) -> Option<&'static str> {
    match value.cmp(&0) {
        std::cmp::Ordering::Greater => Some("✓"),
        std::cmp::Ordering::Less => Some("!"),
        std::cmp::Ordering::Equal => None,
    }
}

/// Draw one metric operand in the hero equation.
fn render_metric_column(
    frame: &mut Frame<'_>,
    area: Rect,
    number: String,
    label_text: &'static str,
    color: Color,
    ratio_value: f64,
) {
    let bar_width = area.width.saturating_sub(2).min(34) as usize;
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                number,
                Style::default()
                    .fg(color)
                    .bg(THEME_PANEL)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(
                label_text,
                Style::default().fg(color).bg(THEME_PANEL),
            )),
            block_bar(bar_width, ratio_value, color),
        ])
        .alignment(Alignment::Center),
        area,
    );
}

/// Return a centered operator paragraph.
fn center_symbol(symbol: &'static str) -> Paragraph<'static> {
    Paragraph::new(symbol).alignment(Alignment::Center).style(
        Style::default()
            .fg(THEME_TEXT)
            .bg(THEME_PANEL)
            .add_modifier(Modifier::BOLD),
    )
}

/// Draw the measured output-size card for every measured call.
fn render_output_card(frame: &mut Frame<'_>, area: Rect, overview: &TokenOverview) {
    let output_only_calls = overview
        .measured_calls
        .saturating_sub(overview.compared_calls);
    let average = overview
        .output_bytes
        .checked_div(overview.measured_calls)
        .unwrap_or(0);
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(vec![
                Span::styled("Emitted by all measured calls: ", body_style().bg(THEME_PANEL)),
                Span::styled(
                    bytes(overview.output_bytes),
                    Style::default()
                        .fg(THEME_INK_WHITE)
                        .bg(THEME_PANEL)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!("  •  mean {} per call", bytes(average)),
                    muted_style().bg(THEME_PANEL),
                ),
            ]),
            Line::from(vec![
                Span::styled("Calls with file comparison: ", body_style().bg(THEME_PANEL)),
                Span::styled(
                    grouped_count(overview.compared_calls),
                    identity_style().bg(THEME_PANEL),
                ),
                Span::styled("   Output-only calls: ", body_style().bg(THEME_PANEL)),
                Span::styled(
                    grouped_count(output_only_calls),
                    identity_style().bg(THEME_PANEL),
                ),
            ]),
            Line::from(Span::styled(
                "Output-only calls (search, navigation, health) have no measured counterpart and claim no saving.",
                muted_style().bg(THEME_PANEL),
            )),
        ])
        .block(panel("ATLAS OUTPUT"))
        .style(body_style().bg(THEME_PANEL))
        .wrap(Wrap { trim: true }),
        area,
    );
}

/// Draw measured bucket rows.
fn render_bucket_table(frame: &mut Frame<'_>, area: Rect, overview: &TokenOverview) {
    let constraints = [
        Constraint::Percentage(26),
        Constraint::Percentage(10),
        Constraint::Percentage(18),
        Constraint::Percentage(18),
        Constraint::Percentage(16),
        Constraint::Percentage(12),
    ];
    let mut rows = overview
        .buckets
        .iter()
        .map(|bucket| {
            Row::new(vec![
                Cell::from(bucket_label(bucket)),
                Cell::from(grouped_count(bucket.calls)),
                Cell::from(if bucket.is_full_file_comparison() {
                    bytes(bucket.source_bytes)
                } else {
                    "n/a".to_string()
                }),
                Cell::from(bytes(bucket.output_bytes)),
                Cell::from(
                    bucket
                        .saved_bytes
                        .map_or_else(|| "n/a".to_string(), signed_bytes),
                ),
                Cell::from(rate_label(bucket.savings_rate)),
            ])
            .style(Style::default().fg(THEME_INK_WHITE).bg(THEME_PANEL))
        })
        .collect::<Vec<_>>();
    if rows.is_empty() {
        rows.push(
            Row::new(vec![
                Cell::from("No measured calls"),
                Cell::from("0"),
                Cell::from("n/a"),
                Cell::from("0 B"),
                Cell::from("n/a"),
                Cell::from("n/a"),
            ])
            .style(Style::default().fg(THEME_MUTED).bg(THEME_PANEL)),
        );
    }
    let table = Table::new(rows, constraints)
        .header(
            Row::new(vec![
                "Measurement",
                "Calls",
                "File bytes",
                "Output bytes",
                "Saved",
                "Rate",
            ])
            .style(header_style().bg(THEME_PANEL))
            .bottom_margin(1),
        )
        .column_spacing(1)
        .block(panel("MEASURED CALLS"));
    frame.render_widget(table, area);
}

/// Return the human label for one measured bucket.
fn bucket_label(bucket: &TokenBucketOverview) -> &'static str {
    if bucket.is_full_file_comparison() {
        "File compared"
    } else {
        "Output only"
    }
}

/// Draw the bounded live repository constellation in the wide dashboard column.
fn render_atlas_map(frame: &mut Frame<'_>, area: Rect, atlas: &TokenAtlasPreview) {
    let block = panel("ATLAS MAP");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(8), Constraint::Length(2)])
        .split(inner);

    if !atlas.available {
        render_atlas_message(
            frame,
            rows[0],
            "Graph preview unavailable",
            "Token-impact data remains available",
        );
        return;
    }
    if atlas.edges.is_empty() {
        render_atlas_message(
            frame,
            rows[0],
            "No resolved graph links",
            "Run projectatlas scan to refresh",
        );
        return;
    }

    let layout = atlas_layout(&atlas.edges);
    let mut node_order = layout.nodes.iter().collect::<Vec<_>>();
    node_order.sort_by(|left, right| {
        right
            .1
            .distance
            .cmp(&left.1.distance)
            .then_with(|| left.0.cmp(right.0))
    });
    let canvas = Canvas::default()
        .background_color(THEME_PANEL)
        .marker(symbols::Marker::Braille)
        .x_bounds([-ATLAS_CANVAS_X_BOUND, ATLAS_CANVAS_X_BOUND])
        .y_bounds([-ATLAS_CANVAS_Y_BOUND, ATLAS_CANVAS_Y_BOUND])
        .paint(|context| {
            for edge in &atlas.edges {
                let (Some(source), Some(target)) = (
                    layout.nodes.get(&edge.source),
                    layout.nodes.get(&edge.target),
                ) else {
                    continue;
                };
                context.draw(&CanvasLine::new(
                    source.x,
                    source.y,
                    target.x,
                    target.y,
                    THEME_MUTED,
                ));
            }
            context.layer();
            for (node, placement) in &node_order {
                let color = if node.as_str() == layout.hub {
                    THEME_INK_WHITE
                } else {
                    atlas_cluster_color(placement.cluster)
                };
                if node.as_str() == layout.hub {
                    context.draw(&Circle::new(placement.x, placement.y, 0.9, THEME_YELLOW));
                    let center = [(placement.x, placement.y)];
                    context.draw(&Points::new(&center, THEME_INK_WHITE));
                } else {
                    if placement.degree >= ATLAS_NODE_HALO_DEGREE {
                        context.draw(&Circle::new(placement.x, placement.y, 0.5, color));
                    }
                    let point = [(placement.x, placement.y)];
                    context.draw(&Points::new(&point, color));
                }
            }
        });
    frame.render_widget(canvas, rows[0]);

    let state = if atlas.truncated {
        "bounded live graph • sampled snapshot"
    } else {
        "bounded live graph • static snapshot"
    };
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                format!(
                    "{} nodes • {} links",
                    grouped_count(atlas.node_count()),
                    grouped_count(atlas.edges.len())
                ),
                body_style().bg(THEME_PANEL),
            )),
            Line::from(Span::styled(state, muted_style().bg(THEME_PANEL))),
        ])
        .alignment(Alignment::Center),
        rows[1],
    );
}

/// Draw an explicit centered atlas state without substituting decorative data.
fn render_atlas_message(frame: &mut Frame<'_>, area: Rect, title: &str, detail: &str) {
    let height = 2_u16.min(area.height);
    let message_area = Rect {
        x: area.x,
        y: area
            .y
            .saturating_add(area.height.saturating_sub(height) / 2),
        width: area.width,
        height,
    };
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                title.to_string(),
                Style::default()
                    .fg(THEME_INK_WHITE)
                    .bg(THEME_PANEL)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(
                detail.to_string(),
                muted_style().bg(THEME_PANEL),
            )),
        ])
        .alignment(Alignment::Center),
        message_area,
    );
}

/// One force-settled node placement with graph-derived depth and cluster cues.
#[derive(Clone, Copy, Debug, PartialEq)]
struct AtlasNodePlacement {
    /// Horizontal Canvas coordinate.
    x: f64,
    /// Vertical Canvas coordinate.
    y: f64,
    /// Undirected degree within the bounded preview.
    degree: usize,
    /// Shortest graph distance from the central hub.
    distance: usize,
    /// Stable first-hop branch used for cluster coloring.
    cluster: usize,
}

/// Deterministic centered layout for the small resolved-relation projection.
struct AtlasLayout {
    /// Stable node positions inside the fixed Canvas safety margin.
    nodes: BTreeMap<String, AtlasNodePlacement>,
    /// Highest-connectivity node anchored at the geometric center.
    hub: String,
}

/// Settle one connected graph with the reusable force engine and center its strongest hub.
fn atlas_layout(edges: &[AtlasPreviewEdge]) -> AtlasLayout {
    let mut adjacency = BTreeMap::<String, BTreeSet<String>>::new();
    for edge in edges {
        adjacency
            .entry(edge.source.clone())
            .or_default()
            .insert(edge.target.clone());
        adjacency
            .entry(edge.target.clone())
            .or_default()
            .insert(edge.source.clone());
    }
    let hub = adjacency
        .iter()
        .max_by(|left, right| {
            left.1
                .len()
                .cmp(&right.1.len())
                .then_with(|| right.0.cmp(left.0))
        })
        .map(|(node, _)| node.clone())
        .unwrap_or_default();
    if hub.is_empty() {
        return AtlasLayout {
            nodes: BTreeMap::new(),
            hub,
        };
    }

    let mut branch_and_distance = BTreeMap::<String, (usize, usize)>::new();
    branch_and_distance.insert(hub.clone(), (0, 0));
    let hub_neighbors = adjacency.get(&hub).cloned().unwrap_or_default();
    let mut frontier = VecDeque::new();
    for (cluster, neighbor) in hub_neighbors.iter().enumerate() {
        branch_and_distance.insert(neighbor.clone(), (cluster, 1));
        frontier.push_back(neighbor.clone());
    }
    while let Some(node) = frontier.pop_front() {
        let Some((cluster, distance)) = branch_and_distance.get(&node).copied() else {
            continue;
        };
        if let Some(neighbors) = adjacency.get(&node) {
            for neighbor in neighbors {
                if !branch_and_distance.contains_key(neighbor) {
                    branch_and_distance.insert(neighbor.clone(), (cluster, distance + 1));
                    frontier.push_back(neighbor.clone());
                }
            }
        }
    }

    let branch_count = hub_neighbors.len().max(1);
    let mut branch_ordinals = BTreeMap::<usize, usize>::new();
    let node_names = adjacency.keys().cloned().collect::<Vec<_>>();
    let node_indexes = node_names
        .iter()
        .enumerate()
        .map(|(index, node)| (node.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let mut positions = Vec::with_capacity(node_names.len());
    for node in &node_names {
        let (cluster, distance) = branch_and_distance.get(node).copied().unwrap_or_default();
        let location = if *node == hub {
            (0.0, 0.0)
        } else {
            let ordinal = branch_ordinals.entry(cluster).or_default();
            let offset = (*ordinal % 5) as f64 - 2.0;
            let ring = (*ordinal / 5) as f64;
            *ordinal += 1;
            let angle =
                std::f64::consts::TAU * cluster as f64 / branch_count as f64 + offset * 0.22;
            let radius = 22.0 + distance as f64 * 16.0 + ring * 6.0;
            (radius * angle.cos(), radius * angle.sin())
        };
        positions.push(location);
    }
    let indexed_edges = edges
        .iter()
        .filter_map(|edge| {
            Some((
                *node_indexes.get(&edge.source)?,
                *node_indexes.get(&edge.target)?,
            ))
        })
        .collect::<Vec<_>>();
    settle_atlas_layout(&mut positions, &indexed_edges);

    let hub_location = node_indexes
        .get(&hub)
        .and_then(|index| positions.get(*index))
        .copied()
        .unwrap_or_default();
    let (max_x, max_y) = positions.iter().fold((0.0_f64, 0.0_f64), |(x, y), node| {
        (
            x.max((node.0 - hub_location.0).abs()),
            y.max((node.1 - hub_location.1).abs()),
        )
    });
    let x_scale = if max_x > f64::EPSILON {
        (ATLAS_CANVAS_X_BOUND - 3.0) / max_x
    } else {
        1.0
    };
    let y_scale = if max_y > f64::EPSILON {
        (ATLAS_CANVAS_Y_BOUND - 3.0) / max_y
    } else {
        1.0
    };
    let mut nodes = BTreeMap::new();
    for (node, location) in node_names.into_iter().zip(positions) {
        let (cluster, distance) = branch_and_distance.get(&node).copied().unwrap_or_default();
        nodes.insert(
            node.clone(),
            AtlasNodePlacement {
                x: (location.0 - hub_location.0) * x_scale,
                y: (location.1 - hub_location.1) * y_scale,
                degree: adjacency.get(&node).map_or(0, BTreeSet::len),
                distance,
                cluster,
            },
        );
    }
    AtlasLayout { nodes, hub }
}

/// Settle the tiny deterministic preview with bounded Fruchterman-Reingold steps.
fn settle_atlas_layout(positions: &mut [(f64, f64)], edges: &[(usize, usize)]) {
    let mut displacement = vec![(0.0, 0.0); positions.len()];
    for iteration in 0..ATLAS_LAYOUT_ITERATIONS {
        displacement.fill((0.0, 0.0));
        for left in 0..positions.len() {
            for right in left + 1..positions.len() {
                let delta = (
                    positions[left].0 - positions[right].0,
                    positions[left].1 - positions[right].1,
                );
                let distance = delta.0.hypot(delta.1).max(0.01);
                let force = ATLAS_LAYOUT_IDEAL_DISTANCE.powi(2) / distance;
                let unit = (delta.0 / distance, delta.1 / distance);
                displacement[left].0 += unit.0 * force;
                displacement[left].1 += unit.1 * force;
                displacement[right].0 -= unit.0 * force;
                displacement[right].1 -= unit.1 * force;
            }
        }
        for &(source, target) in edges {
            let delta = (
                positions[source].0 - positions[target].0,
                positions[source].1 - positions[target].1,
            );
            let distance = delta.0.hypot(delta.1).max(0.01);
            let force = distance.powi(2) / ATLAS_LAYOUT_IDEAL_DISTANCE;
            let unit = (delta.0 / distance, delta.1 / distance);
            displacement[source].0 -= unit.0 * force;
            displacement[source].1 -= unit.1 * force;
            displacement[target].0 += unit.0 * force;
            displacement[target].1 += unit.1 * force;
        }
        let temperature = (ATLAS_LAYOUT_INITIAL_TEMPERATURE
            * (1.0 - iteration as f64 / ATLAS_LAYOUT_ITERATIONS as f64))
            .max(0.1);
        for (position, delta) in positions.iter_mut().zip(&displacement) {
            let distance = delta.0.hypot(delta.1);
            if distance > f64::EPSILON {
                let step = distance.min(temperature) / distance;
                position.0 += delta.0 * step;
                position.1 += delta.1 * step;
            }
        }
    }
}

/// Map graph-derived first-hop branches to the stable dashboard accent palette.
const fn atlas_cluster_color(cluster: usize) -> Color {
    match cluster % 4 {
        0 => THEME_BLUE,
        1 => THEME_GREEN,
        2 => THEME_YELLOW,
        _ => THEME_PURPLE,
    }
}

/// Draw the measurement boundary without duplicating headline totals.
fn render_measurement_notes(frame: &mut Frame<'_>, area: Rect, overview: &TokenOverview) {
    let block = panel("MEASUREMENT");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let mut lines = vec![
        Line::from(Span::styled(
            format!("• {MEASUREMENT_BASIS_TEXT}"),
            body_style().bg(THEME_PANEL),
        )),
        Line::from(Span::styled(
            format!(
                "• Excluded legacy calls without measured sizes: {}",
                grouped_count(overview.excluded_unmeasured_calls)
            ),
            body_style().bg(THEME_PANEL),
        )),
    ];
    if let Some(value) = overview.calibration.as_ref() {
        lines.push(Line::from(Span::styled(
            format!(
                "• Tokenizer audit of indexed files: {} over {} files",
                value.tokenizer,
                grouped_count(value.files)
            ),
            body_style().bg(THEME_PANEL),
        )));
    }
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), inner);
}

/// Draw the compact footer/status row from the reference dashboard.
fn render_status_bar(frame: &mut Frame<'_>, area: Rect) {
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(42), Constraint::Percentage(58)])
        .split(area);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                "ProjectAtlas v",
                Style::default().fg(THEME_INK_WHITE).bg(THEME_PANEL),
            ),
            Span::styled(
                env!("CARGO_PKG_VERSION"),
                Style::default().fg(THEME_INK_WHITE).bg(THEME_PANEL),
            ),
        ]))
        .style(Style::default().bg(THEME_PANEL)),
        columns[0],
    );
    let clock = current_clock_label();
    let status = if area.width < 100 {
        format!(
            "Snapshot {} • rerun to refresh",
            clock.get(..5).unwrap_or(&clock)
        )
    } else {
        format!("Snapshot {clock} • rerun command to refresh")
    };
    frame.render_widget(
        Paragraph::new(Span::styled(status, body_style().bg(THEME_PANEL)))
            .style(Style::default().bg(THEME_PANEL))
            .alignment(Alignment::Right),
        columns[1],
    );
}

/// Render a horizontal divider in a panel.
fn render_divider(frame: &mut Frame<'_>, area: Rect) {
    frame.render_widget(
        Paragraph::new("─".repeat(area.width as usize))
            .style(Style::default().fg(THEME_BORDER).bg(THEME_PANEL)),
        area,
    );
}

/// Return a segmented bar matching the reference dashboard.
fn block_bar(width: usize, ratio_value: f64, color: Color) -> Line<'static> {
    let filled = ((width as f64) * ratio_value.clamp(0.0, 1.0)).round() as usize;
    let empty = width.saturating_sub(filled);
    Line::from(vec![
        Span::styled(
            "█".repeat(filled),
            Style::default().fg(color).bg(THEME_PANEL),
        ),
        Span::styled(
            "░".repeat(empty),
            Style::default().fg(THEME_BAR_EMPTY).bg(THEME_PANEL),
        ),
    ])
}

/// Return the color for a signed value.
fn signed_color(value: isize) -> Color {
    if value >= 0 { THEME_GREEN } else { THEME_RED }
}

/// Large positive/negative hero value style.
fn hero_value_style(value: isize) -> Style {
    Style::default()
        .fg(signed_color(value))
        .bg(THEME_PANEL)
        .add_modifier(Modifier::BOLD)
}

/// Header style used for panel titles.
fn header_style() -> Style {
    section_title_style()
}

/// Section title style used for dashboard chrome.
fn section_title_style() -> Style {
    Style::default().fg(THEME_TEXT).add_modifier(Modifier::BOLD)
}

/// Return the reference-like spaced title treatment used for dominant section labels.
fn reference_title(title: &str) -> String {
    let mut output = String::with_capacity(title.len().saturating_mul(2));
    let mut previous_was_space = false;
    for character in title.chars() {
        if character == ' ' {
            if !previous_was_space {
                output.push_str("   ");
            }
            previous_was_space = true;
        } else {
            if !output.is_empty() && !previous_was_space {
                output.push(' ');
            }
            output.push(character);
            previous_was_space = false;
        }
    }
    output
}

/// Identity label style.
fn identity_style() -> Style {
    Style::default()
        .fg(THEME_INK_WHITE)
        .add_modifier(Modifier::BOLD)
}

/// `ProjectAtlas` title identity style.
fn identity_title_style() -> Style {
    Style::default()
        .fg(THEME_INK_WHITE)
        .add_modifier(Modifier::BOLD)
}

/// Token Impact title style.
fn token_title_style() -> Style {
    Style::default().fg(THEME_BLUE).add_modifier(Modifier::BOLD)
}

/// Body text style.
fn body_style() -> Style {
    Style::default().fg(THEME_TEXT)
}

/// Muted text style.
fn muted_style() -> Style {
    Style::default().fg(THEME_MUTED)
}

/// Muted bold label style.
fn muted_bold_style() -> Style {
    muted_style().add_modifier(Modifier::BOLD)
}

/// Return a compact clock label for the footer status row.
fn current_clock_label() -> String {
    let seconds_since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs());
    let seconds_today = seconds_since_epoch % 86_400;
    let hours = seconds_today / 3_600;
    let minutes = (seconds_today % 3_600) / 60;
    let seconds = seconds_today % 60;
    format!("{hours:02}:{minutes:02}:{seconds:02}")
}

/// Convert trend periods into signed chart coordinates.
fn signed_trend_points(periods: Option<&[TokenTrendPeriod]>) -> Vec<(f64, f64)> {
    let mut points = periods
        .unwrap_or_default()
        .iter()
        .enumerate()
        .map(|(index, period)| (index as f64, period.saved_bytes as f64))
        .collect::<Vec<_>>();
    if points.is_empty() {
        vec![(0.0, 0.0)]
    } else if points.len() == 1 {
        points.push((1.0, points[0].1));
        points
    } else {
        points
    }
}

/// Return y-axis bounds that preserve the sign of trend values and include zero.
fn signed_y_bounds(points: &[(f64, f64)]) -> [f64; 2] {
    let min_value = points
        .iter()
        .map(|(_, value)| *value)
        .fold(0.0_f64, f64::min);
    let max_value = points
        .iter()
        .map(|(_, value)| *value)
        .fold(0.0_f64, f64::max);
    if (min_value - max_value).abs() < f64::EPSILON {
        [min_value - 1.0, max_value + 1.0]
    } else {
        [min_value, max_value]
    }
}

/// Return a trend color that signals all-loss or mixed-sign series.
fn signed_trend_color(points: &[(f64, f64)]) -> Color {
    let has_positive = points.iter().any(|(_, value)| *value > 0.0);
    let has_negative = points.iter().any(|(_, value)| *value < 0.0);
    match (has_positive, has_negative) {
        (true, true) => THEME_YELLOW,
        (false, true) => THEME_RED,
        _ => THEME_GREEN,
    }
}

/// Draw the full trend dashboard frame.
fn render_trend_frame(frame: &mut Frame<'_>, report: &TokenTrendReport) {
    let area = frame.area();
    let outer = Block::bordered()
        .border_set(symbols::border::ROUNDED)
        .title(Line::from(vec![
            Span::styled(" ProjectAtlas Token Trends ", identity_title_style()),
            Span::styled(format!("{} ", report.window), body_style()),
        ]))
        .border_style(Style::default().fg(THEME_TEXT))
        .style(Style::default().fg(THEME_TEXT));
    let inner = outer.inner(area);
    frame.render_widget(outer, area);

    let sections = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(8),
            Constraint::Min(12),
            Constraint::Length(4),
        ])
        .split(inner);

    let summary = vec![
        Line::from(vec![
            label("session"),
            Span::raw(report.session.as_deref().unwrap_or("all sessions")),
            Span::raw("   "),
            label("window"),
            Span::raw(report.window.to_string()),
            Span::raw("   "),
            label("periods"),
            value(report.periods.len()),
        ]),
        Line::from(vec![label("basis"), Span::raw(MEASUREMENT_BASIS_TEXT)]),
    ];
    frame.render_widget(Paragraph::new(summary), sections[0]);

    let trend_points = signed_trend_points(Some(&report.periods));
    let [lower, upper] = signed_y_bounds(&trend_points);
    frame.render_widget(
        Chart::new(vec![
            Dataset::default()
                .marker(symbols::Marker::Braille)
                .graph_type(GraphType::Line)
                .style(Style::default().fg(signed_trend_color(&trend_points)))
                .data(&trend_points),
        ])
        .block(panel("MEASURED BYTES SAVED TREND"))
        .x_axis(Axis::default().bounds([0.0, (trend_points.len().saturating_sub(1)) as f64]))
        .y_axis(Axis::default().bounds([lower, upper])),
        sections[1],
    );

    render_trend_table(frame, sections[2], report);
    frame.render_widget(
        Paragraph::new(
            "Only measured bytes. Legacy rows without measured sizes count as calls only.",
        )
        .style(body_style().bg(THEME_PANEL))
        .alignment(Alignment::Center)
        .block(panel("NOTE")),
        sections[3],
    );
}

/// Draw period rows for the trend dashboard.
fn render_trend_table(frame: &mut Frame<'_>, area: Rect, report: &TokenTrendReport) {
    let mut rows = report
        .periods
        .iter()
        .rev()
        .take(8)
        .map(|period| {
            Row::new(vec![
                Cell::from(period.period.clone()),
                Cell::from(signed_bytes(period.saved_bytes)),
                Cell::from(rate_label(period.savings_rate)),
                Cell::from(grouped_count(period.measured_calls)),
                Cell::from(bytes(period.compared_source_bytes)),
                Cell::from(bytes(period.output_bytes)),
            ])
        })
        .collect::<Vec<_>>();
    rows.reverse();
    if rows.is_empty() {
        rows.push(Row::new(vec![
            Cell::from("none"),
            Cell::from("0 B"),
            Cell::from("n/a"),
            Cell::from("0"),
            Cell::from("0 B"),
            Cell::from("0 B"),
        ]));
    }
    let table = Table::new(
        rows,
        [
            Constraint::Percentage(18),
            Constraint::Percentage(16),
            Constraint::Percentage(13),
            Constraint::Percentage(10),
            Constraint::Percentage(21),
            Constraint::Percentage(22),
        ],
    )
    .header(
        Row::new(vec![
            "period",
            "saved",
            "rate",
            "measured",
            "file bytes",
            "output",
        ])
        .style(Style::default().fg(THEME_TEXT).add_modifier(Modifier::BOLD)),
    )
    .block(panel("PERIODS"));
    frame.render_widget(table, area);
}

/// Convert a Ratatui buffer into trimmed terminal text.
fn buffer_to_string(buffer: &Buffer) -> String {
    let width = buffer.area.width;
    let height = buffer.area.height;
    let mut lines = Vec::with_capacity(height as usize);
    for y in 0..height {
        let mut line = String::new();
        for x in 0..width {
            if let Some(cell) = buffer.cell((x, y)) {
                line.push_str(cell.symbol());
            }
        }
        lines.push(line.trim_end().to_string());
    }
    while matches!(lines.last(), Some(line) if line.is_empty()) {
        lines.pop();
    }
    let mut output = lines.join("\n");
    output.push('\n');
    output
}

/// Convert a Ratatui buffer into ANSI-styled terminal text.
fn buffer_to_ansi_string(buffer: &Buffer) -> String {
    let width = buffer.area.width;
    let height = buffer.area.height;
    let mut output = String::new();
    let mut active_style: Option<CellAnsiStyle> = None;
    for y in 0..height {
        let mut x = 0;
        while x < width {
            let Some(cell) = buffer.cell((x, y)) else {
                x = x.saturating_add(1);
                continue;
            };
            let style = CellAnsiStyle::from_cell(cell);
            if active_style != Some(style) {
                output.push_str("\x1b[0m");
                output.push_str(&style.to_ansi());
                active_style = Some(style);
            }
            output.push_str(cell.symbol());
            x = x.saturating_add(cell.symbol().cell_width().max(1));
        }
        output.push_str("\x1b[0m");
        if y + 1 < height {
            output.push('\n');
        }
        active_style = None;
    }
    output
}

/// Minimal style projection used by the ANSI serializer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CellAnsiStyle {
    /// Cell foreground color.
    fg: Color,
    /// Cell background color.
    bg: Color,
    /// Cell modifiers.
    modifier: Modifier,
}

impl CellAnsiStyle {
    /// Build a style projection from one rendered Ratatui cell.
    fn from_cell(cell: &ratatui::buffer::Cell) -> Self {
        Self {
            fg: themed_color(cell.fg),
            bg: themed_color(cell.bg),
            modifier: cell.modifier,
        }
    }

    /// Convert the style to ANSI Select Graphic Rendition escapes.
    fn to_ansi(self) -> String {
        let mut codes = Vec::new();
        if self.modifier.contains(Modifier::BOLD) {
            codes.push("1".to_string());
        }
        if self.modifier.contains(Modifier::ITALIC) {
            codes.push("3".to_string());
        }
        if self.modifier.contains(Modifier::UNDERLINED) {
            codes.push("4".to_string());
        }
        if let Some(code) = color_to_ansi(self.fg, false) {
            codes.push(code);
        }
        if let Some(code) = color_to_ansi(self.bg, true) {
            codes.push(code);
        }
        if codes.is_empty() {
            String::new()
        } else {
            format!("\x1b[{}m", codes.join(";"))
        }
    }
}

/// Convert one Ratatui color into foreground/background ANSI code.
fn color_to_ansi(color: Color, background: bool) -> Option<String> {
    let offset = if background { 10 } else { 0 };
    let code = match color {
        Color::Reset => return None,
        Color::Black => 30 + offset,
        Color::Red => 31 + offset,
        Color::Green => 32 + offset,
        Color::Yellow => 33 + offset,
        Color::Blue => 34 + offset,
        Color::Magenta => 35 + offset,
        Color::Cyan => 36 + offset,
        Color::Gray | Color::White => 37 + offset,
        Color::DarkGray => 90 + offset,
        Color::LightRed => 91 + offset,
        Color::LightGreen => 92 + offset,
        Color::LightYellow => 93 + offset,
        Color::LightBlue => 94 + offset,
        Color::LightMagenta => 95 + offset,
        Color::LightCyan => 96 + offset,
        Color::Rgb(red, green, blue) => {
            let prefix = if background { 48 } else { 38 };
            return Some(format!("{prefix};2;{red};{green};{blue}"));
        }
        Color::Indexed(index) => {
            let prefix = if background { 48 } else { 38 };
            return Some(format!("{prefix};5;{index}"));
        }
    };
    Some(code.to_string())
}

/// Remap the dark reference palette to the selected output palette.
fn themed_color(color: Color) -> Color {
    match active_token_theme() {
        TokenDashboardTheme::Dark => color,
        TokenDashboardTheme::Light => remap_to_light_theme(color),
        TokenDashboardTheme::Terminal => match color {
            THEME_BG | THEME_PANEL | THEME_TEXT | THEME_MUTED | THEME_INK_WHITE => Color::Reset,
            _ => color,
        },
    }
}

/// Convert one dark semantic role color into its light-theme counterpart.
fn remap_to_light_theme(color: Color) -> Color {
    match color {
        THEME_BG => LIGHT_THEME.bg,
        THEME_PANEL => LIGHT_THEME.panel,
        THEME_TEXT => LIGHT_THEME.text,
        THEME_MUTED => LIGHT_THEME.muted,
        THEME_INK_WHITE => LIGHT_THEME.ink_white,
        THEME_BLUE => LIGHT_THEME.blue,
        THEME_GREEN => LIGHT_THEME.green,
        THEME_YELLOW => LIGHT_THEME.yellow,
        THEME_BORDER => LIGHT_THEME.border,
        THEME_BAR_EMPTY => LIGHT_THEME.bar_empty,
        THEME_RED => LIGHT_THEME.red,
        THEME_PURPLE => LIGHT_THEME.purple,
        _ => color,
    }
}

/// Styled field label span.
fn label(text: &str) -> Span<'static> {
    Span::styled(format!("{text}: "), muted_bold_style())
}

/// Styled unsigned value span.
fn value(value: usize) -> Span<'static> {
    Span::styled(grouped_count(value), identity_style())
}

/// Format an optional savings rate.
fn rate_label(value: Option<f64>) -> String {
    value.map_or_else(|| "n/a".to_string(), |rate| format!("{:.1}%", rate * 100.0))
}

/// Return a stable ratio for Ratatui gauges.
fn ratio(part: usize, total: usize) -> f64 {
    if total == 0 {
        0.0
    } else {
        (part as f64 / total as f64).clamp(0.0, 1.0)
    }
}

/// Preserve the established width-only policy for plain agent payloads.
fn dashboard_width() -> usize {
    let columns = std::env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok());
    let terminal_width = ratatui::crossterm::terminal::size()
        .ok()
        .map(|(width, _)| width);
    resolve_dashboard_width(columns, terminal_width)
}

/// Resolve an explicit plain-payload width before using the detected terminal width.
fn resolve_dashboard_width(columns: Option<usize>, terminal_width: Option<u16>) -> usize {
    columns
        .or_else(|| terminal_width.map(usize::from))
        .unwrap_or(usize::from(DASHBOARD_DEFAULT_WIDTH))
}

/// Parse one non-zero terminal dimension from the environment.
fn dashboard_environment_dimension(name: &str) -> Option<u16> {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|value| *value > 0)
}

/// Resolve live terminal dimensions before deterministic environment fallbacks.
fn resolve_dashboard_viewport(
    terminal_size: Option<(u16, u16)>,
    environment_columns: Option<u16>,
    environment_rows: Option<u16>,
) -> TokenDashboardViewport {
    let columns = terminal_size
        .and_then(|(columns, _)| NonZeroU16::new(columns))
        .or_else(|| environment_columns.and_then(NonZeroU16::new))
        .unwrap_or(NonZeroU16::new(DASHBOARD_DEFAULT_WIDTH).unwrap_or(NonZeroU16::MIN));
    let rows = terminal_size
        .and_then(|(_, rows)| NonZeroU16::new(rows))
        .or_else(|| environment_rows.and_then(NonZeroU16::new))
        .unwrap_or(NonZeroU16::new(DASHBOARD_HEIGHT).unwrap_or(NonZeroU16::MIN));
    TokenDashboardViewport { columns, rows }
}

/// Format an unsigned count with thousands separators.
fn grouped_count(value: usize) -> String {
    let raw = value.to_string();
    let mut grouped = String::with_capacity(raw.len() + raw.len() / 3);
    for (index, character) in raw.chars().enumerate() {
        if index > 0 && (raw.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(character);
    }
    grouped
}

/// Format a signed count with thousands separators.
fn signed_count(value: isize) -> String {
    if value < 0 {
        format!("-{}", grouped_count(value.unsigned_abs()))
    } else {
        grouped_count(usize::try_from(value).unwrap_or(usize::MAX))
    }
}

/// Format an exact byte count.
fn bytes(value: usize) -> String {
    format!("{} B", grouped_count(value))
}

/// Format an exact signed byte count.
fn signed_bytes(value: isize) -> String {
    format!("{} B", signed_count(value))
}

#[cfg(test)]
mod tests {
    use super::{
        ATLAS_CANVAS_X_BOUND, ATLAS_CANVAS_Y_BOUND, ATLAS_PREVIEW_MAX_EDGES,
        ATLAS_PREVIEW_MAX_NODE_DEGREE, ATLAS_PREVIEW_MAX_NODES, DASHBOARD_HEIGHT, THEME_BAR_EMPTY,
        THEME_BG, THEME_BLUE, THEME_GREEN, THEME_INK_WHITE, TOKEN_IMPACT_COLUMN_WIDTH,
        TokenAtlasPreview, TokenDashboardTheme, TokenDashboardViewport, atlas_layout, block_bar,
        buffer_to_ansi_string, buffer_to_string, reference_title, render_dashboard_to_string,
        render_overview_frame, render_overview_frame_with_atlas, render_token_dashboard,
        render_token_dashboard_with_atlas, render_token_dashboard_with_theme,
        render_token_trend_dashboard, render_token_trend_dashboard_with_theme,
        render_token_trend_dashboard_with_theme_in_viewport, resolve_dashboard_viewport,
        resolve_dashboard_width, signed_trend_points, signed_y_bounds, token_dashboard_wants_atlas,
    };
    use projectatlas_core::graph::GraphRelationKind;
    use projectatlas_core::symbols::RelationKind;
    use projectatlas_core::telemetry::{
        AgentEfficiencyComparison, AgentEfficiencyEvidenceState,
        TOKEN_ACCOUNTING_MODELED_AVOIDANCE, TOKEN_ACCOUNTING_OBSERVED_DELTA,
        TOKEN_BASELINE_DIRECTORY_WALK, TOKEN_BASELINE_FULL_FILE,
        TOKEN_BUCKET_FULL_FILE_COMPRESSION, TOKEN_BUCKET_NAVIGATION_AVOIDANCE,
        TOKEN_CONFIDENCE_OBSERVED, TOKEN_CONFIDENCE_POLICY_ESTIMATE, TOKEN_DEDUPE_SCOPE_EVENT,
        TOKEN_DEDUPE_SCOPE_SESSION, TokenOverview, TokenTrendPeriod, TokenTrendReport,
        TokenTrendWindow, usage_from_estimates, usage_from_estimates_with_accounting,
        usage_from_output, usage_from_text,
    };
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::buffer::{Buffer, CellWidth};
    use ratatui::layout::Rect;
    use ratatui::style::Style;
    use ratatui::style::{Color, Modifier};
    use ratatui::text::Line;
    use std::collections::{BTreeMap, BTreeSet, VecDeque};

    #[test]
    fn plain_dashboard_width_preserves_explicit_terminal_and_default_precedence() {
        assert_eq!(resolve_dashboard_width(Some(200), Some(190)), 200);
        assert_eq!(resolve_dashboard_width(None, Some(190)), 190);
        assert_eq!(resolve_dashboard_width(None, None), 140);
    }

    #[test]
    fn dashboard_viewport_prefers_live_dimensions_then_valid_fallbacks() {
        assert_eq!(
            viewport_dimensions(resolve_dashboard_viewport(
                Some((80, 24)),
                Some(200),
                Some(60),
            )),
            (80, 24)
        );
        assert_eq!(
            viewport_dimensions(resolve_dashboard_viewport(None, Some(100), Some(20),)),
            (100, 20)
        );
        assert_eq!(
            viewport_dimensions(resolve_dashboard_viewport(
                Some((0, 24)),
                Some(100),
                Some(0),
            )),
            (100, 24)
        );
        assert_eq!(
            viewport_dimensions(resolve_dashboard_viewport(Some((80, 0)), Some(0), Some(20),)),
            (80, 20)
        );
        assert_eq!(
            viewport_dimensions(resolve_dashboard_viewport(None, Some(0), Some(0),)),
            (140, 50)
        );
    }

    #[test]
    fn dashboard_viewport_selects_full_layout_and_atlas_at_exact_boundaries() {
        for (columns, rows, full_overview, full_trend, atlas) in [
            (79, 50, false, false, false),
            (80, 29, false, false, false),
            (80, 30, false, true, false),
            (80, 49, false, true, false),
            (80, 50, true, true, false),
            (189, 50, true, true, false),
            (190, 49, false, true, false),
            (190, 50, true, true, true),
            (200, 50, true, true, true),
        ] {
            let viewport = test_viewport(columns, rows);
            assert_eq!(viewport.fits_overview(), full_overview);
            assert_eq!(viewport.fits_trend(), full_trend);
            assert_eq!(token_dashboard_wants_atlas(viewport), atlas);
        }
    }

    #[test]
    fn compact_overview_is_bounded_and_preserves_facts_by_priority() {
        let overview = sample_overview();
        let atlas = TokenAtlasPreview::empty();
        for (columns, rows) in [(79, 50), (80, 49), (40, 4), (1, 1)] {
            let viewport = test_viewport(columns, rows);
            let dashboard = rendered_dashboard(render_token_dashboard_with_atlas(
                &overview,
                Some("s"),
                &atlas,
                TokenDashboardTheme::Dark,
                viewport,
            ));
            assert_ansi_bounds(&dashboard, viewport);
            assert!(!strip_ansi(&dashboard).contains(&reference_title("MEASURED BYTES SAVED")));
        }

        let dashboard = rendered_dashboard(render_token_dashboard_with_atlas(
            &overview,
            Some("s"),
            &atlas,
            TokenDashboardTheme::Dark,
            test_viewport(79, 8),
        ));
        let dashboard = strip_ansi(&dashboard);
        for required in [
            "ProjectAtlas Token Telemetry",
            "Measured saving: 80 B",
            "File 400 B - Output 320 B = Saved 80 B",
            "Atlas output: 327 B",
            "Calls:",
            "Excluded legacy: 3",
            "Basis:",
            "ProjectAtlas v",
        ] {
            assert!(
                dashboard.contains(required),
                "missing compact fact {required:?} in:\n{dashboard}"
            );
        }
    }

    #[test]
    fn full_dashboard_layouts_remain_compatible_at_minimum_dimensions() {
        let overview = sample_overview();
        let atlas = TokenAtlasPreview::empty();
        let overview_viewport = test_viewport(80, 50);
        let dashboard = rendered_dashboard(render_token_dashboard_with_atlas(
            &overview,
            Some("s"),
            &atlas,
            TokenDashboardTheme::Dark,
            overview_viewport,
        ));
        assert_ansi_bounds(&dashboard, overview_viewport);
        assert!(!dashboard.ends_with('\n'));
        let dashboard = strip_ansi(&dashboard);
        assert!(dashboard.contains(&reference_title("MEASURED BYTES SAVED")));
        assert!(dashboard.contains(&reference_title("MEASURED CALLS")));

        let trend_viewport = test_viewport(80, 30);
        let trend = rendered_dashboard(render_token_trend_dashboard_with_theme_in_viewport(
            &sample_trend_report(),
            TokenDashboardTheme::Dark,
            trend_viewport,
        ));
        assert_ansi_bounds(&trend, trend_viewport);
        assert!(!trend.ends_with('\n'));
        assert!(strip_ansi(&trend).contains(&reference_title("MEASURED BYTES SAVED TREND")));
    }

    #[test]
    fn compact_overview_and_trend_preserve_negative_savings() {
        let overview = negative_overview();
        assert_eq!(overview.saved_bytes, -8);
        let compact_overview = rendered_dashboard(render_token_dashboard_with_atlas(
            &overview,
            Some("s"),
            &TokenAtlasPreview::empty(),
            TokenDashboardTheme::Dark,
            test_viewport(60, 8),
        ));
        let compact_overview = strip_ansi(&compact_overview);
        assert!(compact_overview.contains("Measured saving: -8 B"));
        assert!(!compact_overview.contains('✓'));

        let trend = negative_trend_report();
        let compact_trend =
            rendered_dashboard(render_token_trend_dashboard_with_theme_in_viewport(
                &trend,
                TokenDashboardTheme::Dark,
                test_viewport(60, 7),
            ));
        let compact_trend = strip_ansi(&compact_trend);
        assert!(compact_trend.contains("Latest 2026-08: -8 B saved"));
        assert!(!compact_trend.contains('✓'));
    }

    #[test]
    fn compact_dashboards_preserve_semantic_styles_across_themes() {
        let overview = negative_overview();
        let overview_buffer =
            render_compact_lines_buffer(super::compact_overview_lines(&overview, Some("s")), 60, 8);
        let trend = negative_trend_report();
        let trend_buffer = render_compact_lines_buffer(super::compact_trend_lines(&trend), 60, 7);

        for (theme, loss_color) in [
            (TokenDashboardTheme::Dark, super::THEME_RED),
            (TokenDashboardTheme::Light, super::LIGHT_THEME.red),
            (TokenDashboardTheme::Terminal, super::THEME_RED),
        ] {
            assert_themed_cell_style(&overview_buffer, "-8 B", theme, loss_color, Modifier::BOLD);
            assert_themed_cell_style(&trend_buffer, "-8 B", theme, loss_color, Modifier::BOLD);
        }
    }

    #[test]
    fn compact_trend_is_bounded_below_each_full_dimension() {
        let report = sample_trend_report();
        for (columns, rows) in [(79, 30), (80, 29), (40, 4), (1, 1)] {
            let viewport = test_viewport(columns, rows);
            let dashboard =
                rendered_dashboard(render_token_trend_dashboard_with_theme_in_viewport(
                    &report,
                    TokenDashboardTheme::Dark,
                    viewport,
                ));
            assert_ansi_bounds(&dashboard, viewport);
            assert!(
                !strip_ansi(&dashboard).contains(&reference_title("MEASURED BYTES SAVED TREND"))
            );
        }

        let empty_report = TokenTrendReport::new(None, TokenTrendWindow::Month, Vec::new());
        let viewport = test_viewport(40, 3);
        let dashboard = rendered_dashboard(render_token_trend_dashboard_with_theme_in_viewport(
            &empty_report,
            TokenDashboardTheme::Dark,
            viewport,
        ));
        assert_ansi_bounds(&dashboard, viewport);
        assert!(strip_ansi(&dashboard).contains("Latest: no retained periods"));
    }

    #[test]
    fn overview_dashboard_shows_measured_sections_in_order() {
        let overview = sample_overview();
        let dashboard = strip_ansi(&render_token_dashboard(&overview, Some("s")));

        for text in [
            "ProjectAtlas",
            "Token Telemetry",
            "Measured values only. No estimates or counterfactual baselines.",
            "Session:",
            "Calls:",
            "Measured:",
            "Excluded legacy:",
            "Loaded file bytes",
            "Emitted bytes",
            "Saved bytes",
            "Emitted by all measured calls:",
            "Output-only calls:",
            "Measurement",
            "File bytes",
            "Output bytes",
            "File compared",
            "Output only",
            "Snapshot",
            "rerun command to refresh",
        ] {
            assert!(
                dashboard.contains(text),
                "dashboard should contain {text:?}"
            );
        }
        assert!(dashboard_contains_time(&dashboard));
        assert_in_order(
            &dashboard,
            &[
                "ProjectAtlas",
                &reference_title("MEASURED BYTES SAVED"),
                "Loaded file bytes",
                &reference_title("ATLAS OUTPUT"),
                &reference_title("MEASURED CALLS"),
                &reference_title("MEASUREMENT"),
            ],
        );
        assert_header_margin(&dashboard, "File bytes", "File compared");
    }

    #[test]
    fn overview_dashboard_never_renders_modeled_or_legacy_values() {
        let overview = sample_overview();
        for width in [80, 140, 200] {
            let dashboard = buffer_to_string(&render_overview_buffer_at_width(
                &overview,
                Some("s"),
                width,
            ));
            for forbidden in [
                "avoided",
                "Avoided",
                "modeled narrowing",
                "Navigation narrowing",
                "Without ProjectAtlas",
                "Confidence",
                "policy",
                "walk",
                "1,000,000",
                "18,000",
                "tokens",
            ] {
                assert!(
                    !dashboard.contains(forbidden),
                    "{width}-column dashboard must not show {forbidden:?}:\n{dashboard}"
                );
            }
        }
    }

    #[test]
    fn overview_dashboard_renders_complete_version_footer_at_supported_widths() {
        let overview = sample_overview();
        let expected_footer = format!("ProjectAtlas v{}", env!("CARGO_PKG_VERSION"));

        for width in [80, 140, 200] {
            let buffer = render_overview_buffer_at_width(&overview, Some("s"), width);
            let rows = (0..buffer.area.height)
                .map(|y| line_symbols(&buffer, y))
                .collect::<Vec<_>>();
            assert_eq!(
                rows.iter()
                    .filter(|row| row.contains(&expected_footer))
                    .count(),
                1,
                "{width}-column overview must contain exactly one complete version footer"
            );
            assert_eq!(
                rows.iter()
                    .map(|row| row.matches("ProjectAtlas v").count())
                    .sum::<usize>(),
                1,
                "{width}-column overview must not duplicate or clip the version footer"
            );
        }
    }

    #[test]
    fn overview_dashboard_light_theme_remaps_semantic_palette() {
        let overview = sample_overview();
        let dashboard =
            render_token_dashboard_with_theme(&overview, Some("s"), TokenDashboardTheme::Light);

        assert!(dashboard.contains("\x1b["));
        assert!(
            dashboard.contains("48;2;246;242;232"),
            "light theme should use the light panel background"
        );
        assert!(
            dashboard.contains("38;2;37;99;235"),
            "baseline blue should be remapped for light terminals"
        );
        assert!(
            dashboard.contains("38;2;22;128;72"),
            "saved green should be remapped for light terminals"
        );
        assert!(
            dashboard.contains("38;2;178;116;0"),
            "modeled yellow should be remapped for light terminals"
        );
        assert!(
            !dashboard.contains("48;2;5;16;25"),
            "light theme should not serialize the dark panel background"
        );
    }

    #[test]
    fn trend_dashboard_light_theme_remaps_semantic_palette() {
        let report = sample_trend_report();
        let dashboard = rendered_dashboard(render_token_trend_dashboard_with_theme(
            &report,
            TokenDashboardTheme::Light,
        ));

        assert!(dashboard.contains("\x1b["));
        assert!(
            dashboard.contains("48;2;246;242;232"),
            "light trend theme should use the light panel background"
        );
        assert!(
            dashboard.contains("38;2;22;128;72"),
            "positive trend line should use the light saved green"
        );
        assert!(
            dashboard.contains("38;2;22;22;20"),
            "ProjectAtlas trend title should use the light identity color"
        );
        assert!(
            !dashboard.contains("38;5;14") && !dashboard.contains("38;5;6"),
            "trend theme should not serialize hard-coded cyan"
        );
        assert!(
            !dashboard.contains("48;2;5;16;25"),
            "light trend theme should not serialize the dark panel background"
        );
    }

    #[test]
    fn overview_dashboard_uses_reference_ratatui_styles() {
        let overview = sample_overview();
        let buffer = render_overview_buffer(&overview, Some("s"));

        let Some((title_x, title_y)) = find_text(&buffer, "ProjectAtlas") else {
            unreachable!("ProjectAtlas title should render");
        };
        assert!(title_x <= 4, "title started at x={title_x}");
        assert!(title_y <= 4, "title started at y={title_y}");
        assert_cell_style(&buffer, "ProjectAtlas", THEME_INK_WHITE, Modifier::BOLD);
        assert_cell_style(&buffer, "Token Telemetry", THEME_BLUE, Modifier::BOLD);
        assert_cell_style(
            &buffer,
            &reference_title("MEASURED BYTES SAVED"),
            super::THEME_TEXT,
            Modifier::BOLD,
        );
        assert_cell_style(&buffer, "400 B", THEME_BLUE, Modifier::BOLD);
        assert_cell_style(&buffer, "Loaded file bytes", THEME_BLUE, Modifier::empty());
        assert_cell_style(&buffer, "Emitted bytes", THEME_INK_WHITE, Modifier::empty());
        assert_cell_style(&buffer, "Saved bytes", THEME_GREEN, Modifier::empty());
    }

    #[test]
    fn dashboards_preserve_terminal_background_outside_panels() {
        let overview = sample_overview();
        let overview_buffer = render_overview_buffer(&overview, Some("s"));
        assert_no_terminal_canvas_fill(&overview_buffer);
        assert_eq!(
            overview_buffer.cell((0, 0)).map(|cell| cell.bg),
            Some(Color::Reset),
            "outer overview border must not force a dashboard background color"
        );

        let overview_dark =
            render_token_dashboard_with_theme(&overview, Some("s"), TokenDashboardTheme::Dark);
        assert!(
            !overview_dark.contains("48;2;4;10;18"),
            "dark overview output must not paint the terminal canvas"
        );

        let overview_light =
            render_token_dashboard_with_theme(&overview, Some("s"), TokenDashboardTheme::Light);
        assert!(
            !overview_light.contains("48;2;252;249;241"),
            "light overview output must not paint the terminal canvas"
        );
        let overview_terminal =
            render_token_dashboard_with_theme(&overview, Some("s"), TokenDashboardTheme::Terminal);
        assert!(
            !overview_terminal.contains("48;2;5;16;25"),
            "terminal overview theme must preserve the terminal background inside panels"
        );
        let terminal_neutral_roles = super::with_token_theme(TokenDashboardTheme::Terminal, || {
            (
                super::themed_color(super::THEME_TEXT),
                super::themed_color(super::THEME_MUTED),
                super::themed_color(THEME_INK_WHITE),
            )
        });
        assert_eq!(
            terminal_neutral_roles,
            (Color::Reset, Color::Reset, Color::Reset),
            "terminal overview theme must use the terminal foreground for neutral text"
        );

        let report = sample_trend_report();
        let trend_buffer = render_trend_buffer(&report);
        assert_no_terminal_canvas_fill(&trend_buffer);
        assert_eq!(
            trend_buffer.cell((0, 0)).map(|cell| cell.bg),
            Some(Color::Reset),
            "outer trend border must not force a dashboard background color"
        );

        let trend_dark = rendered_dashboard(render_token_trend_dashboard_with_theme(
            &report,
            TokenDashboardTheme::Dark,
        ));
        assert!(
            !trend_dark.contains("48;2;4;10;18"),
            "dark trend output must not paint the terminal canvas"
        );

        let trend_light = rendered_dashboard(render_token_trend_dashboard_with_theme(
            &report,
            TokenDashboardTheme::Light,
        ));
        assert!(
            !trend_light.contains("48;2;252;249;241"),
            "light trend output must not paint the terminal canvas"
        );
        let trend_terminal = rendered_dashboard(render_token_trend_dashboard_with_theme(
            &report,
            TokenDashboardTheme::Terminal,
        ));
        assert!(
            !trend_terminal.contains("48;2;5;16;25"),
            "terminal trend theme must preserve the terminal background inside panels"
        );
    }

    #[test]
    fn overview_dashboard_hero_value_is_readable_terminal_text() {
        let overview = sample_overview();
        for width in [100, 140] {
            let buffer = render_overview_buffer_at_width(&overview, Some("s"), width);
            let Some((_, title_y)) = find_text(&buffer, &reference_title("MEASURED BYTES SAVED"))
            else {
                unreachable!("hero title should render");
            };
            let hero_rows = ((title_y + 1)..=(title_y + 2))
                .map(|y| line_symbols(&buffer, y))
                .collect::<Vec<_>>()
                .join("\n");
            assert!(hero_rows.contains(&super::signed_bytes(overview.saved_bytes)));
            assert!(hero_rows.contains('✓'));
            let caption_line = line_symbols(&buffer, title_y + 3);
            assert!(caption_line.contains("calls that loaded a complete file"));
            assert!(caption_line.contains("rate 20.0%"));
        }
    }

    #[test]
    fn overview_dashboard_uses_compact_reference_table_at_narrow_width() {
        let overview = sample_overview();
        let dashboard = render_dashboard_to_string(80, DASHBOARD_HEIGHT, |frame| {
            render_overview_frame(frame, &overview, Some("s"));
        });

        assert!(dashboard.contains("ProjectAtlas"));
        assert!(dashboard.contains("Token Telemetry"));
        assert!(dashboard.contains(&reference_title("MEASURED BYTES SAVED")));
        assert!(dashboard.contains(&reference_title("ATLAS OUTPUT")));
        assert!(dashboard.contains(&reference_title("MEASURED CALLS")));
        assert!(dashboard.contains(&reference_title("MEASUREMENT")));
        assert!(dashboard.contains("File compared"));
    }

    #[test]
    fn benchmark_evidence_never_changes_the_human_overview() {
        let live = sample_overview();
        for state in [
            AgentEfficiencyEvidenceState::Unavailable,
            AgentEfficiencyEvidenceState::Failed,
            AgentEfficiencyEvidenceState::Incompatible,
            AgentEfficiencyEvidenceState::Partial,
            AgentEfficiencyEvidenceState::Compatible,
        ] {
            let mut with_benchmark = live.clone();
            with_benchmark.agent_efficiency = AgentEfficiencyComparison {
                state,
                reason: Some(
                    "structured benchmark evidence remains available to agents".to_string(),
                ),
                artifact: None,
                baselines: Vec::new(),
                capabilities: Vec::new(),
                provider_counters_descriptive_only: true,
            };
            for width in [80, 140, 200] {
                let live = normalize_dashboard_clock(buffer_to_string(
                    &render_overview_buffer_at_width(&live, Some("s"), width),
                ));
                let with_benchmark = normalize_dashboard_clock(buffer_to_string(
                    &render_overview_buffer_at_width(&with_benchmark, Some("s"), width),
                ));
                assert_eq!(with_benchmark, live);
                assert!(!with_benchmark.contains("BENCHMARK"));
            }
        }
    }

    #[test]
    fn overview_dashboard_bars_reflect_expected_ratios() {
        let full = block_bar(10, 1.0, THEME_BLUE);
        assert_bar_segments(&full, 10, 0, THEME_BLUE);

        let partial = block_bar(10, 0.52, THEME_GREEN);
        assert_bar_segments(&partial, 5, 5, THEME_GREEN);
        assert_eq!(line_text(&partial), "█████░░░░░");

        let clamped = block_bar(10, 2.0, THEME_BLUE);
        assert_bar_segments(&clamped, 10, 0, THEME_BLUE);

        let empty = block_bar(10, -1.0, THEME_BLUE);
        assert_bar_segments(&empty, 0, 10, THEME_BLUE);
    }

    #[test]
    fn atlas_preview_is_bounded_connected_and_centers_the_strongest_hub() {
        let kinds = [
            GraphRelationKind::Legacy(RelationKind::Imports),
            GraphRelationKind::Legacy(RelationKind::Calls),
            GraphRelationKind::Legacy(RelationKind::DependsOn),
        ];
        let mut relations = Vec::new();
        for branch in 0..12 {
            let branch_length = if branch < 11 { 4 } else { 3 };
            let root = format!("branch-{branch:02}-00");
            relations.push(("hub".to_string(), root.clone(), kinds[branch % kinds.len()]));
            let mut previous = root.clone();
            for depth in 1..branch_length {
                let node = format!("branch-{branch:02}-{depth:02}");
                relations.push((
                    previous,
                    node.clone(),
                    kinds[(branch + depth) % kinds.len()],
                ));
                previous = node;
            }
            relations.push((root, previous, kinds[(branch + 1) % kinds.len()]));
        }
        for branch in 0..5 {
            relations.push((
                format!("branch-{branch:02}-02"),
                format!("branch-{:02}-02", branch + 1),
                kinds[(branch + 2) % kinds.len()],
            ));
        }
        relations.extend([
            ("island-a".to_string(), "island-b".to_string(), kinds[0]),
            ("island-b".to_string(), "island-c".to_string(), kinds[1]),
        ]);

        let atlas = TokenAtlasPreview::from_resolved_edges(relations, false);
        let layout = atlas_layout(&atlas.edges);
        let repeated_layout = atlas_layout(&atlas.edges);

        assert!(atlas.available);
        assert!(atlas.truncated);
        assert_eq!(atlas.node_count(), ATLAS_PREVIEW_MAX_NODES);
        assert_eq!(atlas.edges.len(), ATLAS_PREVIEW_MAX_EDGES);
        assert_eq!(layout.hub, "hub");
        let Some(hub) = layout.nodes.get(&layout.hub) else {
            unreachable!("connected atlas should retain its hub placement");
        };
        assert_eq!((hub.x, hub.y), (0.0, 0.0));
        assert_eq!(layout.nodes, repeated_layout.nodes);
        assert!(
            atlas.edges.iter().all(
                |edge| !edge.source.starts_with("island") && !edge.target.starts_with("island")
            )
        );
        let mut selected_degrees = BTreeMap::<&str, usize>::new();
        let mut adjacency = BTreeMap::<&str, BTreeSet<&str>>::new();
        for edge in &atlas.edges {
            *selected_degrees.entry(&edge.source).or_default() += 1;
            *selected_degrees.entry(&edge.target).or_default() += 1;
            adjacency
                .entry(&edge.source)
                .or_default()
                .insert(&edge.target);
            adjacency
                .entry(&edge.target)
                .or_default()
                .insert(&edge.source);
        }
        assert!(
            selected_degrees
                .values()
                .all(|degree| *degree <= ATLAS_PREVIEW_MAX_NODE_DEGREE)
        );
        let mut visited = BTreeSet::from([layout.hub.as_str()]);
        let mut frontier = VecDeque::from([layout.hub.as_str()]);
        while let Some(node) = frontier.pop_front() {
            if let Some(neighbors) = adjacency.get(node) {
                for neighbor in neighbors {
                    if visited.insert(*neighbor) {
                        frontier.push_back(*neighbor);
                    }
                }
            }
        }
        assert_eq!(visited.len(), atlas.node_count());
        assert!(
            layout
                .nodes
                .values()
                .all(|node| node.x.abs() < ATLAS_CANVAS_X_BOUND
                    && node.y.abs() < ATLAS_CANVAS_Y_BOUND)
        );
    }

    #[test]
    fn atlas_preview_discovers_expanding_branches_before_applying_visual_degree_limits() {
        let kind = GraphRelationKind::Legacy(RelationKind::Calls);
        let mut relations = Vec::new();
        for branch in 0..16 {
            let root = format!("branch-{branch:02}-root");
            relations.push(("hub".to_string(), root.clone(), kind));
            let leaves = (0..3)
                .map(|leaf| format!("branch-{branch:02}-leaf-{leaf}"))
                .collect::<Vec<_>>();
            for leaf in &leaves {
                relations.push((root.clone(), leaf.clone(), kind));
            }
            for (left, right) in [(0, 1), (1, 2), (2, 0)] {
                relations.push((leaves[left].clone(), leaves[right].clone(), kind));
            }
        }

        let atlas = TokenAtlasPreview::from_resolved_edges(relations, false);
        assert_eq!(atlas.node_count(), ATLAS_PREVIEW_MAX_NODES);
        assert_eq!(atlas.edges.len(), ATLAS_PREVIEW_MAX_EDGES);
        assert!(atlas.truncated);
        let mut selected_degrees = BTreeMap::<&str, usize>::new();
        for edge in &atlas.edges {
            *selected_degrees.entry(&edge.source).or_default() += 1;
            *selected_degrees.entry(&edge.target).or_default() += 1;
        }
        assert!(
            selected_degrees
                .values()
                .all(|degree| *degree <= ATLAS_PREVIEW_MAX_NODE_DEGREE)
        );

        let narrow =
            render_overview_buffer_with_atlas_at_width(&sample_overview(), None, &atlas, 189);
        assert!(!buffer_to_string(&narrow).contains(&reference_title("ATLAS MAP")));
        for width in [190, 200, 220] {
            let buffer =
                render_overview_buffer_with_atlas_at_width(&sample_overview(), None, &atlas, width);
            let dashboard = buffer_to_string(&buffer);
            assert!(dashboard.contains("48 nodes • 64 links"));
            let atlas_start = TOKEN_IMPACT_COLUMN_WIDTH + 2;
            let midpoint_x = atlas_start + (width - atlas_start) / 2;
            let midpoint_y = DASHBOARD_HEIGHT / 2;
            let quadrants = (0..buffer.area.height)
                .flat_map(|y| (atlas_start..buffer.area.width).map(move |x| (x, y)))
                .filter_map(|(x, y)| {
                    buffer.cell((x, y)).and_then(|cell| {
                        cell.symbol()
                            .chars()
                            .any(|character| ('\u{2801}'..='\u{28ff}').contains(&character))
                            .then_some((x >= midpoint_x, y >= midpoint_y))
                    })
                })
                .collect::<BTreeSet<_>>();
            assert!(
                quadrants.len() >= 3,
                "atlas should retain visible density across the panel at width {width}: {quadrants:?}"
            );
        }
    }

    #[test]
    fn atlas_preview_excludes_containment_before_applying_bounds() {
        let mut relations = (0..80)
            .map(|index| {
                (
                    "containment-root".to_string(),
                    format!("contained-{index:02}"),
                    GraphRelationKind::Legacy(RelationKind::Contains),
                )
            })
            .collect::<Vec<_>>();
        relations.extend([
            (
                "network-root".to_string(),
                "network-a".to_string(),
                GraphRelationKind::Legacy(RelationKind::Calls),
            ),
            (
                "network-a".to_string(),
                "network-b".to_string(),
                GraphRelationKind::Legacy(RelationKind::Imports),
            ),
        ]);

        let atlas = TokenAtlasPreview::from_resolved_edges(relations, false);

        assert_eq!(atlas.edges.len(), 2);
        assert!(atlas.edges.iter().all(|edge| {
            !matches!(edge.kind, GraphRelationKind::Legacy(RelationKind::Contains))
                && !edge.source.starts_with("contain")
                && !edge.target.starts_with("contain")
        }));
    }

    #[test]
    fn wide_atlas_map_renders_real_counts_and_stays_inside_its_panel() {
        let kind = GraphRelationKind::Legacy(RelationKind::Calls);
        let mut relations = (0..6)
            .map(|index| ("hub".to_string(), format!("node-{index}"), kind))
            .collect::<Vec<_>>();
        relations.extend([
            ("node-0".to_string(), "satellite-a".to_string(), kind),
            ("satellite-a".to_string(), "satellite-b".to_string(), kind),
        ]);
        let atlas = TokenAtlasPreview::from_resolved_edges(relations, false);
        let buffer =
            render_overview_buffer_with_atlas_at_width(&sample_overview(), Some("s"), &atlas, 200);
        let dashboard = buffer_to_string(&buffer);

        assert!(dashboard.contains(&reference_title("ATLAS MAP")));
        assert!(dashboard.contains("9 nodes • 8 links"));
        assert!(dashboard.contains("bounded live graph • static snapshot"));
        assert!(buffer_contains_braille(
            &buffer,
            TOKEN_IMPACT_COLUMN_WIDTH + 2
        ));
        assert!(!dashboard.contains("Frozen v0.3.26"));
        assert!(!dashboard.contains("Plain Codex"));
        assert!(!dashboard.contains(&reference_title("REPEATED-WORK BENCHMARK")));
        for y in 2..(DASHBOARD_HEIGHT - 2) {
            assert_eq!(
                buffer.cell((198, y)).map(ratatui::buffer::Cell::symbol),
                Some("│"),
                "atlas panel right border should remain intact at row {y}"
            );
        }
    }

    #[test]
    fn atlas_map_hides_when_narrow_and_never_invents_empty_state_data() {
        let kind = GraphRelationKind::Legacy(RelationKind::Calls);
        let atlas = TokenAtlasPreview::from_resolved_edges(
            [("source".to_string(), "target".to_string(), kind)],
            false,
        );
        let narrow =
            render_overview_buffer_with_atlas_at_width(&sample_overview(), Some("s"), &atlas, 189);
        assert!(!buffer_to_string(&narrow).contains(&reference_title("ATLAS MAP")));

        for (atlas, message) in [
            (TokenAtlasPreview::empty(), "No resolved graph links"),
            (
                TokenAtlasPreview::unavailable(),
                "Graph preview unavailable",
            ),
        ] {
            let buffer = render_overview_buffer_with_atlas_at_width(
                &sample_overview(),
                Some("s"),
                &atlas,
                200,
            );
            let dashboard = buffer_to_string(&buffer);
            assert!(dashboard.contains(message));
            assert!(!dashboard.contains("nodes •"));
            assert!(!buffer_contains_braille(
                &buffer,
                TOKEN_IMPACT_COLUMN_WIDTH + 2
            ));
        }
    }

    #[test]
    fn overview_dashboard_preserves_negative_savings_in_visual_widgets() {
        let overview = negative_overview();
        for width in [100, 140] {
            let buffer = render_overview_buffer_at_width(&overview, Some("s"), width);
            let Some((_, title_y)) = find_text(&buffer, &reference_title("MEASURED BYTES SAVED"))
            else {
                unreachable!("hero title should render");
            };
            let hero_rows = ((title_y + 1)..=(title_y + 2))
                .map(|y| line_symbols(&buffer, y))
                .collect::<Vec<_>>()
                .join("\n");
            assert!(hero_rows.contains('!'));
            assert!(!hero_rows.contains('✓'));
            assert_cell_style(&buffer, "-8 B", super::THEME_RED, Modifier::BOLD);
        }

        let trend = [
            TokenTrendPeriod::from_buckets(
                "loss".to_string(),
                TokenOverview::from_events(&[usage_from_text(
                    "s", "slice", None, None, "ab", "abcd",
                )])
                .buckets,
            ),
            TokenTrendPeriod::from_buckets(
                "gain".to_string(),
                TokenOverview::from_events(&[usage_from_text(
                    "s", "slice", None, None, "abcd", "ab",
                )])
                .buckets,
            ),
        ];
        let points = signed_trend_points(Some(&trend));
        assert_float_eq(points[0].1, -2.0);
        assert_float_eq(points[1].1, 2.0);
        let bounds = signed_y_bounds(&points);
        assert_float_eq(bounds[0], -2.0);
        assert_float_eq(bounds[1], 2.0);

        let single_points = signed_trend_points(Some(&trend[1..]));
        assert_float_eq(single_points[0].0, 0.0);
        assert_float_eq(single_points[0].1, 2.0);
        assert_float_eq(single_points[1].0, 1.0);
        assert_float_eq(single_points[1].1, 2.0);
    }

    #[test]
    fn trend_dashboard_renders_chart_and_period_table() {
        let report = sample_trend_report();
        let dashboard = strip_ansi(&render_token_trend_dashboard(&report));

        assert!(dashboard.contains("ProjectAtlas Token Trends"));
        assert!(dashboard.contains(&reference_title("MEASURED BYTES SAVED TREND")));
        assert!(dashboard.contains("2026-06"));
        assert!(dashboard.contains("2026-07"));
        assert!(dashboard.contains("period"));
        assert!(!dashboard.contains("estimate"));
        assert!(dashboard_contains_chart_glyph(&dashboard));
    }

    fn sample_trend_report() -> TokenTrendReport {
        TokenTrendReport::new(
            Some("s".to_string()),
            TokenTrendWindow::Month,
            vec![
                TokenTrendPeriod::from_buckets(
                    "2026-06".to_string(),
                    TokenOverview::from_events(&[usage_from_text(
                        "s",
                        "summary",
                        None,
                        None,
                        &"x".repeat(200),
                        &"x".repeat(50),
                    )])
                    .buckets,
                ),
                TokenTrendPeriod::from_buckets(
                    "2026-07".to_string(),
                    TokenOverview::from_events(&[usage_from_text(
                        "s",
                        "summary",
                        None,
                        None,
                        &"x".repeat(100),
                        &"x".repeat(80),
                    )])
                    .buckets,
                ),
            ],
        )
    }

    fn negative_overview() -> TokenOverview {
        TokenOverview::from_events(&[usage_from_text(
            "s",
            "summary",
            Some("src/lib.rs".to_string()),
            None,
            "abcd",
            "abcdabcdabcd",
        )])
    }

    fn negative_trend_report() -> TokenTrendReport {
        TokenTrendReport::new(
            Some("s".to_string()),
            TokenTrendWindow::Month,
            vec![TokenTrendPeriod::from_buckets(
                "2026-08".to_string(),
                negative_overview().buckets,
            )],
        )
    }

    fn test_viewport(columns: u16, rows: u16) -> TokenDashboardViewport {
        resolve_dashboard_viewport(None, Some(columns), Some(rows))
    }

    fn rendered_dashboard(result: std::io::Result<String>) -> String {
        match result {
            Ok(dashboard) => dashboard,
            Err(error) => unreachable!("in-memory token dashboard render failed: {error}"),
        }
    }

    fn viewport_dimensions(viewport: TokenDashboardViewport) -> (u16, u16) {
        (viewport.columns(), viewport.rows())
    }

    fn assert_ansi_bounds(output: &str, viewport: TokenDashboardViewport) {
        let plain = strip_ansi(output);
        assert!(
            plain.lines().count() <= usize::from(viewport.rows()),
            "dashboard exceeded {} rows:\n{plain}",
            viewport.rows()
        );
        for line in plain.lines() {
            assert!(
                line.cell_width() <= viewport.columns(),
                "dashboard line exceeded {} columns: {line:?}",
                viewport.columns()
            );
        }
    }

    #[test]
    fn ansi_serializer_emits_each_wide_grapheme_once() {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 8, 4));
        buffer.set_string(0, 0, "A界B", Style::default());
        buffer.set_string(0, 1, "e\u{301}", Style::default());
        buffer.set_string(0, 2, "👨‍👩‍👧‍👦", Style::default());

        let output = strip_ansi(&buffer_to_ansi_string(&buffer));
        let lines = output.lines().collect::<Vec<_>>();
        assert_eq!(lines[0].cell_width(), 8);
        assert_eq!(lines[0].matches('界').count(), 1);
        assert_eq!(lines[1].cell_width(), 8);
        assert_eq!(lines[2].cell_width(), 8);
    }

    fn sample_overview() -> TokenOverview {
        TokenOverview::from_events(&[
            usage_from_text(
                "s",
                "summary",
                Some("src/lib.rs".to_string()),
                None,
                &"x".repeat(400),
                &"x".repeat(320),
            ),
            usage_from_output("s", "search", None, Some("token".to_string()), "hits:1\n"),
            usage_from_estimates_with_accounting(
                "s",
                "folders",
                None,
                Some("src".to_string()),
                1_000_000,
                20,
                TOKEN_BUCKET_NAVIGATION_AVOIDANCE,
                TOKEN_BASELINE_DIRECTORY_WALK,
                TOKEN_CONFIDENCE_POLICY_ESTIMATE,
                TOKEN_ACCOUNTING_MODELED_AVOIDANCE,
                TOKEN_BASELINE_DIRECTORY_WALK,
                TOKEN_DEDUPE_SCOPE_SESSION,
            ),
            usage_from_estimates("s", "search", None, Some("src".to_string()), 18_000, 16),
            usage_from_estimates_with_accounting(
                "s",
                "summary",
                None,
                None,
                9_000,
                20,
                TOKEN_BUCKET_FULL_FILE_COMPRESSION,
                TOKEN_BASELINE_FULL_FILE,
                TOKEN_CONFIDENCE_OBSERVED,
                TOKEN_ACCOUNTING_OBSERVED_DELTA,
                TOKEN_BASELINE_FULL_FILE,
                TOKEN_DEDUPE_SCOPE_EVENT,
            ),
        ])
    }

    fn render_overview_buffer(overview: &TokenOverview, session: Option<&str>) -> Buffer {
        render_overview_buffer_at_width(overview, session, 140)
    }

    fn render_compact_lines_buffer(lines: Vec<Line<'_>>, width: u16, height: u16) -> Buffer {
        let backend = TestBackend::new(width, height);
        let mut terminal =
            Terminal::new(backend).expect("in-memory token dashboard backend should initialize");
        let frame = terminal
            .draw(move |frame| {
                frame.render_widget(ratatui::widgets::Paragraph::new(lines), frame.area());
            })
            .expect("in-memory compact token dashboard should render");
        frame.buffer.clone()
    }

    fn render_overview_buffer_at_width(
        overview: &TokenOverview,
        session: Option<&str>,
        width: u16,
    ) -> Buffer {
        let backend = TestBackend::new(width, DASHBOARD_HEIGHT);
        let mut terminal =
            Terminal::new(backend).expect("in-memory token dashboard backend should initialize");
        let frame = terminal
            .draw(|frame| render_overview_frame(frame, overview, session))
            .expect("in-memory token dashboard should render");
        frame.buffer.clone()
    }

    fn render_overview_buffer_with_atlas_at_width(
        overview: &TokenOverview,
        session: Option<&str>,
        atlas: &TokenAtlasPreview,
        width: u16,
    ) -> Buffer {
        let backend = TestBackend::new(width, DASHBOARD_HEIGHT);
        let mut terminal =
            Terminal::new(backend).expect("in-memory token dashboard backend should initialize");
        let frame = terminal
            .draw(|frame| render_overview_frame_with_atlas(frame, overview, session, Some(atlas)))
            .expect("in-memory token dashboard with atlas should render");
        frame.buffer.clone()
    }

    fn buffer_contains_braille(buffer: &Buffer, start_x: u16) -> bool {
        (0..buffer.area.height).any(|y| {
            (start_x..buffer.area.width).any(|x| {
                buffer.cell((x, y)).is_some_and(|cell| {
                    cell.symbol()
                        .chars()
                        .any(|character| ('\u{2801}'..='\u{28ff}').contains(&character))
                })
            })
        })
    }

    fn render_trend_buffer(report: &TokenTrendReport) -> Buffer {
        let backend = TestBackend::new(
            super::DASHBOARD_DEFAULT_WIDTH,
            super::TREND_DASHBOARD_HEIGHT,
        );
        let mut terminal =
            Terminal::new(backend).expect("in-memory token dashboard backend should initialize");
        let frame = terminal
            .draw(|frame| super::render_trend_frame(frame, report))
            .expect("in-memory token dashboard should render");
        frame.buffer.clone()
    }

    fn line_symbols(buffer: &Buffer, y: u16) -> String {
        let mut line = String::new();
        for x in 0..buffer.area.width {
            if let Some(cell) = buffer.cell((x, y)) {
                line.push_str(cell.symbol());
            }
        }
        line
    }

    fn assert_no_terminal_canvas_fill(buffer: &Buffer) {
        for y in 0..buffer.area.height {
            for x in 0..buffer.area.width {
                let Some(cell) = buffer.cell((x, y)) else {
                    continue;
                };
                assert_ne!(
                    cell.bg, THEME_BG,
                    "dashboard should not force the terminal canvas background at ({x},{y})"
                );
            }
        }
    }

    fn assert_header_margin(dashboard: &str, header: &str, first_row: &str) {
        let header_index = dashboard.lines().position(|line| line.contains(header));
        assert!(
            header_index.is_some(),
            "dashboard should contain table header {header:?}"
        );
        let Some(header_index) = header_index else {
            return;
        };
        let row_index = dashboard.lines().position(|line| line.contains(first_row));
        assert!(
            row_index.is_some(),
            "dashboard should contain first table row {first_row:?}"
        );
        let Some(row_index) = row_index else {
            return;
        };
        assert!(
            row_index >= header_index + 2,
            "expected a visible separator row between {header:?} and {first_row:?}"
        );
    }

    fn assert_in_order(dashboard: &str, needles: &[&str]) {
        let mut previous = 0usize;
        for needle in needles {
            let Some(index) = dashboard.find(needle) else {
                assert!(
                    dashboard.contains(needle),
                    "dashboard should contain {needle:?}"
                );
                return;
            };
            assert!(
                index >= previous,
                "{needle:?} should appear after the previous section"
            );
            previous = index;
        }
    }

    fn dashboard_contains_time(dashboard: &str) -> bool {
        let bytes = dashboard.as_bytes();
        bytes.windows(8).any(|window| {
            window.len() == 8
                && window[2] == b':'
                && window[5] == b':'
                && window
                    .iter()
                    .enumerate()
                    .all(|(index, byte)| index == 2 || index == 5 || byte.is_ascii_digit())
        })
    }

    fn normalize_dashboard_clock(mut dashboard: String) -> String {
        let Some(time_start) = dashboard
            .find("Snapshot ")
            .map(|start| start + "Snapshot ".len())
        else {
            return dashboard;
        };
        let time_len = if dashboard.as_bytes().get(time_start + 5) == Some(&b':') {
            8
        } else {
            5
        };
        dashboard.replace_range(time_start..time_start + time_len, "CLOCK");
        dashboard
    }

    fn assert_bar_segments(line: &Line<'_>, filled: usize, empty: usize, color: Color) {
        assert_eq!(line.spans.len(), 2);
        assert_eq!(line.spans[0].content.chars().count(), filled);
        assert_eq!(line.spans[1].content.chars().count(), empty);
        assert!(
            line.spans[0]
                .content
                .chars()
                .all(|character| character == '█')
        );
        assert!(
            line.spans[1]
                .content
                .chars()
                .all(|character| character == '░')
        );
        assert_eq!(line.spans[0].style.fg, Some(color));
        assert_eq!(line.spans[1].style.fg, Some(THEME_BAR_EMPTY));
    }

    fn line_text(line: &Line<'_>) -> String {
        line.spans
            .iter()
            .map(|span| span.content.as_ref())
            .collect::<String>()
    }

    fn dashboard_contains_chart_glyph(dashboard: &str) -> bool {
        dashboard.chars().any(|character| {
            matches!(
                character,
                '█' | '▌' | '▏' | '▅' | '▁' | '\u{2801}'..='\u{28ff}'
            )
        })
    }

    fn assert_float_eq(left: f64, right: f64) {
        assert!(
            (left - right).abs() < f64::EPSILON,
            "expected {left} to equal {right}"
        );
    }

    fn assert_cell_style(buffer: &Buffer, text: &str, color: Color, modifier: Modifier) {
        let found = find_text(buffer, text);
        assert!(found.is_some(), "rendered buffer should contain {text:?}");
        let Some((x, y)) = found else {
            return;
        };
        let cell = buffer.cell((x, y));
        assert!(
            cell.is_some(),
            "located text should resolve to a buffer cell"
        );
        let Some(cell) = cell else {
            return;
        };
        assert_eq!(cell.fg, color, "unexpected foreground color for {text:?}");
        assert!(
            cell.modifier.contains(modifier),
            "missing modifier {modifier:?} for {text:?}"
        );
    }

    fn assert_themed_cell_style(
        buffer: &Buffer,
        text: &str,
        theme: TokenDashboardTheme,
        color: Color,
        modifier: Modifier,
    ) {
        super::with_token_theme(theme, || {
            let Some((x, y)) = find_text(buffer, text) else {
                unreachable!("rendered buffer should contain {text:?}");
            };
            let Some(cell) = buffer.cell((x, y)) else {
                unreachable!("located text should resolve to a buffer cell");
            };
            let style = super::CellAnsiStyle::from_cell(cell);
            assert_eq!(style.fg, color, "unexpected themed color for {text:?}");
            assert!(
                style.modifier.contains(modifier),
                "missing themed modifier {modifier:?} for {text:?}"
            );
        });
    }

    fn strip_ansi(input: &str) -> String {
        let mut output = String::with_capacity(input.len());
        let mut chars = input.chars().peekable();
        while let Some(character) = chars.next() {
            if character == '\u{1b}' && chars.peek() == Some(&'[') {
                chars.next();
                for code in chars.by_ref() {
                    if code.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                output.push(character);
            }
        }
        output
    }

    fn find_text(buffer: &Buffer, text: &str) -> Option<(u16, u16)> {
        assert!(
            text.is_ascii(),
            "use direct cell assertions for non-ASCII symbols"
        );
        for y in 0..buffer.area.height {
            let mut cells = Vec::new();
            let mut line = String::new();
            for x in 0..buffer.area.width {
                let symbol = buffer.cell((x, y))?.symbol();
                if symbol.is_ascii() {
                    line.push_str(symbol);
                } else {
                    line.push(' ');
                }
                cells.push((x, y));
            }
            if let Some(index) = line.find(text) {
                return cells.get(index).copied();
            }
        }
        None
    }
}
