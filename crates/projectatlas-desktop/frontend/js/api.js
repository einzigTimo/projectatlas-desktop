/* Purpose: The single place that talks to the Rust backend.
   Uses the global Tauri bridge (withGlobalTauri) so the frontend needs no bundler
   and no npm dependencies — plain files the WebView loads directly. */

window.PAD = window.PAD || {};

window.PAD.api = (function () {
  "use strict";

  /** Return the Tauri core namespace, or null when running outside the app shell. */
  function core() {
    return (window.__TAURI__ && window.__TAURI__.core) || null;
  }

  /** Return the Tauri event namespace, or null when running outside the app shell. */
  function events() {
    return (window.__TAURI__ && window.__TAURI__.event) || null;
  }

  /** Return the Tauri dialog plugin namespace, or null when unavailable. */
  function dialog() {
    return (window.__TAURI__ && window.__TAURI__.dialog) || null;
  }

  /** Invoke one backend command, rejecting with a readable message. */
  function invoke(command, args) {
    const bridge = core();
    if (!bridge) {
      return Promise.reject(new Error("Die Verbindung zur Anwendung steht nicht zur Verfügung."));
    }
    return bridge.invoke(command, args || {});
  }

  /** Subscribe to one backend event; resolves to an unlisten function. */
  function listen(event, handler) {
    const bridge = events();
    if (!bridge) return Promise.resolve(function () {});
    return bridge.listen(event, handler);
  }

  /** Ask the user for a project folder, returning null when the dialog is cancelled. */
  function pickFolder() {
    const bridge = dialog();
    if (!bridge) {
      return Promise.reject(new Error("Der Ordner-Dialog steht nicht zur Verfügung."));
    }
    return bridge.open({
      directory: true,
      multiple: false,
      title: "ProjectAtlas-Projektordner wählen"
    });
  }

  return {
    invoke: invoke,
    listen: listen,
    pickFolder: pickFolder,
    listProjects: function () { return invoke("list_projects"); },
    rescanProjects: function () { return invoke("rescan_projects"); },
    addProjectManual: function (path) { return invoke("add_project_manual", { path: path }); },
    removeProject: function (projectId) { return invoke("remove_project", { projectId: projectId }); },
    switchActiveProject: function (projectId) { return invoke("switch_active_project", { projectId: projectId }); },
    getOverview: function (projectId) { return invoke("get_overview", { projectId: projectId }); },
    getTrend: function (projectId, window_) { return invoke("get_trend", { projectId: projectId, window: window_ }); },
    getRecentActivity: function (projectId, limit) { return invoke("get_recent_activity", { projectId: projectId, limit: limit || null }); },
    getAtlasMap: function (projectId) { return invoke("get_atlas_map", { projectId: projectId }); },
    getProjectBadges: function () { return invoke("get_project_badges"); },
    appVersion: function () { return invoke("app_version"); },
    checkForUpdate: function () { return invoke("check_for_update"); },
    installUpdate: function () { return invoke("install_update"); },
    detectAiTools: function () { return invoke("detect_ai_tools"); },
    getProjectConnection: function (projectId) { return invoke("get_project_connection", { projectId: projectId }); },
    connectProject: function (projectId, scan) { return invoke("connect_project", { projectId: projectId, scan: !!scan }); },
    connectAllProjects: function (scan) { return invoke("connect_all_projects", { scan: !!scan }); },
    calibrateProject: function (projectId, tokenizer) { return invoke("calibrate_project", { projectId: projectId, tokenizer: tokenizer }); }
  };
})();
