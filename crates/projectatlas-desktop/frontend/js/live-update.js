/* Purpose: Receive the backend's change events and patch only what changed.
   The backend emits an event only when a payload's fingerprint actually differs,
   so every event that arrives here is a real change. Nothing in this file reloads
   the page, replaces the shell, or touches the sidebar selection. */

window.PAD = window.PAD || {};

window.PAD.liveUpdate = (function () {
  "use strict";

  const api = window.PAD.api;

  /** Callbacks supplied by main.js, so this module stays free of app state. */
  let handlers = {
    isActive: function () { return false; },
    onOverview: function () {},
    onTrend: function () {},
    onActivity: function () {},
    onBadges: function () {}
  };

  /** Ignore a payload that belongs to a project the user has since left. */
  function forActiveProject(callback) {
    return function (event) {
      const payload = event && event.payload;
      if (!payload || !handlers.isActive(payload.projectId)) return;
      callback(payload.data);
    };
  }

  /** Subscribe to every backend event. */
  function start(nextHandlers) {
    handlers = Object.assign(handlers, nextHandlers || {});
    return Promise.all([
      api.listen("token-overview-updated", forActiveProject(function (data) {
        handlers.onOverview(data);
      })),
      api.listen("token-trend-updated", forActiveProject(function (data) {
        handlers.onTrend(data);
      })),
      api.listen("token-activity-updated", forActiveProject(function (data) {
        handlers.onActivity(data);
      })),
      api.listen("project-badges-updated", function (event) {
        handlers.onBadges(event && event.payload);
      })
    ]);
  }

  return {
    start: start
  };
})();
