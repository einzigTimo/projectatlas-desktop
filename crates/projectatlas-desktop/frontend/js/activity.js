/* Purpose: Render the activity log — the "wodurch" and "wann" of a single call.
   Rows carry a real timestamp (created_at_epoch), formatted German-style, so the
   log answers "wann" precisely instead of only in rollup periods. */

window.PAD = window.PAD || {};

window.PAD.activity = (function () {
  "use strict";

  const fmt = window.PAD.format;

  /** Build the descriptive middle column of one row. */
  function describe(entry) {
    const cell = document.createElement("span");
    cell.className = "p";

    const command = document.createElement("span");
    command.className = "cmd";
    command.textContent = entry.command;
    cell.appendChild(command);

    const detail = entry.path || entry.query;
    if (detail) {
      cell.appendChild(document.createTextNode(" " + fmt.shortPath(detail, 90)));
    }
    cell.title = [entry.path, entry.query, entry.provider + " / " + entry.model, entry.bucket]
      .filter(Boolean)
      .join("\n");
    return cell;
  }

  /** Render the whole activity list from one backend payload. */
  function render(entries) {
    const host = document.getElementById("activityList");
    if (!host) return;
    host.textContent = "";
    const rows = entries || [];
    if (rows.length === 0) {
      const empty = document.createElement("div");
      empty.className = "state-note";
      const head = document.createElement("b");
      head.textContent = "Noch keine Aufrufe aufgezeichnet";
      empty.appendChild(head);
      empty.appendChild(
        document.createTextNode(
          "Sobald ein KI-Werkzeug ProjectAtlas in diesem Projekt benutzt, erscheinen die Aufrufe hier."
        )
      );
      host.appendChild(empty);
      return;
    }

    rows.forEach(function (entry) {
      const row = document.createElement("div");
      row.className = "activity-row";

      const time = document.createElement("span");
      time.className = "t";
      time.textContent = fmt.time(entry.createdAtEpoch);
      time.title = fmt.dateTime(entry.createdAtEpoch);

      const saved = document.createElement("span");
      const value = typeof entry.saved === "number" ? entry.saved : 0;
      saved.className = "saved" + (value < 0 ? " neg" : "");
      saved.textContent = (value > 0 ? "+" : "") + fmt.int(value);

      row.appendChild(time);
      row.appendChild(describe(entry));
      row.appendChild(saved);
      host.appendChild(row);
    });
  }

  /** Show or clear the activity panel's note. */
  function setNote(message, isError) {
    const note = document.getElementById("activityNote");
    if (!note) return;
    if (!message) {
      note.hidden = true;
      return;
    }
    note.textContent = "";
    note.className = "state-note" + (isError ? " error" : "");
    const head = document.createElement("b");
    head.textContent = isError ? "Aktivität nicht lesbar" : "Nichts anzuzeigen";
    note.appendChild(head);
    note.appendChild(document.createTextNode(message));
    note.hidden = false;
  }

  return {
    render: render,
    setNote: setNote
  };
})();
