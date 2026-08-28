/* Purpose: The setup screen — which AI tools are installed, and connecting a project.

   Reachable from the small link symbol in the sidebar footer, next to the update gear,
   because it is about the machine and the tooling rather than about the numbers of one
   project.

   Connecting runs `projectatlas init` in the project folder through the bundled
   command-line binary, so nobody has to open a terminal. Detection only checks whether
   a tool's configuration folder exists — nothing inside it is read or changed. */

window.PAD = window.PAD || {};

window.PAD.setup = (function () {
  "use strict";

  const api = window.PAD.api;

  /** Id of the project the dashboard currently shows. */
  let projectId = null;
  /** Display name of that project, for the heading. */
  let projectName = null;
  /** Whether a detection or connect call is currently running. */
  let busy = false;
  /** Whether the overlay is open, so background changes can refresh it. */
  let open_ = false;
  /** Handle of the running elapsed-time ticker, or null while idle. */
  let activityTimer = null;
  /** Timestamp the current run started at, for the elapsed counter. */
  let activityStart = 0;

  /** Return one element by id. */
  function el(id) {
    return document.getElementById(id);
  }

  /** Write text into one element by id. */
  function setText(id, text) {
    const node = el(id);
    if (node) node.textContent = text;
  }

  /** Remove every child of one element. */
  function clear(node) {
    while (node && node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  /** Build one element with a class and text, avoiding innerHTML for tool-supplied paths. */
  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  /** Enable or disable the two action buttons. */
  function setBusy(next) {
    busy = next;
    const connect = el("setupConnectBtn");
    const all = el("setupConnectAllBtn");
    if (connect) connect.disabled = busy || !projectId;
    if (all) all.disabled = busy;
  }

  /** Turn a backend error into a readable sentence. */
  function message(error) {
    if (!error) return "Unbekannter Fehler.";
    if (typeof error === "string") return error;
    if (error.message) return error.message;
    return String(error);
  }

  /** Render the list of detected tools. */
  function renderTools(tools) {
    const host = el("setupTools");
    if (!host) return;
    clear(host);

    if (!tools || tools.length === 0) {
      host.appendChild(make("div", "setup-empty", "Keine Werkzeuge erkannt."));
      return;
    }

    tools.forEach(function (tool) {
      const row = make("div", "setup-tool" + (tool.installed ? " found" : ""));
      row.appendChild(make("span", "setup-tool-pip", tool.installed ? "✓" : "–"));
      row.appendChild(make("span", "setup-tool-name", tool.displayName));
      row.appendChild(
        make(
          "span",
          "setup-tool-path",
          tool.installed ? tool.configPath : "nicht gefunden"
        )
      );
      host.appendChild(row);
    });
  }

  /** Render the host configuration files of the selected project. */
  function renderFiles(files) {
    const host = el("setupFiles");
    if (!host) return;
    clear(host);
    if (!files || files.length === 0) return;

    files.forEach(function (file) {
      const row = make("div", "setup-file" + (file.present ? " present" : ""));
      row.appendChild(make("span", "setup-file-pip", file.present ? "✓" : "–"));
      row.appendChild(make("span", "setup-file-name", file.name));
      row.appendChild(make("span", "setup-file-use", "für " + file.usedBy));
      host.appendChild(row);
    });
  }

  /** Show the heading for the currently selected project. */
  function renderProjectHeading() {
    setText("setupProject", projectName || "kein Projekt gewählt");
  }

  /** Load tool detection and the connection state of the selected project. */
  function refresh() {
    if (busy) return;
    setBusy(true);
    renderProjectHeading();
    setText("setupState", "Prüfe …");

    const detect = api.detectAiTools();
    const connection = projectId
      ? api.getProjectConnection(projectId)
      : Promise.resolve(null);

    Promise.all([detect, connection])
      .then(function (results) {
        renderTools(results[0]);
        const state = results[1];
        renderFiles(state ? state.configFiles : []);

        if (!projectId) {
          setText("setupState", "Links ein Projekt wählen, um es zu verbinden.");
        } else if (state && state.initialized) {
          setText(
            "setupState",
            "Dieses Projekt ist bereits eingerichtet. Erneutes Verbinden erneuert die Konfiguration."
          );
        } else {
          setText(
            "setupState",
            "Dieses Projekt ist noch nicht eingerichtet. „Projekt verbinden“ legt die Konfiguration an."
          );
        }
        setBusy(false);
      })
      .catch(function (error) {
        setText("setupState", message(error));
        setBusy(false);
      });
  }

  /** Whether the user asked for a full index rebuild. */
  function wantsScan() {
    const box = el("setupScan");
    return box ? box.checked : true;
  }

  /** Warn that a scan takes real time, so nobody thinks the window froze. */
  function scanHint(many) {
    if (!wantsScan()) return "";
    const what = many ? "Die Projekte werden" : "Das Projekt wird";
    return " " + what + " neu indiziert — das dauert bei großen Ordnern einige Minuten.";
  }

  /** Empty the progress list. */
  function clearProgress() {
    clear(el("setupProgress"));
  }

  /** Show the running seconds count, so the window never looks frozen. */
  function tickActivity() {
    const label = el("setupActivityTime");
    if (!label) return;
    const seconds = Math.floor((Date.now() - activityStart) / 1000);
    label.textContent = seconds + " s";
  }

  /** Start the animated activity bar and the elapsed-time counter. */
  function startActivity() {
    const box = el("setupActivity");
    if (box) box.hidden = false;
    activityStart = Date.now();
    tickActivity();
    if (activityTimer) window.clearInterval(activityTimer);
    activityTimer = window.setInterval(tickActivity, 1000);
  }

  /** Stop the activity bar and the counter. */
  function stopActivity() {
    if (activityTimer) {
      window.clearInterval(activityTimer);
      activityTimer = null;
    }
    const box = el("setupActivity");
    if (box) box.hidden = true;
  }

  /** Patch one row of the progress list from a backend progress event. */
  function onProgress(progress) {
    const host = el("setupProgress");
    if (!host || !progress) return;
    const id = "setupProgressRow" + progress.index;
    let row = document.getElementById(id);
    if (!row) {
      row = make("div", "setup-progress-row");
      row.id = id;
      row.appendChild(make("span", "pip", "•"));
      row.appendChild(make("span", "name", progress.displayName));
      row.appendChild(make("span", "pos", (progress.index + 1) + "/" + progress.total));
      host.appendChild(row);
    }
    if (progress.finished) {
      row.className = "setup-progress-row " + (progress.succeeded ? "done" : "failed");
      row.firstChild.textContent = progress.succeeded ? "✓" : "×";
    } else {
      row.className = "setup-progress-row active";
      row.firstChild.textContent = "•";
    }
  }

  /** Connect every registered project, one after another. */
  function connectAll() {
    if (busy) return;
    setBusy(true);
    clearProgress();
    startActivity();
    setText("setupState", "Verbinde alle Projekte …" + scanHint(true));

    api
      .connectAllProjects(wantsScan())
      .then(function (outcomes) {
        const failed = outcomes.filter(function (o) { return !o.succeeded; });
        if (failed.length === 0) {
          setText("setupState", outcomes.length + " Projekte verbunden.");
        } else {
          const lines = failed.map(function (o) {
            return o.message + (o.details ? "\n" + o.details : "");
          });
          setText(
            "setupState",
            (outcomes.length - failed.length) + " von " + outcomes.length +
              " verbunden. Nicht geklappt hat:\n\n" + lines.join("\n\n")
          );
        }
        stopActivity();
        setBusy(false);
        if (projectId) {
          api.getProjectConnection(projectId)
            .then(function (state) { renderFiles(state ? state.configFiles : []); })
            .catch(function () { /* Anzeige bleibt stehen */ });
        }
      })
      .catch(function (error) {
        stopActivity();
        setText("setupState", message(error));
        setBusy(false);
      });
  }

  /** Run `projectatlas init` in the selected project through the bundled binary. */
  function connect() {
    if (busy || !projectId) return;
    setBusy(true);
    clearProgress();
    startActivity();
    setText("setupState", "Verbinde …" + scanHint(false));

    api
      .connectProject(projectId, wantsScan())
      .then(function (outcome) {
        stopActivity();
        renderFiles(outcome.configFiles);
        const detail = outcome.details ? "\n\n" + outcome.details : "";
        setText("setupState", outcome.message + detail);
        setBusy(false);
      })
      .catch(function (error) {
        stopActivity();
        setText("setupState", message(error));
        setBusy(false);
      });
  }

  /** Show the setup panel. */
  function open() {
    const overlay = el("setupOverlay");
    if (!overlay) return;
    overlay.hidden = false;
    open_ = true;
    refresh();
  }

  /** Hide the setup panel. */
  function close() {
    const overlay = el("setupOverlay");
    if (overlay) overlay.hidden = true;
    open_ = false;
  }

  /** Record which project the dashboard shows, refreshing the panel when it is open. */
  function setProject(id, name) {
    if (id === projectId && name === projectName) return;
    projectId = id || null;
    projectName = name || null;
    if (open_) {
      refresh();
    } else {
      renderProjectHeading();
    }
  }

  /** Wire the sidebar button, the close button, and the two actions. */
  function wire() {
    const button = el("btnSetup");
    if (button) button.addEventListener("click", open);
    const closeBtn = el("setupCloseBtn");
    if (closeBtn) closeBtn.addEventListener("click", close);
    const connectBtn = el("setupConnectBtn");
    if (connectBtn) connectBtn.addEventListener("click", connect);
    const connectAllBtn = el("setupConnectAllBtn");
    if (connectAllBtn) connectAllBtn.addEventListener("click", connectAll);

    api.listen("setup-progress", function (event) {
      onProgress(event && event.payload);
    });

    const overlay = el("setupOverlay");
    if (overlay) {
      overlay.addEventListener("click", function (event) {
        if (event.target === overlay && !busy) close();
      });
    }
    document.addEventListener("keydown", function (event) {
      // Waehrend eines Laufs nicht schliessen: sonst waere unklar, ob er noch laeuft.
      if (event.key === "Escape" && !busy) close();
    });
  }

  return {
    wire: wire,
    open: open,
    close: close,
    setProject: setProject
  };
})();
