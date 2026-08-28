/* Purpose: Umschalter zwischen dunklem und hellem Design.

   Laeuft absichtlich als erstes, blockierendes Skript im <head>: das Design steht
   damit vor dem ersten Zeichnen fest und das Fenster blitzt beim Start nicht kurz
   dunkel auf. Gewechselt wird nur ein Attribut am <html>-Element; alle Farben
   liegen als CSS-Variablen in app.css, sodass keine Regel doppelt gepflegt wird. */

window.PAD = window.PAD || {};

window.PAD.theme = (function () {
  "use strict";

  /** Schluessel der gemerkten Wahl im lokalen Speicher der WebView. */
  const STORAGE_KEY = "projectatlas.desktop.theme";
  /** Design, das ohne gemerkte Wahl gilt. */
  const DEFAULT_THEME = "dark";

  /** Gemerkte Wahl lesen; ein gesperrter Speicher darf den Start nicht verhindern. */
  function stored() {
    try {
      return window.localStorage.getItem(STORAGE_KEY);
    } catch (error) {
      return null;
    }
  }

  /** Wahl merken; ein gesperrter Speicher darf den Wechsel nicht verhindern. */
  function remember(theme) {
    try {
      window.localStorage.setItem(STORAGE_KEY, theme);
    } catch (error) {
      /* Ohne Speicher gilt die Wahl nur fuer diese Sitzung. */
    }
  }

  /** Unbekannte Werte auf ein gueltiges Design zurechtbiegen. */
  function normalize(theme) {
    return theme === "light" ? "light" : "dark";
  }

  /** Aktuell gesetztes Design. */
  function current() {
    return normalize(document.documentElement.getAttribute("data-theme"));
  }

  /** Knopfbeschriftung an das Design anpassen, falls er schon im Baum steht. */
  function label() {
    const button = document.getElementById("btnTheme");
    if (!button) return;
    const light = current() === "light";
    button.textContent = light ? "☾" : "☀";
    button.title = light ? "Dunkles Design" : "Helles Design";
    button.setAttribute("aria-label", button.title);
  }

  /** Design setzen und merken. */
  function apply(theme) {
    const next = normalize(theme);
    document.documentElement.setAttribute("data-theme", next);
    remember(next);
    label();
  }

  /** Zwischen hell und dunkel wechseln. */
  function toggle() {
    apply(current() === "light" ? "dark" : "light");
  }

  /** Den Knopf in der Seitenleiste anschliessen. */
  function wire() {
    const button = document.getElementById("btnTheme");
    if (button) button.addEventListener("click", toggle);
    label();
  }

  document.documentElement.setAttribute("data-theme", normalize(stored() || DEFAULT_THEME));

  return {
    apply: apply,
    toggle: toggle,
    current: current,
    wire: wire
  };
})();
