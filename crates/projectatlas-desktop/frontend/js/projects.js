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

  /** Rendered rows keyed by project id, so badges can be patched without a rebuild. */
  const rows = new Map();
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
  function signature(projects, activeId) {
    return projects
      .map(function (project) {
        return project.id + ":" + project.displayName + ":" + project.status;
      })
      .join("|") + "#" + (activeId || "");
  }

  /** Render the empty-state hint shown when no project is registered yet. */
  function renderEmpty() {
    listEl.textContent = "";
    const note = document.createElement("div");
    note.className = "sidebar-empty";
    note.textContent =
      "Noch kein Projekt gefunden. „Scan“ durchsucht den Projekte-Ordner, " +
      "„+ Ordner“ fügt eines von Hand hinzu.";
    listEl.appendChild(note);
    titleEl.textContent = "Kein Projekt gewählt";
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

    const badge = document.createElement("span");
    badge.className = "project-row-badge";
    badge.textContent = "";

    row.appendChild(dot);
    row.appendChild(name);
    row.appendChild(badge);
    row.addEventListener("click", function () {
      onSelect(project.id);
    });

    rows.set(project.id, { row: row, badge: badge });
    return row;
  }

  /** Render the project list, skipping the rebuild when nothing structural changed. */
  function render(payload) {
    const projects = (payload && payload.projects) || [];
    const activeId = payload && payload.activeProjectId;
    const nextSignature = signature(projects, activeId);
    if (nextSignature === renderedSignature) return;
    renderedSignature = nextSignature;

    if (projects.length === 0) {
      rows.clear();
      renderEmpty();
      return;
    }

    rows.clear();
    listEl.textContent = "";
    projects.forEach(function (project) {
      listEl.appendChild(buildRow(project, project.id === activeId));
    });

    const active = projects.filter(function (project) {
      return project.id === activeId;
    })[0];
    titleEl.textContent = active ? active.root : "Kein Projekt gewählt";
  }

  /** Patch the sidebar badge numbers in place. */
  function renderBadges(badges) {
    (badges || []).forEach(function (badge) {
      const entry = rows.get(badge.id);
      if (!entry) return;
      entry.badge.textContent = fmt.tokens(badge.saved);
      entry.badge.title = fmt.int(badge.calls) + " Aufrufe";
    });
  }

  /** Register the selection callback. */
  function setSelectHandler(handler) {
    onSelect = handler;
  }

  return {
    render: render,
    renderBadges: renderBadges,
    setSelectHandler: setSelectHandler
  };
})();
