/* Purpose: German number, ratio, and date formatting used by every panel.
   Dates are always TT.MM.JJJJ and numbers always use the de-DE grouping, so the
   window never shows a US-style date or a bare dot-decimal anywhere. */

window.PAD = window.PAD || {};

window.PAD.format = (function () {
  "use strict";

  const DASH = "–";

  /** Format an integer with German thousands separators. */
  function int(value) {
    if (typeof value !== "number" || !isFinite(value)) return DASH;
    return Math.round(value).toLocaleString("de-DE");
  }

  /** Format a token count compactly (K/M) for tight table cells. */
  function tokens(value) {
    if (typeof value !== "number" || !isFinite(value)) return DASH;
    const abs = Math.abs(value);
    if (abs >= 1e6) return (value / 1e6).toFixed(2).replace(".", ",") + "M";
    if (abs >= 1e4) return (value / 1e3).toFixed(1).replace(".", ",") + "K";
    return int(value);
  }

  /** Format a 0..1 ratio as a German percentage, or a dash when unknown. */
  function percent(ratio, digits) {
    if (typeof ratio !== "number" || !isFinite(ratio)) return DASH;
    const places = typeof digits === "number" ? digits : 1;
    return (ratio * 100).toFixed(places).replace(".", ",") + " %";
  }

  /** Format a share of a total as a German percentage. */
  function share(part, total, digits) {
    if (!total) return DASH;
    return percent(part / total, digits);
  }

  /** Pad a number to two digits. */
  function pad2(value) {
    return String(value).padStart(2, "0");
  }

  /** Format Unix epoch seconds as TT.MM.JJJJ. */
  function date(epochSeconds) {
    if (typeof epochSeconds !== "number" || epochSeconds <= 0) return DASH;
    const d = new Date(epochSeconds * 1000);
    return pad2(d.getDate()) + "." + pad2(d.getMonth() + 1) + "." + d.getFullYear();
  }

  /** Format Unix epoch seconds as HH:MM:SS. */
  function time(epochSeconds) {
    if (typeof epochSeconds !== "number" || epochSeconds <= 0) return DASH;
    const d = new Date(epochSeconds * 1000);
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds());
  }

  /** Format Unix epoch seconds as TT.MM.JJJJ HH:MM. */
  function dateTime(epochSeconds) {
    if (typeof epochSeconds !== "number" || epochSeconds <= 0) return DASH;
    const d = new Date(epochSeconds * 1000);
    return date(epochSeconds) + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes());
  }

  /** Format the current wall clock as HH:MM:SS. */
  function clockNow() {
    return time(Math.floor(Date.now() / 1000));
  }

  /**
   * Turn a trend period key into a readable German label.
   * Accepts day (JJJJ-MM-TT), week (JJJJ-Wnn), month (JJJJ-MM), and year (JJJJ).
   */
  function periodLabel(period) {
    if (typeof period !== "string") return DASH;
    let match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(period);
    if (match) return match[3] + "." + match[2] + "." + match[1];
    match = /^(\d{4})-W(\d{1,2})$/.exec(period);
    if (match) return "KW " + match[2] + "/" + match[1];
    match = /^(\d{4})-(\d{2})$/.exec(period);
    if (match) return match[2] + "." + match[1];
    return period;
  }

  /** Shorten a long path from the left so the file name stays visible. */
  function shortPath(path, maxLength) {
    if (typeof path !== "string") return "";
    const limit = typeof maxLength === "number" ? maxLength : 64;
    if (path.length <= limit) return path;
    return "…" + path.slice(path.length - limit + 1);
  }

  return {
    DASH: DASH,
    int: int,
    tokens: tokens,
    percent: percent,
    share: share,
    date: date,
    time: time,
    dateTime: dateTime,
    clockNow: clockNow,
    periodLabel: periodLabel,
    shortPath: shortPath
  };
})();
