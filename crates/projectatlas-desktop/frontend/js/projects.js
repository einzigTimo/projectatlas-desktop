/* Purpose: The sidebar project switcher.
   Rows are rebuilt only when the project list itself changes; badge numbers are
   patched in place so a background refresh never rebuilds the sidebar under the
   user's cursor. */

window.PAD = window.PAD || {};

window.PAD.projects = (function () {
  "use strict";

  const fmt = window.PAD.format;
  const listEl = document.getElementById("projectList");
  const titleEl = document.getElementById("projTitle");
  const filterStatusEl = document.getElementById("purposeFilterStatus");

  /** Rendered rows keyed by project id, so badges can be patched without a rebuild. */
  const rows = new Map();
  /** Latest savings badges, retained when a Purpose search rebuilds visible rows. */
  const badgeValues = new Map();
  /** Signature of the currently rendered list, used to skip pointless rebuilds. */
  let renderedSignature = "";
  /** Callback invoked when the user selects a different project. */
  let onSelect = function () {};

  /** Map a backend status to its sidebar dot class. */
  function statusClass(status) {
    if (status === "ok") return "";
    if (status === "openError") return " status-warn";
    return " status-off";
  }

  /** Build a stable signature of the list shape. */
  function signature(projects, activeId, filterQuery, activeRoot) {
    return projects
      .map(function (project) {
        const purpose = project.purposeSummary;
        const byStatus = (purpose && purpose.byStatus) || {};
        return [
          project.id,
          project.displayName,
          project.root,
          project.status,
          project.statusMessage,
          purpose && purpose.totalNodes,
          purpose && purpose.withPurpose,
          byStatus.approved,
          byStatus.suggested,
          byStatus.stale,
          byStatus.missing
        ].join(":");
      })
      .join("|") + "#" + (activeId || "") + "#" + (filterQuery || "") + "#" + (activeRoot || "");
  }

  /** Render the empty-state hint shown when no project is registered yet. */
  function renderEmpty(filterQuery, activeProject) {
    listEl.textContent = "";
    const note = document.createElement("div");
    note.className = "sidebar-empty";
    if (filterQuery) {
      note.textContent = "Kein Projekt enthält Purpose-Text passend zu „" + filterQuery + "“.";
    } else {
      note.textContent =
        "Noch kein Projekt gefunden. „Scan“ durchsucht den Projekte-Ordner, " +
        "„+ Ordner“ fügt eines von Hand hinzu.";
    }
    listEl.appendChild(note);
    titleEl.textContent = activeProject ? activeProject.root : "Kein Projekt gewählt";
  }

  /** Format the compact Purpose coverage shown below a project name. */
  function purposeCoverage(summary) {
    if (!summary) return "Purpose –";
    return "Purpose " + fmt.int(summary.withPurpose || 0) + "/" + fmt.int(summary.totalNodes || 0);
  }

  /** Explain the complete Purpose review status without widening the sidebar. */
  function purposeTooltip(summary) {
    if (!summary) return "Purpose-Status nicht verfügbar.";
    const status = summary.byStatus || {};
    return [
      "Purpose-Abdeckung: " + fmt.int(summary.withPurpose || 0) + " von " + fmt.int(summary.totalNodes || 0),
      "Freigegeben: " + fmt.int(status.approved || 0),
      "Vorgeschlagen: " + fmt.int(status.suggested || 0),
      "Veraltet: " + fmt.int(status.stale || 0),
      "Fehlend: " + fmt.int(status.missing || 0)
    ].join("\n");
  }

  /** Write one cached or freshly loaded savings badge into a rendered row. */
  function applyBadge(entry, badge) {
    entry.badge.textContent = fmt.tokens(badge.saved);
    entry.badge.title = fmt.int(badge.calls) + " Aufrufe";
  }

  /** Build one sidebar row. */
  function buildRow(project, isActive) {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "project-row" + statusClass(project.status) + (isActive ? " active" : "");
    row.title = project.statusMessage ? project.root + "\n" + project.statusMessage : project.root;

    const dot = document.createElement("span");
    dot.className = "dot";

    const name = document.createElement("span");
    name.className = "project-row-name";
    name.textContent = project.displayName;

    const purpose = document.createElement("span");
    purpose.className = "project-purpose-chip";
    purpose.textContent = purposeCoverage(project.purposeSummary);
    purpose.title = purposeTooltip(project.purposeSummary);
    if (project.purposeSummary) {
      const status = project.purposeSummary.byStatus || {};
      if ((status.stale || 0) > 0 || (status.missing || 0) > 0) {
        purpose.classList.add("needs-work");
      } else if ((status.suggested || 0) > 0) {
        purpose.classList.add("suggested");
      } else {
        purpose.classList.add("complete");
      }
    }

    const content = document.createElement("span");
    content.className = "project-row-content";
    content.appendChild(name);
    content.appendChild(purpose);

    const badge = document.createElement("span");
    badge.className = "project-row-badge";
    badge.textContent = "";

    row.appendChild(dot);
    row.appendChild(content);
    row.appendChild(badge);
    row.addEventListener("click", function () {
      onSelect(project.id);
    });

    const entry = { row: row, badge: badge };
    rows.set(project.id, entry);
    if (badgeValues.has(project.id)) applyBadge(entry, badgeValues.get(project.id));
    return row;
  }

  /** Render the project list, skipping the rebuild when nothing structural changed. */
  function render(payload, options) {
    const projects = (payload && payload.projects) || [];
    const activeId = payload && payload.activeProjectId;
    const filterQuery = (options && options.filterQuery) || "";
    const activeProject = options && options.activeProject;
    const nextSignature = signature(projects, activeId, filterQuery, activeProject && activeProject.root);
    if (nextSignature === renderedSignature) return;
    renderedSignature = nextSignature;

    if (projects.length === 0) {
      rows.clear();
      renderEmpty(filterQuery, activeProject);
      return;
    }

    rows.clear();
    listEl.textContent = "";
    projects.forEach(function (project) {
      listEl.appendChild(buildRow(project, project.id === activeId));
    });

    const active = activeProject || projects.filter(function (project) {
      return project.id === activeId;
    })[0];
    titleEl.textContent = active ? active.root : "Kein Projekt gewählt";
  }

  /** Keep the compact filter progress/error message accessible to screen readers. */
  function setFilterStatus(text, isError) {
    if (!filterStatusEl) return;
    filterStatusEl.textContent = text || "";
    filterStatusEl.classList.toggle("error", !!isError);
  }

  /** Patch the sidebar badge numbers in place. */
  function renderBadges(badges) {
    badgeValues.clear();
    rows.forEach(function (entry) {
      entry.badge.textContent = "";
      entry.badge.removeAttribute("title");
    });
    (badges || []).forEach(function (badge) {
      badgeValues.set(badge.id, badge);
      const entry = rows.get(badge.id);
      if (!entry) return;
      applyBadge(entry, badge);
    });
  }

  /** Register the selection callback. */
  function setSelectHandler(handler) {
    onSelect = handler;
  }

  return {
    render: render,
    renderBadges: renderBadges,
    setSelectHandler: setSelectHandler,
    setFilterStatus: setFilterStatus
  };
})();
