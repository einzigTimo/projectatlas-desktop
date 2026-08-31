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
  /** Complete unfiltered project list; filtering must never replace global state. */
  let projectCatalog = { projects: [], activeProjectId: null };
  /** Free-text Purpose query currently applied to the sidebar. */
  let purposeFilter = "";
  /** Invalidates an older filter response when the user keeps typing. */
  let purposeFilterSerial = 0;
  /** Short debounce for the local-purpose search command. */
  let purposeFilterTimer = null;
  /** Prevents overlapping multi-project database searches. */
  let purposeFilterInFlight = false;
  /** Remembers that the newest text must run once the active search completes. */
  let purposeFilterQueued = false;

  /** Turn a backend error into a readable German sentence. */
  function message(error) {
    if (!error) return "Unbekannter Fehler.";
    if (typeof error === "string") return error;
    if (error.message) return error.message;
    return String(error);
  }

  /** Find the display name of the active project inside one list payload. */
  function activeProject() {
    const match = projectCatalog.projects.find(function (project) {
      return project.id === activeProjectId;
    });
    return match || null;
  }

  /** Render either the full catalog or one filtered result without changing selection. */
  function renderProjectList(payload, query) {
    const visibleProjects = (payload && payload.projects) || [];
    projects.render(
      { projects: visibleProjects, activeProjectId: activeProjectId },
      { activeProject: activeProject(), filterQuery: query || "" }
    );
  }

  /** Refresh the visible sidebar for the current Purpose text. */
  function refreshPurposeFilter() {
    const query = purposeFilter;
    const serial = ++purposeFilterSerial;
    if (!query) {
      renderProjectList(projectCatalog, "");
      projects.setFilterStatus("");
      return Promise.resolve(projectCatalog);
    }
    if (query.length < 2) {
      renderProjectList(projectCatalog, "");
      projects.setFilterStatus("Mindestens 2 Zeichen eingeben.");
      return Promise.resolve(projectCatalog);
    }
    if (purposeFilterInFlight) {
      purposeFilterQueued = true;
      return Promise.resolve(projectCatalog);
    }

    purposeFilterInFlight = true;
    projects.setFilterStatus("Suche …");
    return api
      .listProjectsByPurpose(query)
      .then(function (payload) {
        if (serial !== purposeFilterSerial || query !== purposeFilter) return projectCatalog;
        const count = (payload && payload.projects && payload.projects.length) || 0;
        renderProjectList(payload, query);
        projects.setFilterStatus(fmtFilterCount(count));
        return projectCatalog;
      })
      .catch(function (error) {
        if (serial === purposeFilterSerial && query === purposeFilter) {
          projects.setFilterStatus(message(error), true);
        }
        // A decorative filter failure must not block project switching or panel refreshes.
        return projectCatalog;
      })
      .then(function (result) {
        purposeFilterInFlight = false;
        if (!purposeFilterQueued) return result;
        purposeFilterQueued = false;
        return refreshPurposeFilter();
      });
  }

  /** German result count kept here so projects.js only owns rendering. */
  function fmtFilterCount(count) {
    return count === 1 ? "1 Treffer" : String(count) + " Treffer";
  }

  /** Apply one project list payload to the sidebar and the active selection. */
  function applyProjectList(payload) {
    projectCatalog = {
      projects: (payload && payload.projects) || [],
      activeProjectId: (payload && payload.activeProjectId) || null
    };
    activeProjectId = projectCatalog.activeProjectId;
    const active = activeProject();
    setup.setProject(activeProjectId, active ? active.displayName : null);
    return refreshPurposeFilter().then(function () { return payload; });
  }

  /** Load every panel for the active project. */
  function loadActiveProject() {
    if (!activeProjectId) {
      overview.setNote(
        "Kein Projekt ausgewählt. Über „Scan“ oder „+ Ordner“ links ein ProjectAtlas-Projekt hinzufügen.",
        false
      );
      trend.clear();
      trend.setNote("Kein Projekt ausgewählt.", false);
      activity.clear();
      activity.setNote("Kein Projekt ausgewählt.", false);
      atlas.draw(null, null);
      return Promise.resolve();
    }
    const projectId = activeProjectId;
    overview.setLoading();
    trend.setLoading();
    activity.setLoading();
    atlas.setLoading(projectId);

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
        atlas.draw(view, projectId);
      })
      .catch(function () {
        if (projectId !== activeProjectId) return;
        atlas.draw(null, projectId);
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
    const filterInput = document.getElementById("purposeFilter");
    const filterClear = document.getElementById("purposeFilterClear");

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

    /** Adopt the input value and refresh now or after a brief typing pause. */
    function updatePurposeFilter(immediate) {
      purposeFilter = filterInput ? filterInput.value.trim() : "";
      purposeFilterSerial += 1;
      if (filterClear) filterClear.disabled = purposeFilter.length === 0;
      if (purposeFilterTimer !== null) window.clearTimeout(purposeFilterTimer);
      purposeFilterTimer = null;
      if (immediate || !purposeFilter) {
        refreshPurposeFilter();
        return;
      }
      purposeFilterTimer = window.setTimeout(function () {
        purposeFilterTimer = null;
        refreshPurposeFilter();
      }, 300);
    }

    if (filterInput) {
      filterInput.addEventListener("input", function () { updatePurposeFilter(false); });
      filterInput.addEventListener("keydown", function (event) {
        if (event.key !== "Enter") return;
        event.preventDefault();
        updatePurposeFilter(true);
      });
    }
    if (filterClear) {
      filterClear.disabled = true;
      filterClear.addEventListener("click", function () {
        if (filterInput) {
          filterInput.value = "";
          filterInput.focus();
        }
        updatePurposeFilter(true);
      });
    }
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
    const buttons = [
      document.getElementById("calibBtn"),
      document.getElementById("calibrationHintBtn")
    ].filter(function (button) { return !!button; });
    const picker = document.getElementById("calibTokenizer");
    if (buttons.length === 0) return;

    function calibrate() {
      if (!activeProjectId) return;
      const projectId = activeProjectId;
      const tokenizer = picker ? picker.value : "o200k_base";
      const previous = buttons.map(function (button) { return button.textContent; });
      overview.setCalibrationStatus("Kalibrierung läuft …", false);
      buttons.forEach(function (button) {
        button.disabled = true;
        button.textContent = "Messe …";
      });

      api
        .calibrateProject(projectId, tokenizer)
        .then(function (data) {
          if (projectId !== activeProjectId) return;
          overview.render(data, { flash: true });
          overview.setCalibrationStatus("Kalibrierung abgeschlossen.", false);
        })
        .catch(function (error) {
          if (projectId !== activeProjectId) return;
          overview.setCalibrationStatus(message(error), true);
        })
        .then(function () {
          buttons.forEach(function (button, index) {
            button.disabled = false;
            button.textContent = previous[index];
          });
        });
    }

    buttons.forEach(function (button) {
      button.addEventListener("click", calibrate);
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
        const isEmpty = payload && payload.projects && payload.projects.length === 0;
        return applyProjectList(payload).then(function () {
          return isEmpty ? api.rescanProjects().then(applyProjectList) : payload;
        });
      })
      .then(loadActiveProject)
      .then(loadBadges)
      .catch(function (error) {
        overview.setNote(message(error), true);
      });
  }

  boot();
})();
