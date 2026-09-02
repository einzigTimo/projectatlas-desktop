/* Purpose: Draw and drive the Atlas Map — the relationship view on the right.
   The backend delivers nodes and edges; the placement and the interaction happen here.

   Hubs are anchored on a fixed ring and never move during layout: letting them float
   turned every spring into a pull toward the centre of mass, and all hubs collapsed
   into one clump. Only the leaves relax, around the hub they belong to. The result is
   deterministic — the same graph always lands in the same shape, so a refresh never
   makes the picture jump.

   On top of that layout sits the interaction: the whole scene can be dragged and
   zoomed, a single node can be pulled aside, and clicking one shows what it is
   connected to. All of that is view state only — nothing is written back — so a live
   update simply redraws the same deterministic picture. */

window.PAD = window.PAD || {};

window.PAD.atlas = (function () {
  "use strict";

  const fmt = window.PAD.format;
  const api = window.PAD.api;

  const NAMESPACE = "http://www.w3.org/2000/svg";
  /** Node colors, cycling like atlas_cluster_color in token_tui.rs. */
  const CLUSTER_COLORS = ["var(--blue)", "var(--green)", "var(--yellow)", "var(--purple)"];
  /** Drawing area in user units; the SVG scales it into whatever box it sits in. */
  const SIZE = { width: 300, height: 340, padding: 24 };
  /** Relaxation passes; fixed so the layout is reproducible. */
  const PASSES = 160;
  /** Distance of the hub ring, as a share of the usable radius. */
  const HUB_RING = 0.44;
  /** Distance a leaf is pushed away from its hub. */
  const LEAF_DISTANCE = 46;
  /** Below this distance two nodes push each other apart. */
  const MIN_GAP = 26;
  /** Zoom limits and the step one wheel notch or button press takes. */
  const ZOOM_MIN = 0.4;
  const ZOOM_MAX = 8;
  const ZOOM_STEP = 1.25;
  /** Pointer travel in screen pixels that still counts as a click, not a drag. */
  const CLICK_SLOP = 3;
  /** Neighbours listed in the detail box before the rest is summed up. */
  const MAX_NEIGHBOR_CHIPS = 12;
  /** Top files shown above the compact graph. */
  const MAX_RELATION_SUMMARY = 8;

  /** Return whether one repository path can expose Markdown heading selectors. */
  function isMarkdownPath(path) {
    return /\.(md|mdx|markdown)$/i.test(path || "");
  }

  /** Copy text with the modern clipboard API and a WebView-compatible fallback. */
  function copyText(text) {
    function fallback() {
      return new Promise(function (resolve, reject) {
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.readOnly = true;
        textarea.style.position = "fixed";
        textarea.style.left = "-9999px";
        document.body.appendChild(textarea);
        textarea.select();
        let copied = false;
        try {
          copied = document.execCommand("copy");
        } catch (_error) {
          copied = false;
        }
        textarea.remove();
        if (copied) resolve();
        else reject(new Error("Kopieren nicht möglich."));
      });
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(fallback);
    }
    return fallback();
  }

  /** Seeded pseudo-random generator, so a graph always starts from the same spot. */
  function seeded(seed) {
    let state = seed >>> 0;
    return function () {
      state = (state * 1664525 + 1013904223) >>> 0;
      return state / 4294967296;
    };
  }

  /** Turn a node id into a stable numeric seed. */
  function seedOf(id) {
    let hash = 0;
    for (let index = 0; index < id.length; index += 1) {
      hash = (hash * 31 + id.charCodeAt(index)) >>> 0;
    }
    return hash;
  }

  /** Keep a value inside an inclusive range. */
  function clamp(value, low, high) {
    return Math.min(high, Math.max(low, value));
  }

  /** Return one element by id, or null. */
  function el(id) {
    return document.getElementById(id);
  }

  /** Place hubs on a fixed ring and relax the leaves around them. */
  function layout(nodes, edges) {
    const centerX = SIZE.width / 2;
    const centerY = SIZE.height / 2;
    const radius = Math.min(SIZE.width, SIZE.height) / 2 - SIZE.padding;

    // One ring slot per distinct cluster. The backend numbers clusters per hub, so
    // this is normally one slot per hub; keying by cluster keeps two hubs from
    // landing on the exact same point should that numbering ever repeat.
    const hubs = nodes.filter(function (node) { return node.hub; });
    const clusterOrder = [];
    hubs.forEach(function (hub) {
      if (clusterOrder.indexOf(hub.cluster) === -1) clusterOrder.push(hub.cluster);
    });
    const hubAngles = new Map();
    clusterOrder.forEach(function (cluster, position) {
      hubAngles.set(
        cluster,
        (position / Math.max(1, clusterOrder.length)) * Math.PI * 2 - Math.PI / 2
      );
    });

    const index = new Map();
    const placed = nodes.map(function (node, position) {
      index.set(node.id, position);
      const anchorAngle = hubAngles.has(node.cluster)
        ? hubAngles.get(node.cluster)
        : (position / Math.max(1, nodes.length)) * Math.PI * 2;

      if (node.hub) {
        return {
          node: node,
          fixed: true,
          x: centerX + Math.cos(anchorAngle) * radius * HUB_RING,
          y: centerY + Math.sin(anchorAngle) * radius * HUB_RING
        };
      }

      const random = seeded(seedOf(node.id));
      const spread = (random() - 0.5) * 1.5;
      const distance = radius * (0.74 + random() * 0.26);
      return {
        node: node,
        fixed: false,
        x: centerX + Math.cos(anchorAngle + spread) * distance,
        y: centerY + Math.sin(anchorAngle + spread) * distance
      };
    });

    const links = edges
      .map(function (edge) {
        return [index.get(edge.source), index.get(edge.target)];
      })
      .filter(function (pair) {
        return pair[0] !== undefined && pair[1] !== undefined;
      });

    /** Move one node unless it is anchored. */
    function nudge(item, dx, dy) {
      if (item.fixed) return;
      item.x += dx;
      item.y += dy;
    }

    for (let pass = 0; pass < PASSES; pass += 1) {
      const cooling = 1 - pass / PASSES;

      for (let a = 0; a < placed.length; a += 1) {
        for (let b = a + 1; b < placed.length; b += 1) {
          if (placed[a].fixed && placed[b].fixed) continue;
          let dx = placed[a].x - placed[b].x;
          let dy = placed[a].y - placed[b].y;
          const distance = Math.sqrt(dx * dx + dy * dy) || 0.01;
          if (distance > MIN_GAP) continue;
          const push = ((MIN_GAP - distance) / distance) * 0.5 * cooling;
          dx *= push;
          dy *= push;
          nudge(placed[a], dx, dy);
          nudge(placed[b], -dx, -dy);
        }
      }

      links.forEach(function (link) {
        const from = placed[link[0]];
        const to = placed[link[1]];
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const distance = Math.sqrt(dx * dx + dy * dy) || 0.01;
        const pull = ((distance - LEAF_DISTANCE) / distance) * 0.25 * cooling;
        nudge(from, dx * pull, dy * pull);
        nudge(to, -dx * pull, -dy * pull);
      });

      placed.forEach(function (item) {
        if (item.fixed) return;
        const dx = item.x - centerX;
        const dy = item.y - centerY;
        const distance = Math.sqrt(dx * dx + dy * dy) || 0.01;
        if (distance > radius) {
          item.x = centerX + (dx / distance) * radius;
          item.y = centerY + (dy / distance) * radius;
        }
      });
    }

    return { placed: placed, links: links };
  }

  /** Show one explanatory line instead of a graph. */
  function placeholder(wrap, text) {
    const note = document.createElement("div");
    note.className = "atlas-placeholder";
    note.textContent = text;
    wrap.appendChild(note);
  }

  /** Build one interactive map bound to a wrap / detail / foot element triple.

     The dashboard needs the same picture twice — small in the overview column and
     large in the expanded window — so the whole renderer is created per target
     instead of reaching for one fixed set of element ids. */
  function createSurface(wrapId, detailId, footId, relationsId) {
    /** Everything about the currently drawn graph, or null while nothing is drawn. */
    let map = null;
    /** Invalidates stale relation/heading responses after another selection. */
    let relationRequest = 0;

    /** Write the current pan and zoom onto the scene group. */
    function applyTransform() {
      map.scene.setAttribute(
        "transform",
        "translate(" + map.tx.toFixed(2) + " " + map.ty.toFixed(2) +
          ") scale(" + map.zoom.toFixed(3) + ")"
      );
    }

    /** Write every node and edge position into the DOM. */
    function applyPositions() {
      map.nodes.forEach(function (entry, position) {
        const item = map.placed[position];
        const x = item.x.toFixed(1);
        const y = item.y.toFixed(1);
        entry.dot.setAttribute("cx", x);
        entry.dot.setAttribute("cy", y);
        entry.hit.setAttribute("cx", x);
        entry.hit.setAttribute("cy", y);
        if (entry.halo) {
          entry.halo.setAttribute("cx", x);
          entry.halo.setAttribute("cy", y);
        }
        if (entry.text) {
          entry.text.setAttribute("x", x);
          entry.text.setAttribute("y", (item.y - entry.radius - 4).toFixed(1));
        }
      });
      map.edges.forEach(function (entry) {
        const from = map.placed[entry.from];
        const to = map.placed[entry.to];
        entry.line.setAttribute("x1", from.x.toFixed(1));
        entry.line.setAttribute("y1", from.y.toFixed(1));
        entry.line.setAttribute("x2", to.x.toFixed(1));
        entry.line.setAttribute("y2", to.y.toFixed(1));
      });
    }

    /** Turn one pointer event into the coordinate system of an SVG element. */
    function pointIn(element, event) {
      const point = map.svg.createSVGPoint();
      point.x = event.clientX;
      point.y = event.clientY;
      const matrix = element.getScreenCTM();
      if (!matrix) return { x: 0, y: 0 };
      return point.matrixTransform(matrix.inverse());
    }

    /** Zoom around a focus point given in the SVG viewport coordinate system. */
    function zoomBy(factor, focus) {
      if (!map) return;
      const next = clamp(map.zoom * factor, ZOOM_MIN, ZOOM_MAX);
      if (next === map.zoom) return;
      const ratio = next / map.zoom;
      const point = focus || { x: SIZE.width / 2, y: SIZE.height / 2 };
      map.tx = point.x - (point.x - map.tx) * ratio;
      map.ty = point.y - (point.y - map.ty) * ratio;
      map.zoom = next;
      applyTransform();
    }

    /** Positions of every node linked to the one at `position`, without repeats. */
    function neighborsOf(position) {
      const found = [];
      map.links.forEach(function (link) {
        let other = null;
        if (link[0] === position) other = link[1];
        else if (link[1] === position) other = link[0];
        if (other === null || other === position) return;
        if (found.indexOf(other) === -1) found.push(other);
      });
      return found;
    }

    /** Empty the detail box below the map. */
    function clearDetail() {
      relationRequest += 1;
      const box = el(detailId);
      if (!box) return;
      box.textContent = "";
      box.hidden = true;
    }

    /** Add the standard close control to a map detail box. */
    function appendDetailClose(box, handler) {
      const close = document.createElement("button");
      close.type = "button";
      close.className = "atlas-detail-close";
      close.title = "Auswahl aufheben";
      close.textContent = "×";
      close.addEventListener("click", handler);
      box.appendChild(close);
    }

    /** Translate the backend's direction marker into a compact German label. */
    function directionLabel(direction) {
      return String(direction || "").toLowerCase() === "outgoing"
        ? "→ ausgehend"
        : "← eingehend";
    }

    /** Render an exact Markdown heading selector picker into a relation detail. */
    function appendHeadingPicker(box, projectId, filePath, request) {
      if (!isMarkdownPath(filePath)) return;

      const section = document.createElement("div");
      section.className = "heading-picker";
      const loading = document.createElement("div");
      loading.className = "heading-picker-note";
      loading.textContent = "Abschnittsziele werden geladen …";
      section.appendChild(loading);
      box.appendChild(section);

      api
        .getFileHeadings(projectId, filePath)
        .then(function (headings) {
          if (request !== relationRequest || projectId !== lastProjectId) return;
          section.textContent = "";

          const title = document.createElement("div");
          title.className = "heading-picker-title";
          title.textContent = "Exaktes Abschnittsziel";
          section.appendChild(title);

          if (!headings || headings.length === 0) {
            const empty = document.createElement("div");
            empty.className = "heading-picker-note";
            empty.textContent = "Keine Markdown-Überschriften im Index gefunden.";
            section.appendChild(empty);
            return;
          }

          const controls = document.createElement("div");
          controls.className = "heading-picker-controls";
          const picker = document.createElement("select");
          picker.title = "Dokumentabschnitt auswählen";
          headings.forEach(function (heading) {
            const option = document.createElement("option");
            option.value = heading.selector || (filePath + "#" + heading.anchor);
            const indent = new Array(Math.max(1, heading.level || 1)).join("· ");
            option.textContent =
              indent + heading.text + (heading.line ? " · Zeile " + fmt.int(heading.line) : "");
            picker.appendChild(option);
          });

          const copy = document.createElement("button");
          copy.type = "button";
          copy.textContent = "Selektor kopieren";
          const status = document.createElement("span");
          status.className = "heading-copy-status";
          status.setAttribute("aria-live", "polite");

          copy.addEventListener("click", function () {
            copy.disabled = true;
            copyText(picker.value)
              .then(function () {
                status.textContent = "Selektor kopiert.";
                status.classList.remove("error");
              })
              .catch(function () {
                status.textContent = "Kopieren nicht möglich.";
                status.classList.add("error");
              })
              .then(function () {
                copy.disabled = false;
                window.setTimeout(function () {
                  if (request === relationRequest) status.textContent = "";
                }, 2200);
              });
          });

          controls.appendChild(picker);
          controls.appendChild(copy);
          section.appendChild(controls);
          section.appendChild(status);
        })
        .catch(function () {
          if (request !== relationRequest || projectId !== lastProjectId) return;
          loading.textContent = "Abschnittsziele konnten nicht geladen werden.";
          loading.classList.add("error");
        });
    }

    /** Append one incoming or outgoing file relation. */
    function appendFileRelation(host, entry, fallbackDirection, selectedPath) {
      const row = document.createElement("div");
      row.className = "file-relation-row";

      const direction = document.createElement("span");
      direction.className = "file-relation-direction";
      direction.textContent = directionLabel(entry.direction || fallbackDirection);

      const relation = document.createElement("span");
      relation.className = "file-relation-kind";
      relation.textContent = entry.relation || "Relation";

      let neighbor;
      const canDrillDown =
        String(entry.entityKind || "").toLowerCase() === "file" &&
        entry.path && entry.path !== selectedPath;
      if (canDrillDown) {
        neighbor = document.createElement("button");
        neighbor.type = "button";
        neighbor.title = entry.path;
        neighbor.addEventListener("click", function () {
          showFileRelations(entry.path, entry.label || entry.path);
        });
      } else {
        neighbor = document.createElement("span");
        neighbor.title = entry.path || "";
      }
      neighbor.className = "file-relation-neighbor selectable";
      neighbor.textContent = entry.label || entry.path || "Unbekannter Nachbar";

      row.appendChild(direction);
      row.appendChild(relation);
      row.appendChild(neighbor);
      host.appendChild(row);
    }

    /** Render the fetched relation page for one repository file. */
    function renderFileRelations(box, data, fallbackPath, projectId, request) {
      const filePath = (data && data.path) || fallbackPath;
      const incoming = (data && data.incoming) || [];
      const outgoing = (data && data.outgoing) || [];

      const name = document.createElement("div");
      name.className = "name selectable";
      name.textContent = filePath;
      box.appendChild(name);

      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent =
        fmt.int(incoming.length) + " eingehend · " +
        fmt.int(outgoing.length) + " ausgehend" +
        (data && data.truncated ? " · begrenzter Ausschnitt" : "");
      box.appendChild(meta);

      const relations = document.createElement("div");
      relations.className = "file-relations";
      outgoing.forEach(function (entry) {
        appendFileRelation(relations, entry, "outgoing", filePath);
      });
      incoming.forEach(function (entry) {
        appendFileRelation(relations, entry, "incoming", filePath);
      });
      if (incoming.length === 0 && outgoing.length === 0) {
        const empty = document.createElement("div");
        empty.className = "file-relations-empty";
        empty.textContent = "Für diese Datei sind keine Relationen veröffentlicht.";
        relations.appendChild(empty);
      }
      box.appendChild(relations);
      appendHeadingPicker(box, projectId, filePath, request);
    }

    /** Fetch and show the directional relation page for one file. */
    function showFileRelations(filePath, label) {
      const box = el(detailId);
      const projectId = lastProjectId;
      if (!box || !projectId || !filePath) return;
      const request = ++relationRequest;
      box.textContent = "";
      appendDetailClose(box, function () {
        if (map) select(null);
        else clearDetail();
      });

      const loading = document.createElement("div");
      loading.className = "name selectable";
      loading.textContent = label || filePath;
      box.appendChild(loading);
      const state = document.createElement("div");
      state.className = "meta";
      state.textContent = "Relationen werden geladen …";
      box.appendChild(state);
      box.hidden = false;

      api
        .getFileRelations(projectId, filePath)
        .then(function (data) {
          if (request !== relationRequest || projectId !== lastProjectId) return;
          box.textContent = "";
          appendDetailClose(box, function () {
            if (map) select(null);
            else clearDetail();
          });
          renderFileRelations(box, data, filePath, projectId, request);
        })
        .catch(function (error) {
          if (request !== relationRequest || projectId !== lastProjectId) return;
          state.textContent = error && error.message ? error.message : String(error);
          state.classList.add("error");
        });
    }

    /** Add an exact repository-path entry point for files outside the preview. */
    function appendPathLookup(host) {
      const form = document.createElement("form");
      form.className = "atlas-path-lookup";
      const input = document.createElement("input");
      input.type = "text";
      input.placeholder = "docs/handbuch.md";
      input.setAttribute("aria-label", "Repository-relativen Dateipfad öffnen");
      input.autocomplete = "off";
      input.spellcheck = false;
      const open = document.createElement("button");
      open.type = "submit";
      open.textContent = "Pfad öffnen";
      form.appendChild(input);
      form.appendChild(open);
      form.addEventListener("submit", function (event) {
        event.preventDefault();
        const path = input.value.trim();
        if (path) showFileRelations(path, path);
      });
      host.appendChild(form);
    }

    /** Render the compact top-file relation summary above the graph. */
    function renderRelationSummary(view) {
      const host = el(relationsId);
      if (!host) return;
      host.textContent = "";

      const title = document.createElement("div");
      title.className = "atlas-relations-title";
      title.textContent = "Relationen · Top-Dateien";
      host.appendChild(title);
      appendPathLookup(host);

      const entries = (view && view.relationSummary) || [];
      if (entries.length === 0) {
        const empty = document.createElement("div");
        empty.className = "atlas-relations-empty";
        empty.textContent = "Noch keine Dateirelationen verfügbar.";
        host.appendChild(empty);
        return;
      }

      entries.slice(0, MAX_RELATION_SUMMARY).forEach(function (entry) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "atlas-relation-summary";
        button.title =
          entry.path +
          ((entry.relationKinds || []).length > 0
            ? "\n" + entry.relationKinds.join(" · ")
            : "");

        const label = document.createElement("span");
        label.className = "atlas-relation-label";
        label.textContent = entry.label || entry.path;
        const meta = document.createElement("span");
        meta.className = "atlas-relation-meta";
        meta.textContent = fmt.int(entry.incoming || 0) + " eingehend";
        const kinds = document.createElement("span");
        kinds.className = "atlas-relation-kinds";
        kinds.textContent = (entry.relationKinds || []).join(" · ") || "Relation";

        button.appendChild(label);
        button.appendChild(meta);
        button.appendChild(kinds);
        button.addEventListener("click", function () {
          showFileRelations(entry.path, entry.label || entry.path);
        });
        host.appendChild(button);
      });
    }

    /** Describe the selected node below the map. */
    function showDetail(position) {
      const box = el(detailId);
      if (!box) return;
      relationRequest += 1;
      const node = map.placed[position].node;
      const neighbors = neighborsOf(position);
      box.textContent = "";

      appendDetailClose(box, function () { select(null); });

      const name = document.createElement("div");
      name.className = "name selectable";
      name.textContent = node.label;
      box.appendChild(name);

      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent =
        (node.hub ? "Knotenpunkt" : "Knoten") +
        (node.entityKind ? " · " + node.entityKind : "") +
        " · Gruppe " + fmt.int(node.cluster + 1) +
        " · " + fmt.int(neighbors.length) +
        (neighbors.length === 1 ? " Verbindung" : " Verbindungen");
      box.appendChild(meta);

      if (node.path) {
        const path = document.createElement("div");
        path.className = "atlas-node-path selectable";
        path.textContent = node.path;
        box.appendChild(path);
      }

      if (neighbors.length > 0) {
        const list = document.createElement("div");
        list.className = "neighbors";
        neighbors.slice(0, MAX_NEIGHBOR_CHIPS).forEach(function (other) {
          const chip = document.createElement("button");
          chip.type = "button";
          chip.textContent = map.placed[other].node.label;
          chip.title = "Zu diesem Knoten springen";
          chip.addEventListener("click", function () { select(other); });
          list.appendChild(chip);
        });
        if (neighbors.length > MAX_NEIGHBOR_CHIPS) {
          const more = document.createElement("span");
          more.className = "more";
          more.textContent = "+" + fmt.int(neighbors.length - MAX_NEIGHBOR_CHIPS) + " weitere";
          list.appendChild(more);
        }
        box.appendChild(list);
      }

      if (String(node.entityKind || "").toLowerCase() === "file" && node.path) {
        const actions = document.createElement("div");
        actions.className = "atlas-detail-actions";
        const relations = document.createElement("button");
        relations.type = "button";
        relations.textContent = isMarkdownPath(node.path)
          ? "Dateirelationen & Abschnitte"
          : "Dateirelationen";
        relations.addEventListener("click", function () {
          showFileRelations(node.path, node.label);
        });
        actions.appendChild(relations);
        box.appendChild(actions);
      }

      box.hidden = false;
    }

    /** Select one node, or clear the selection with null. */
    function select(position) {
      if (!map) return;
      map.selected = position;

      if (position === null) {
        map.svg.classList.remove("has-selection");
        map.nodes.forEach(function (entry) {
          entry.group.classList.remove("selected");
          entry.group.classList.remove("neighbor");
        });
        map.edges.forEach(function (entry) {
          entry.line.classList.remove("active");
        });
        clearDetail();
        return;
      }

      const neighbors = neighborsOf(position);
      map.svg.classList.add("has-selection");
      map.nodes.forEach(function (entry, other) {
        entry.group.classList.toggle("selected", other === position);
        entry.group.classList.toggle("neighbor", neighbors.indexOf(other) !== -1);
      });
      map.edges.forEach(function (entry) {
        entry.line.classList.toggle("active", entry.from === position || entry.to === position);
      });
      showDetail(position);
    }

    /** Start a drag: `position` null pans the whole scene, otherwise it pulls one node. */
    function beginDrag(event, position) {
      if (!map || event.button !== 0) return;
      event.preventDefault();

      const panning = position === null;
      const frame = panning ? map.svg : map.scene;
      const start = pointIn(frame, event);
      const origin = panning
        ? { x: map.tx, y: map.ty }
        : { x: map.placed[position].x, y: map.placed[position].y };
      const startClient = { x: event.clientX, y: event.clientY };
      let moved = false;

      if (panning) map.svg.classList.add("panning");

      function onMove(next) {
        if (
          Math.abs(next.clientX - startClient.x) > CLICK_SLOP ||
          Math.abs(next.clientY - startClient.y) > CLICK_SLOP
        ) {
          moved = true;
        }
        const current = pointIn(frame, next);
        if (panning) {
          map.tx = origin.x + (current.x - start.x);
          map.ty = origin.y + (current.y - start.y);
          applyTransform();
          return;
        }
        map.placed[position].x = origin.x + (current.x - start.x);
        map.placed[position].y = origin.y + (current.y - start.y);
        applyPositions();
      }

      function onEnd() {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onEnd);
        window.removeEventListener("pointercancel", onEnd);
        map.svg.classList.remove("panning");
        // Ein Zug verschiebt nur. Erst ein Klick ohne Weg waehlt aus oder hebt auf.
        if (!moved) select(panning ? null : position);
      }

      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onEnd);
      window.addEventListener("pointercancel", onEnd);
    }

    /** Build the SVG for one graph and wire its interaction. */
    function build(view) {
      const positioned = layout(view.nodes, view.edges || []);

      const svg = document.createElementNS(NAMESPACE, "svg");
      svg.setAttribute("class", "atlas-svg");
      svg.setAttribute("viewBox", "0 0 " + SIZE.width + " " + SIZE.height);
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
      svg.setAttribute("role", "img");
      svg.setAttribute("aria-label", "Beziehungsgraph des Projekts");

      const scene = document.createElementNS(NAMESPACE, "g");
      const edgeLayer = document.createElementNS(NAMESPACE, "g");
      const nodeLayer = document.createElementNS(NAMESPACE, "g");
      scene.appendChild(edgeLayer);
      scene.appendChild(nodeLayer);
      svg.appendChild(scene);

      map = {
        svg: svg,
        scene: scene,
        placed: positioned.placed,
        links: positioned.links,
        nodes: new Array(positioned.placed.length),
        edges: [],
        tx: 0,
        ty: 0,
        zoom: 1,
        selected: null
      };

      positioned.links.forEach(function (link) {
        const line = document.createElementNS(NAMESPACE, "line");
        line.setAttribute("class", "atlas-edge");
        line.setAttribute("stroke", "var(--border-dim)");
        line.setAttribute("stroke-width", "1");
        edgeLayer.appendChild(line);
        map.edges.push({ line: line, from: link[0], to: link[1] });
      });

      // Leaves first, hubs on top, so a hub label is never hidden behind a leaf.
      const order = positioned.placed
        .map(function (_item, position) { return position; })
        .sort(function (left, right) {
          return Number(positioned.placed[left].node.hub) -
            Number(positioned.placed[right].node.hub);
        });

      order.forEach(function (position) {
        const item = positioned.placed[position];
        const color = CLUSTER_COLORS[item.node.cluster % CLUSTER_COLORS.length];
        const nodeRadius = item.node.hub ? 4.2 : 2.4;

        const group = document.createElementNS(NAMESPACE, "g");
        group.setAttribute("class", "atlas-node" + (item.node.hub ? " hub" : ""));

        let halo = null;
        if (item.node.hub) {
          halo = document.createElementNS(NAMESPACE, "circle");
          halo.setAttribute("class", "halo");
          halo.setAttribute("r", (nodeRadius + 2.8).toFixed(1));
          halo.setAttribute("fill", "none");
          halo.setAttribute("stroke", color);
          halo.setAttribute("stroke-width", "1");
          halo.setAttribute("opacity", "0.35");
          group.appendChild(halo);
        }

        const dot = document.createElementNS(NAMESPACE, "circle");
        dot.setAttribute("class", "dot");
        dot.setAttribute("r", nodeRadius.toFixed(1));
        dot.setAttribute("fill", color);
        group.appendChild(dot);

        let text = null;
        if (item.node.hub || positioned.placed.length <= 16) {
          text = document.createElementNS(NAMESPACE, "text");
          text.setAttribute("font-size", item.node.hub ? "8.5" : "7.5");
          text.setAttribute("fill", item.node.hub ? color : "var(--muted)");
          text.setAttribute("text-anchor", "middle");
          text.setAttribute("font-family", "var(--font-ui)");
          text.textContent = item.node.label;
          group.appendChild(text);
        }

        // Zuletzt und grosszuegig: die unsichtbare Trefferflaeche liegt oben, damit
        // auch ein 2,4 Einheiten kleiner Blattknoten mit der Maus zu treffen ist.
        const hit = document.createElementNS(NAMESPACE, "circle");
        hit.setAttribute("class", "hit");
        hit.setAttribute("r", Math.max(nodeRadius + 5, 8).toFixed(1));
        group.appendChild(hit);

        const title = document.createElementNS(NAMESPACE, "title");
        title.textContent = item.node.label;
        group.appendChild(title);

        group.addEventListener("pointerdown", function (event) {
          event.stopPropagation();
          beginDrag(event, position);
        });

        nodeLayer.appendChild(group);
        map.nodes[position] = {
          group: group,
          dot: dot,
          halo: halo,
          text: text,
          hit: hit,
          radius: nodeRadius
        };
      });

      svg.addEventListener("pointerdown", function (event) {
        beginDrag(event, null);
      });
      svg.addEventListener(
        "wheel",
        function (event) {
          event.preventDefault();
          zoomBy(event.deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP, pointIn(svg, event));
        },
        { passive: false }
      );

      applyPositions();
      applyTransform();
      return svg;
    }

    /** Fill the foot line with the counts and the operating hint. */
    function renderFoot(view) {
      const foot = el(footId);
      if (!foot) return;

      const counts = document.createElement("div");
      const nodeCount = document.createElement("span");
      nodeCount.className = "n";
      nodeCount.textContent = fmt.int(view.nodes.length);
      const edgeCount = document.createElement("span");
      edgeCount.className = "n";
      edgeCount.textContent = fmt.int((view.edges || []).length);
      counts.appendChild(nodeCount);
      counts.appendChild(document.createTextNode(" Knoten · "));
      counts.appendChild(edgeCount);
      counts.appendChild(document.createTextNode(" Kanten · "));
      counts.appendChild(
        document.createTextNode(
          view.truncated ? "begrenzter Ausschnitt" : "vollständiger Ausschnitt"
        )
      );
      foot.appendChild(counts);

      const hint = document.createElement("div");
      hint.textContent = "ziehen verschiebt · Mausrad zoomt · Klick zeigt Verbindungen";
      foot.appendChild(hint);
    }

    /** Draw one view into this surface. */
    function render(view) {
      const wrap = el(wrapId);
      const foot = el(footId);
      if (!wrap) return;
      wrap.textContent = "";
      if (foot) foot.textContent = "";
      clearDetail();
      map = null;
      renderRelationSummary(view);

      if (!view || !view.available) {
        placeholder(
          wrap,
          "Für dieses Projekt liegt noch kein veröffentlichter Beziehungsgraph vor."
        );
        return;
      }
      if (!view.nodes || view.nodes.length === 0) {
        placeholder(wrap, "Der Beziehungsgraph ist leer — noch keine aufgelösten Verweise.");
        return;
      }

      wrap.appendChild(build(view));
      renderFoot(view);
    }

    /** Clear stale interactions while another project's graph is loading. */
    function renderLoading() {
      const wrap = el(wrapId);
      const foot = el(footId);
      const relations = el(relationsId);
      if (!wrap) return;
      wrap.textContent = "";
      if (foot) foot.textContent = "";
      if (relations) {
        relations.textContent = "";
        const note = document.createElement("div");
        note.className = "atlas-relations-empty";
        note.textContent = "Dateirelationen werden geladen …";
        relations.appendChild(note);
      }
      clearDetail();
      map = null;
      placeholder(wrap, "Beziehungsgraph wird geladen …");
    }

    /** Put pan and zoom back to the starting picture and drop the selection. */
    function reset() {
      if (!map) return;
      map.tx = 0;
      map.ty = 0;
      map.zoom = 1;
      applyTransform();
      select(null);
    }

    return {
      render: render,
      renderLoading: renderLoading,
      reset: reset,
      zoomIn: function () { zoomBy(ZOOM_STEP, null); },
      zoomOut: function () { zoomBy(1 / ZOOM_STEP, null); }
    };
  }

  const small = createSurface("atlasWrap", "atlasDetail", "atlasFoot", "atlasRelations");
  const large = createSurface("atlasBigWrap", "atlasBigDetail", "atlasBigFoot", "atlasBigRelations");

  /** Last view handed in, so the large window can be filled without a new fetch. */
  let lastView = null;
  /** Active project owning the current map and every relation drilldown. */
  let lastProjectId = null;
  /** Whether the large window is currently open. */
  let largeOpen = false;

  /** Draw one view; the large window follows along while it is open. */
  function draw(view, projectId) {
    lastView = view || null;
    lastProjectId = projectId || null;
    small.render(lastView);
    if (largeOpen) large.render(lastView);
  }

  /** Clear the previous project immediately and bind loading to the new id. */
  function setLoading(projectId) {
    lastView = null;
    lastProjectId = projectId || null;
    small.renderLoading();
    if (largeOpen) large.renderLoading();
  }

  /** Open the large map window. */
  function openLarge() {
    const overlay = el("atlasOverlay");
    if (!overlay) return;
    overlay.hidden = false;
    largeOpen = true;
    large.render(lastView);
  }

  /** Close the large map window. */
  function closeLarge() {
    const overlay = el("atlasOverlay");
    if (overlay) overlay.hidden = true;
    largeOpen = false;
  }

  /** Attach one click handler, if the button exists. */
  function onClick(id, handler) {
    const button = el(id);
    if (button) button.addEventListener("click", handler);
  }

  /** Wire the map controls of both surfaces. */
  function wire() {
    onClick("atlasZoomIn", small.zoomIn);
    onClick("atlasZoomOut", small.zoomOut);
    onClick("atlasReset", small.reset);
    onClick("atlasExpand", openLarge);

    onClick("atlasBigZoomIn", large.zoomIn);
    onClick("atlasBigZoomOut", large.zoomOut);
    onClick("atlasBigReset", large.reset);
    onClick("atlasCloseBtn", closeLarge);

    const overlay = el("atlasOverlay");
    if (overlay) {
      overlay.addEventListener("click", function (event) {
        if (event.target === overlay) closeLarge();
      });
    }
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && largeOpen) closeLarge();
    });
  }

  return {
    draw: draw,
    setLoading: setLoading,
    wire: wire
  };
})();
