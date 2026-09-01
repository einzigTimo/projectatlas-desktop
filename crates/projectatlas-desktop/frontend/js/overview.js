/* Purpose: Render the savings overview — the "was" and "wodurch" of the dashboard.
   Every value is written into an existing text node, never by replacing markup, so
   a background refresh cannot steal focus, reset scroll, or collapse a table. */

window.PAD = window.PAD || {};

window.PAD.overview = (function () {
  "use strict";

  const fmt = window.PAD.format;

  /** Cluster colors, cycling like atlas_cluster_color in token_tui.rs. */
  const CLUSTER_COLORS = ["var(--blue)", "var(--green)", "var(--yellow)", "var(--purple)"];

  /** Write text into one element by id, if it exists. */
  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  /** Set one bar's fill width as a percentage of a reference value. */
  function setBar(id, value, reference) {
    const el = document.getElementById(id);
    if (!el) return;
    const ratio = reference > 0 ? Math.max(0, Math.min(1, value / reference)) : 0;
    el.style.width = (ratio * 100).toFixed(1) + "%";
  }

  /** Briefly highlight the headline number after a silent update. */
  function flashHero() {
    const el = document.getElementById("heroValue");
    if (!el) return;
    el.classList.add("flash");
    window.setTimeout(function () {
      el.classList.remove("flash");
    }, 500);
  }

  /** Render the confidence donut and its legend. */
  function renderSignal(data) {
    const measured = Math.max(0, data.measuredTokensSaved);
    const modeled = Math.max(0, data.dedupedModeledTokensAvoided);
    const total = measured + modeled;
    const observedShare = total > 0 ? measured / total : 0;

    const donut = document.getElementById("signalDonut");
    if (donut) {
      const circumference = 150.8;
      donut.setAttribute("stroke-dashoffset", (circumference * (1 - observedShare)).toFixed(1));
    }
    setText("signalObserved", "beobachtet " + (total > 0 ? fmt.percent(observedShare, 0) : fmt.DASH));
    setText("signalModeled", "modelliert " + (total > 0 ? fmt.percent(1 - observedShare, 0) : fmt.DASH));
  }

  /** Collapse the bucket rows into distinct categories, strongest first. */
  function categories(buckets) {
    const totals = new Map();
    buckets.forEach(function (bucket) {
      const previous = totals.get(bucket.bucket) || 0;
      totals.set(bucket.bucket, previous + bucket.saved);
    });
    return Array.from(totals.entries())
      .map(function (entry) {
        return { name: entry[0], saved: entry[1] };
      })
      .sort(function (left, right) {
        return right.saved - left.saved;
      });
  }

  /** Render the category legend, one line per distinct savings category. */
  function renderCategories(buckets) {
    const host = document.getElementById("signalCategories");
    if (!host) return;
    host.textContent = "";
    const distinct = categories(buckets);
    if (distinct.length === 0) {
      const empty = document.createElement("div");
      empty.textContent = "noch keine Kategorien";
      host.appendChild(empty);
      return;
    }
    const total = distinct.reduce(function (sum, entry) {
      return sum + Math.max(0, entry.saved);
    }, 0);
    distinct.slice(0, 4).forEach(function (entry, index) {
      const line = document.createElement("div");
      const swatch = document.createElement("i");
      swatch.style.background = CLUSTER_COLORS[index % CLUSTER_COLORS.length];
      const label = document.createElement("span");
      label.textContent = entry.name + " " + fmt.share(Math.max(0, entry.saved), total, 0);
      line.appendChild(swatch);
      line.appendChild(label);
      host.appendChild(line);
    });
  }

  /** Render the attribution table. */
  function renderBreakdown(buckets) {
    const body = document.getElementById("breakdownBody");
    if (!body) return;
    body.textContent = "";
    if (buckets.length === 0) {
      const row = document.createElement("tr");
      const cell = document.createElement("td");
      cell.colSpan = 5;
      cell.textContent = "Noch keine aufgezeichneten Aufrufe in diesem Projekt.";
      row.appendChild(cell);
      body.appendChild(row);
      return;
    }
    buckets.forEach(function (bucket) {
      const row = document.createElement("tr");
      const cells = [
        { text: bucket.provider + " / " + bucket.model, cls: "" },
        { text: bucket.baselineKind, cls: "" },
        { text: fmt.int(bucket.calls), cls: "num" },
        { text: fmt.tokens(bucket.saved), cls: "num " + (bucket.saved < 0 ? "neg" : "pos") },
        { text: fmt.percent(bucket.savingsRate), cls: "num " + (bucket.saved < 0 ? "neg" : "pos") }
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

  /** Render the calibration and method hints. */
  function renderCalibration(data) {
    const host = document.getElementById("calibLines");
    if (!host) return;
    host.textContent = "";

    const calibrationLine = document.createElement("div");
    if (data.calibration) {
      const mark = document.createElement("span");
      mark.className = "ok";
      mark.textContent = "✓";
      calibrationLine.appendChild(mark);
      calibrationLine.appendChild(document.createTextNode(" Kalibrierung vorhanden · Tokenizer "));
      const tokenizer = document.createElement("b");
      tokenizer.textContent = data.calibration.tokenizer;
      calibrationLine.appendChild(tokenizer);
      calibrationLine.appendChild(document.createTextNode(" (" + data.calibration.provider + " / " + data.calibration.model + ")"));
    } else {
      calibrationLine.textContent = "Keine lokale Tokenizer-Kalibrierung hinterlegt — die Zahlen sind geschätzt.";
    }
    host.appendChild(calibrationLine);

    const methodLine = document.createElement("div");
    methodLine.appendChild(document.createTextNode("Schätzart: "));
    const kind = document.createElement("b");
    kind.textContent = data.estimateKind;
    methodLine.appendChild(kind);
    methodLine.appendChild(document.createTextNode(" · Schätzer: "));
    const estimator = document.createElement("b");
    estimator.textContent = data.estimator;
    methodLine.appendChild(estimator);
    host.appendChild(methodLine);

    const scopeLine = document.createElement("div");
    scopeLine.appendChild(document.createTextNode("Geltungsbereich: "));
    const scope = document.createElement("b");
    scope.textContent = data.estimateScope;
    scopeLine.appendChild(scope);
    scopeLine.appendChild(document.createTextNode(" · Vermeidungs-Konfidenz: "));
    const confidence = document.createElement("b");
    confidence.textContent = data.readAvoidanceConfidence;
    scopeLine.appendChild(confidence);
    host.appendChild(scopeLine);
  }

  /** Surface a direct calibration action as soon as recorded calls need one. */
  function renderCalibrationNeeded(data) {
    const hint = document.getElementById("calibrationNeeded");
    if (!hint) return;
    hint.hidden = !data.calibrationNeeded;
  }

  /** Report calibration progress locally without hiding an already valid overview. */
  function setCalibrationStatus(message, isError) {
    const status = document.getElementById("calibActionStatus");
    if (!status) return;
    status.textContent = message || "";
    status.classList.toggle("error", !!isError);
  }

  /**
   * Explain an all-zero overview instead of showing silent nulls.
   *
   * Telemetry rows only appear when an agent actually calls the `atlas_*` MCP
   * tools, so a connected project with zero calls is almost always a setup gap:
   * Claude Code only auto-loads `<root>/.mcp.json`, which `claudeMcpRegistered`
   * reflects. A user-scoped registration outside the project is invisible to
   * that check, hence the softer wording once the file is present.
   */
  function renderZeroCallsHint(data) {
    const hint = document.getElementById("heroHint");
    if (!hint) return;
    hint.textContent = "";
    if (data.calls > 0) {
      hint.hidden = true;
      return;
    }
    const head = document.createElement("b");
    let body;
    if (data.claudeMcpRegistered) {
      head.textContent = "MCP-Server registriert, aber noch unbenutzt.";
      body =
        " Der Agent hat bisher keine atlas_*-Tools aufgerufen. " +
        "Tipp: in der CLAUDE.md des Projekts vorgeben, zur Orientierung zuerst " +
        "atlas_*-Tools zu nutzen, bevor Dateien gelesen werden.";
    } else {
      head.textContent = "MCP-Server nicht verbunden – Tokens werden nicht erfasst.";
      body =
        " Im Projektordner projectatlas init ausführen (registriert den Server in " +
        ".mcp.json) und Claude Code neu starten.";
    }
    hint.appendChild(head);
    hint.appendChild(document.createTextNode(body));
    hint.hidden = false;
  }

  /** Render the whole overview panel from one backend payload. */
  function render(data, options) {
    const flash = options && options.flash;
    const buckets = data.buckets || [];
    const reference = Math.max(data.without, data.with, Math.abs(data.saved), 1);

    setText("hdrCalls", fmt.int(data.calls));
    setText("hdrEstimate", data.estimator);

    setText("heroNumber", fmt.int(data.saved));
    setText("heroCheck", data.measuredTokensSaved > 0 ? "✓" : "");
    setText(
      "heroSub",
      data.calls > 0
        ? fmt.int(data.calls) + " Aufrufe · Sparquote " + fmt.percent(data.savingsRate)
        : "noch keine aufgezeichneten Aufrufe"
    );
    renderZeroCallsHint(data);

    setText("eqWithout", fmt.int(data.without));
    setBar("eqWithoutBar", data.without, reference);
    setText("eqWith", fmt.int(data.with));
    setBar("eqWithBar", data.with, reference);
    setText("eqSaved", fmt.int(data.saved));
    setBar("eqSavedBar", Math.abs(data.saved), reference);

    const secondReference = Math.max(
      Math.abs(data.measuredTokensSaved),
      Math.abs(data.dedupedModeledTokensAvoided),
      Math.abs(data.maximumTokensAvoided),
      1
    );
    setText("eqMeasured", fmt.int(data.measuredTokensSaved));
    setBar("eqMeasuredBar", Math.abs(data.measuredTokensSaved), secondReference);
    setText("eqModeled", fmt.int(data.dedupedModeledTokensAvoided));
    setBar("eqModeledBar", Math.abs(data.dedupedModeledTokensAvoided), secondReference);
    setText("eqMaximum", fmt.int(data.maximumTokensAvoided));
    setBar("eqMaximumBar", Math.abs(data.maximumTokensAvoided), secondReference);

    setText("navReads", fmt.int(data.likelyFileReadsAvoided));
    setText("navObserved", fmt.int(data.observedFileReadReplacements));
    setText("navModeled", fmt.int(data.modeledFileReadsAvoided));
    setText("navRate", fmt.percent(data.savingsRate));

    renderSignal(data);
    renderCategories(buckets);
    renderBreakdown(buckets);
    renderCalibration(data);
    renderCalibrationNeeded(data);
    setText("statusClock", "Stand " + fmt.clockNow() + " · aktualisiert sich selbst");

    if (flash) flashHero();
  }

  /** Show or clear the panel-level note used for empty and error states. */
  function setNote(message, isError, heading) {
    const note = document.getElementById("overviewNote");
    const cols = document.getElementById("overviewCols");
    if (!note || !cols) return;
    if (!message) {
      note.hidden = true;
      cols.hidden = false;
      return;
    }
    note.textContent = "";
    note.className = "state-note" + (isError ? " error" : "");
    const head = document.createElement("b");
    head.textContent = heading || (isError ? "Projekt nicht lesbar" : "Nichts anzuzeigen");
    note.appendChild(head);
    note.appendChild(document.createTextNode(message));
    note.hidden = false;
    cols.hidden = true;
  }

  return {
    render: render,
    setNote: setNote,
    setLoading: function () {
      setCalibrationStatus("");
      setNote("Die Übersicht für das gewählte Projekt wird geladen …", false, "Projekt wird geladen");
    },
    setCalibrationStatus: setCalibrationStatus
  };
})();
