/* Purpose: Boot the dashboard and own the small amount of app state.
   Switching a project or a tab refills the content area through the same render
   functions the live updates use — there is no page reload anywhere in this app. */

(function () {
  "use strict";

  const api = window.PAD.api;
  const projects = window.PAD.projects;
  const overview = window.PAD.overview;
  const trend = window.PAD.trend;
  const activity = window.PAD.activity;
  const atlas = window.PAD.atlas;
  const liveUpdate = window.PAD.liveUpdate;
  const update = window.PAD.update;
  const setup = window.PAD.setup;
  const theme = window.PAD.theme;

  /** Id of the project currently displayed. */
  let activeProjectId = null;
  /** Calendar grouping the trend panel shows. */
  let trendWindow = "day";

  /** Turn a backend error into a readable German sentence. */
  function message(error) {
    if (!error) return "Unbekannter Fehler.";
    if (typeof error === "string") return error;
    if (error.message) return error.message;
    return String(error);
  }

  /** Find the display name of the active project inside one list payload. */
  function activeProjectName(payload) {
    if (!payload || !payload.projects) return null;
    const match = payload.projects.find(function (project) {
      return project.id === activeProjectId;
    });
    return match ? match.displayName : null;
  }

  /** Apply one project list payload to the sidebar and the active selection. */
  function applyProjectList(payload) {
    activeProjectId = (payload && payload.activeProjectId) || null;
    projects.render(payload);
    setup.setProject(activeProjectId, activeProjectName(payload));
    return payload;
  }

  /** Load every panel for the active project. */
  function loadActiveProject() {
    if (!activeProjectId) {
      overview.setNote(
        "Kein Projekt ausgewählt. Über „Scan“ oder „+ Ordner“ links ein ProjectAtlas-Projekt hinzufügen.",
        false
      );
      trend.setNote("Kein Projekt ausgewählt.", false);
      activity.setNote("Kein Projekt ausgewählt.", false);
      atlas.draw(null);
      return Promise.resolve();
    }
    const projectId = activeProjectId;

    const overviewLoad = api
      .getOverview(projectId)
      .then(function (data) {
        if (projectId !== activeProjectId) return;
        overview.setNote(null);
        overview.render(data, { flash: false });
      })
      .catch(function (error) {
        if (projectId !== activeProjectId) return;
        overview.setNote(message(error), true);
      });

    const trendLoad = api
      .getTrend(projectId, trendWindow)
      .then(function (data) {
        if (projectId !== activeProjectId) return;
        trend.setNote(null);
        trend.render(data);
      })
      .catch(function (error) {
        if (projectId !== activeProjectId) return;
        trend.setNote(message(error), true);
      });

    const activityLoad = api
      .getRecentActivity(projectId)
      .then(function (entries) {
        if (projectId !== activeProjectId) return;
        activity.setNote(null);
        activity.render(entries);
      })
      .catch(function (error) {
        if (projectId !== activeProjectId) return;
        activity.setNote(message(error), true);
      });

    const atlasLoad = api
      .getAtlasMap(projectId)
      .then(function (view) {
        if (projectId !== activeProjectId) return;
        atlas.draw(view);
      })
      .catch(function () {
        if (projectId !== activeProjectId) return;
        atlas.draw(null);
      });

    return Promise.all([overviewLoad, trendLoad, activityLoad, atlasLoad]);
  }

  /** Refresh the sidebar badges. */
  function loadBadges() {
    return api
      .getProjectBadges()
      .then(function (badges) {
        projects.renderBadges(badges);
      })
      .catch(function () {
        /* Badges are decoration; a failure must not disturb the dashboard. */
      });
  }

  /** Switch the displayed project. */
  function selectProject(projectId) {
    if (projectId === activeProjectId) return;
    api
      .switchActiveProject(projectId)
      .then(applyProjectList)
      .then(loadActiveProject)
      .then(loadBadges)
      .catch(function (error) {
        overview.setNote(message(error), true);
      });
  }

  /** Wire the sidebar buttons. */
  function wireSidebar() {
    const rescanButton = document.getElementById("btnRescan");
    const addButton = document.getElementById("btnAdd");

    rescanButton.addEventListener("click", function () {
      rescanButton.disabled = true;
      api
        .rescanProjects()
        .then(applyProjectList)
        .then(loadActiveProject)
        .then(loadBadges)
        .catch(function (error) {
          overview.setNote(message(error), true);
        })
        .then(function () {
          rescanButton.disabled = false;
        });
    });

    addButton.addEventListener("click", function () {
      api
        .pickFolder()
        .then(function (folder) {
          if (!folder) return null;
          return api.addProjectManual(folder).then(applyProjectList).then(loadActiveProject);
        })
        .then(loadBadges)
        .catch(function (error) {
          overview.setNote(message(error), true);
        });
    });

    projects.setSelectHandler(selectProject);
  }

  /** Wire the tab strip. */
  function wireTabs() {
    document.getElementById("tabs").addEventListener("click", function (event) {
      const button = event.target.closest(".tab");
      if (!button) return;
      const tabs = document.querySelectorAll(".tab");
      Array.prototype.forEach.call(tabs, function (tab) {
        tab.classList.toggle("active", tab === button);
      });
      const panels = document.querySelectorAll(".view-panel");
      Array.prototype.forEach.call(panels, function (panel) {
        panel.classList.toggle("active", panel.id === "view-" + button.dataset.view);
      });
    });
  }

  /** Wire the trend window switch. */
  function wireWindowSwitch() {
    document.getElementById("windowSwitch").addEventListener("click", function (event) {
      const button = event.target.closest("button");
      if (!button || button.dataset.window === trendWindow) return;
      trendWindow = button.dataset.window;
      trend.setWindow(trendWindow);
      if (!activeProjectId) return;
      const projectId = activeProjectId;
      api
        .getTrend(projectId, trendWindow)
        .then(function (data) {
          if (projectId !== activeProjectId) return;
          trend.setNote(null);
          trend.render(data);
        })
        .catch(function (error) {
          if (projectId !== activeProjectId) return;
          trend.setNote(message(error), true);
        });
    });
  }

  /** Wire the "measure for real" button in the calibration panel.

     Deliberately a button rather than something automatic: the measurement tokenizes
     every indexed file, so it must be the user's decision, not a side effect of opening
     a tab. */
  function wireCalibration() {
    const button = document.getElementById("calibBtn");
    const picker = document.getElementById("calibTokenizer");
    if (!button) return;

    button.addEventListener("click", function () {
      if (!activeProjectId) return;
      const projectId = activeProjectId;
      const tokenizer = picker ? picker.value : "o200k_base";
      button.disabled = true;
      const previous = button.textContent;
      button.textContent = "Messe …";

      api
        .calibrateProject(projectId, tokenizer)
        .then(function (data) {
          if (projectId !== activeProjectId) return;
          overview.render(data, { flash: true });
        })
        .catch(function (error) {
          overview.setNote(message(error), true);
        })
        .then(function () {
          button.disabled = false;
          button.textContent = previous;
        });
    });
  }

  /** Subscribe to the silent background updates. */
  function wireLiveUpdates() {
    liveUpdate.start({
      isActive: function (projectId) {
        return projectId === activeProjectId;
      },
      onOverview: function (data) {
        overview.setNote(null);
        overview.render(data, { flash: true });
      },
      onTrend: function (data) {
        trend.setNote(null);
        trend.render(data);
      },
      onActivity: function (entries) {
        activity.setNote(null);
        activity.render(entries);
      },
      onBadges: function (badges) {
        projects.renderBadges(badges);
      }
    });
  }

  /** Start the application. */
  function boot() {
    wireSidebar();
    wireTabs();
    theme.wire();
    atlas.wire();
    update.wire();
    setup.wire();
    wireCalibration();

    // Die Statuszeile fragt die Version beim Programm nach, statt sie im Markup
    // stehen zu haben - sonst behauptet sie nach einem Update die alte Ausgabe.
    api
      .appVersion()
      .then(function (version) {
        const node = document.getElementById("appVersion");
        if (node) node.textContent = "ProjectAtlas Desktop v" + version;
      })
      .catch(function () { /* Statuszeile bleibt ohne Nummer */ });
    wireWindowSwitch();
    trend.setWindow(trendWindow);
    wireLiveUpdates();

    api
      .listProjects()
      .then(function (payload) {
        applyProjectList(payload);
        if (payload && payload.projects && payload.projects.length === 0) {
          return api.rescanProjects().then(applyProjectList);
        }
        return payload;
      })
      .then(loadActiveProject)
      .then(loadBadges)
      .catch(function (error) {
        overview.setNote(message(error), true);
      });
  }

  boot();
})();
