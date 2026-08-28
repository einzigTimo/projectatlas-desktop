/* Purpose: The update screen — version, check result, changelog, install.
   Reachable from the small gear in the sidebar footer rather than as a main tab,
   because it is about the app itself, not about the selected project.

   Nothing installs on its own: the user sees what changed and picks the moment. */

window.PAD = window.PAD || {};

window.PAD.update = (function () {
  "use strict";

  const api = window.PAD.api;
  const fmt = window.PAD.format;

  /** Last status returned by a check, so the install button knows what it offers. */
  let lastStatus = null;
  /** Whether a check or install is currently running. */
  let busy = false;

  /** Return one element by id. */
  function el(id) {
    return document.getElementById(id);
  }

  /** Write text into one element by id. */
  function setText(id, text) {
    const node = el(id);
    if (node) node.textContent = text;
  }

  /** Enable or disable both action buttons. */
  function setBusy(next) {
    busy = next;
    const check = el("updateCheckBtn");
    const install = el("updateInstallBtn");
    if (check) check.disabled = busy;
    if (install) {
      install.disabled = busy || !(lastStatus && lastStatus.available);
    }
  }

  /** Show the update panel. */
  function open() {
    const overlay = el("updateOverlay");
    if (!overlay) return;
    overlay.hidden = false;
    // Die eigene Version unabhaengig von der Pruefung setzen: schlaegt der Abruf
    // fehl, stand hier vorher dauerhaft "Version -".
    api
      .appVersion()
      .then(function (version) { setText("updateCurrentVersion", "Version " + version); })
      .catch(function () { /* Ueberschrift bleibt wie sie ist */ });
    if (!lastStatus) check();
  }

  /** Hide the update panel. */
  function close() {
    const overlay = el("updateOverlay");
    if (overlay) overlay.hidden = true;
  }

  /** Render one check result. */
  function render(status) {
    lastStatus = status;
    setText("updateCurrentVersion", "Version " + status.currentVersion);

    const notes = el("updateNotes");
    if (notes) {
      notes.textContent = "";
      notes.hidden = true;
    }

    if (status.unconfiguredReason) {
      setText("updateState", status.unconfiguredReason);
      setBusy(false);
      return;
    }

    if (!status.available) {
      setText("updateState", "Diese Ausgabe ist aktuell. Geprüft um " + fmt.clockNow() + ".");
      setBusy(false);
      return;
    }

    setText(
      "updateState",
      "Version " + status.version + " steht bereit" +
        (status.published ? " (veröffentlicht " + status.published + ")" : "") + "."
    );

    if (notes && status.notes) {
      notes.textContent = status.notes;
      notes.hidden = false;
    }
    setBusy(false);
  }

  /** Ask the backend whether a newer version exists. */
  function check() {
    if (busy) return;
    setBusy(true);
    setText("updateState", "Suche nach Aktualisierungen …");
    api
      .checkForUpdate()
      .then(render)
      .catch(function (error) {
        lastStatus = null;
        setText("updateState", error && error.message ? error.message : String(error));
        setBusy(false);
      });
  }

  /** Download and install the offered update, then let the app restart itself. */
  function install() {
    if (busy || !lastStatus || !lastStatus.available) return;
    setBusy(true);
    setText("updateState", "Lade Aktualisierung …");
    const bar = el("updateProgressBar");
    const wrap = el("updateProgress");
    if (wrap) wrap.hidden = false;
    if (bar) bar.style.width = "0%";

    api
      .installUpdate()
      .then(function () {
        setText("updateState", "Installiert. Die Anwendung startet neu …");
      })
      .catch(function (error) {
        if (wrap) wrap.hidden = true;
        setText("updateState", error && error.message ? error.message : String(error));
        setBusy(false);
      });
  }

  /** Patch the progress bar from a backend progress event. */
  function onProgress(progress) {
    const bar = el("updateProgressBar");
    if (!bar || !progress) return;
    if (progress.finished) {
      bar.style.width = "100%";
      setText("updateState", "Heruntergeladen, Installation läuft …");
      return;
    }
    if (progress.total) {
      const share = Math.max(0, Math.min(1, progress.downloaded / progress.total));
      bar.style.width = (share * 100).toFixed(1) + "%";
      setText(
        "updateState",
        "Lade Aktualisierung … " + fmt.percent(share, 0)
      );
    }
  }

  /** Wire the gear button, the close button, and the two actions. */
  function wire() {
    const gear = el("btnUpdate");
    if (gear) gear.addEventListener("click", open);
    const closeBtn = el("updateCloseBtn");
    if (closeBtn) closeBtn.addEventListener("click", close);
    const checkBtn = el("updateCheckBtn");
    if (checkBtn) checkBtn.addEventListener("click", check);
    const installBtn = el("updateInstallBtn");
    if (installBtn) installBtn.addEventListener("click", install);

    const overlay = el("updateOverlay");
    if (overlay) {
      overlay.addEventListener("click", function (event) {
        if (event.target === overlay) close();
      });
    }
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") close();
    });

    api.listen("update-progress", function (event) {
      onProgress(event && event.payload);
    });
  }

  return {
    wire: wire,
    open: open,
    close: close
  };
})();
