/* Purpose: Render the trend panel — the "wann" of the dashboard.
   The chart is an inline SVG built from the retained daily rollups, so there is no
   charting library, no CDN, and nothing the CSP has to allow. */

window.PAD = window.PAD || {};

window.PAD.trend = (function () {
  "use strict";

  const fmt = window.PAD.format;

  /** Chart geometry, matching the viewBox declared in index.html. */
  const CHART = { width: 700, height: 180, padL: 8, padR: 8, padT: 12, padB: 22 };

  /** Draw the savings line chart for one set of periods. */
  function drawChart(periods) {
    const svg = document.getElementById("trendSvg");
    if (!svg) return;
    svg.textContent = "";
    if (periods.length === 0) return;

    const innerW = CHART.width - CHART.padL - CHART.padR;
    const innerH = CHART.height - CHART.padT - CHART.padB;
    const maxSaved = Math.max.apply(
      null,
      periods.map(function (period) {
        return Math.max(0, period.saved);
      })
    ) * 1.15 || 1;
    const stepX = periods.length > 1 ? innerW / (periods.length - 1) : 0;

    const points = periods.map(function (period, index) {
      const x = CHART.padL + index * stepX;
      const y = CHART.padT + innerH - (Math.max(0, period.saved) / maxSaved) * innerH;
      return [x, y];
    });

    const namespace = "http://www.w3.org/2000/svg";

    for (let line = 0; line <= 3; line += 1) {
      const y = CHART.padT + (innerH / 3) * line;
      const grid = document.createElementNS(namespace, "line");
      grid.setAttribute("x1", String(CHART.padL));
      grid.setAttribute("y1", y.toFixed(1));
      grid.setAttribute("x2", String(CHART.width - CHART.padR));
      grid.setAttribute("y2", y.toFixed(1));
      grid.setAttribute("stroke", "var(--border-dim)");
      grid.setAttribute("stroke-width", "1");
      svg.appendChild(grid);
    }

    const linePath = points
      .map(function (point, index) {
        return (index === 0 ? "M" : "L") + point[0].toFixed(1) + "," + point[1].toFixed(1);
      })
      .join(" ");

    if (points.length > 1) {
      const area = document.createElementNS(namespace, "path");
      area.setAttribute(
        "d",
        linePath +
          " L" + points[points.length - 1][0].toFixed(1) + "," + (CHART.padT + innerH) +
          " L" + points[0][0].toFixed(1) + "," + (CHART.padT + innerH) + " Z"
      );
      area.setAttribute("fill", "var(--green)");
      area.setAttribute("opacity", "0.12");
      svg.appendChild(area);
    }

    const stroke = document.createElementNS(namespace, "path");
    stroke.setAttribute("d", linePath);
    stroke.setAttribute("fill", "none");
    stroke.setAttribute("stroke", "var(--green)");
    stroke.setAttribute("stroke-width", "2");
    stroke.setAttribute("stroke-linejoin", "round");
    stroke.setAttribute("stroke-linecap", "round");
    svg.appendChild(stroke);

    points.forEach(function (point, index) {
      const isLast = index === points.length - 1;
      const dot = document.createElementNS(namespace, "circle");
      dot.setAttribute("cx", point[0].toFixed(1));
      dot.setAttribute("cy", point[1].toFixed(1));
      dot.setAttribute("r", isLast ? "3.6" : "2.2");
      dot.setAttribute("fill", isLast ? "var(--yellow)" : "var(--panel)");
      dot.setAttribute("stroke", "var(--green)");
      dot.setAttribute("stroke-width", "1.4");
      svg.appendChild(dot);
    });

    periods.forEach(function (period, index) {
      const label = document.createElementNS(namespace, "text");
      label.setAttribute("x", (CHART.padL + index * stepX).toFixed(1));
      label.setAttribute("y", String(CHART.height - 6));
      label.setAttribute("font-size", "9");
      label.setAttribute("fill", "var(--muted)");
      label.setAttribute("text-anchor", "middle");
      label.setAttribute("font-family", "var(--font-ui)");
      label.textContent = fmt.periodLabel(period.period);
      svg.appendChild(label);
    });
  }

  /** Fill the period table below the chart, newest period first. */
  function drawTable(periods) {
    const body = document.getElementById("trendBody");
    if (!body) return;
    body.textContent = "";
    if (periods.length === 0) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 5;
      cell.textContent = "Für dieses Zeitfenster liegen noch keine Werte vor.";
      row.appendChild(cell);
      body.appendChild(row);
      return;
    }
    periods
      .slice()
      .reverse()
      .forEach(function (period) {
        const row = document.createElement("tr");
        const cells = [
          { text: fmt.periodLabel(period.period), cls: "" },
          { text: fmt.int(period.calls), cls: "num" },
          { text: fmt.tokens(period.without), cls: "num" },
          { text: fmt.tokens(period.saved), cls: "num " + (period.saved < 0 ? "neg" : "pos") },
          { text: fmt.percent(period.savingsRate), cls: "num " + (period.saved < 0 ? "neg" : "pos") }
        ];
        cells.forEach(function (spec) {
          const cell = document.createElement("td");
          if (spec.cls) cell.className = spec.cls;
          cell.textContent = spec.text;
          row.appendChild(cell);
        });
        body.appendChild(row);
      });
  }

  /** Fill the per-period savings-bucket breakdown supplied by the trend view. */
  function drawBucketTable(periods) {
    const body = document.getElementById("trendBucketBody");
    if (!body) return;
    body.textContent = "";

    let rowCount = 0;
    periods
      .slice()
      .reverse()
      .forEach(function (period) {
        (period.buckets || []).forEach(function (bucket) {
          rowCount += 1;
          const row = document.createElement("tr");
          const saved = bucket.saved;
          const providerModel = [bucket.provider, bucket.model]
            .filter(function (part) { return !!part; })
            .join(" / ");
          const cells = [
            { text: fmt.periodLabel(period.period), cls: "" },
            { text: bucket.bucket || "–", cls: "" },
            { text: providerModel || "–", cls: "" },
            { text: fmt.int(bucket.calls), cls: "num" },
            { text: fmt.tokens(saved), cls: "num " + (saved < 0 ? "neg" : "pos") },
            { text: fmt.percent(bucket.savingsRate), cls: "num " + (saved < 0 ? "neg" : "pos") }
          ];
          cells.forEach(function (spec) {
            const cell = document.createElement("td");
            if (spec.cls) cell.className = spec.cls;
            cell.textContent = spec.text;
            row.appendChild(cell);
          });
          body.appendChild(row);
        });
      });

    if (rowCount === 0) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 6;
      cell.textContent = "Für dieses Zeitfenster liegen noch keine Kategorie-Werte vor.";
      row.appendChild(cell);
      body.appendChild(row);
    }
  }

  /** Render chart and table from one backend payload. */
  function render(data) {
    const periods = (data && data.periods) || [];
    drawChart(periods);
    drawTable(periods);
    drawBucketTable(periods);
    const limitNote = document.getElementById("trendLimitNote");
    if (limitNote) {
      limitNote.textContent = data && data.truncated
        ? "Begrenzter Ausschnitt: Die neuesten Perioden und maximal 240 Bucket-Zeilen werden angezeigt."
        : "";
      limitNote.hidden = !(data && data.truncated);
    }
  }

  /** Show or clear the trend panel's note. */
  function setNote(message, isError, heading) {
    const note = document.getElementById("trendNote");
    if (!note) return;
    if (!message) {
      note.hidden = true;
      return;
    }
    note.textContent = "";
    note.className = "state-note" + (isError ? " error" : "");
    const head = document.createElement("b");
    head.textContent = heading || (isError ? "Zeitverlauf nicht lesbar" : "Nichts anzuzeigen");
    note.appendChild(head);
    note.appendChild(document.createTextNode(message));
    note.hidden = false;
  }

  /** Mark one window button as selected. */
  function setWindow(window_) {
    const buttons = document.querySelectorAll("#windowSwitch button");
    Array.prototype.forEach.call(buttons, function (button) {
      button.classList.toggle("active", button.dataset.window === window_);
    });
  }

  /** Remove values from the previously selected project. */
  function clear() {
    const svg = document.getElementById("trendSvg");
    const periods = document.getElementById("trendBody");
    const buckets = document.getElementById("trendBucketBody");
    if (svg) svg.textContent = "";
    if (periods) periods.textContent = "";
    if (buckets) buckets.textContent = "";
    const limitNote = document.getElementById("trendLimitNote");
    if (limitNote) limitNote.hidden = true;
  }

  /** Clear stale values and show a project-bound loading state. */
  function setLoading() {
    clear();
    setNote("Der Zeitverlauf für das gewählte Projekt wird geladen …", false, "Zeitverlauf wird geladen");
  }

  return {
    render: render,
    setNote: setNote,
    clear: clear,
    setLoading: setLoading,
    setWindow: setWindow
  };
})();
