# ProjectAtlas Desktop – Innovation-Übernahme-Request

Closes #10

## Status

Bereit zur Priorisierung und Zerlegung in Sub-Issues.

## Hintergrund

ProjectAtlas Desktop ist eine Companion-App für [ProjectAtlas](https://github.com/styler-ai/ProjectAtlas). Die
Desktop-App besitzt bereits eine Projekt-Registry, Rescan-Logik, Atlas-Map-/Recent-Activity-/Trend-Views,
Tauri-Frontend mit Updates, Setup und Badge-Status sowie eine Verbindung zu bestehenden Projekten über
`projectatlas init`.

Das Referenz-Repository `styler-ai/ProjectAtlas` hat seit der initialen Desktop-Integration mehrere Konzepte
eingeführt, die die Desktop-App von einer reinen Companion-Anzeige zu einer stärkeren
**Agenten-Navigations- und Wissensschicht** weiterentwickeln können. Dieser Request hält diese Kandidaten
als priorisierbare Vorhaben fest.

## Übernahme-Kandidaten (priorisiert)

### P1 – Purpose-Metadaten pro Datei und Ordner

**Was es ist:**
`styler-ai/ProjectAtlas` klassifiziert jede Datei und jeden Ordner mit einem `purpose`-Feld (z. B.
`source`, `test`, `config`, `generated`, `docs`). Dieser Wert steuert, welche Einträge Agenten zuerst
lesen, und ermöglicht gezielte Health-Checks.

**Was in der Desktop-App fehlt:**
Die `RegisteredProject`-Struktur und die Sidebar zeigen heute kein Purpose-Feld. Das bedeutet, dass die
Desktop-App keine Aussage darüber machen kann, welche Dateien und Ordner eines Projekts für Agenten
primär relevant sind.

**Vorgeschlagene Erweiterung:**
1. `RegisteredProject` um ein optionales `purpose_summary`-Feld erweitern
   (Anzahl klassifizierter Dateien nach Purpose-Kategorie, gelesen aus dem `AtlasStore`).
2. `ProjectView` und das Frontend-Sidebar-Widget um eine kompakte Purpose-Anzeige ergänzen.
3. Den `rescan`-Pfad so anpassen, dass Purpose-Zusammenfassungen beim Probing befüllt werden,
   ohne den Scan spürbar zu verlangsamen (Einzelabfrage je Projekt, kein Full-Walk).

**Warum P1:**
Purpose-Metadaten sind die Grundlage für alle weiteren Kandidaten (Routing, Graph, Referenzen).

---

### P2 – Atomare Registry- und Schema-Migrationen

**Was es ist:**
`styler-ai/ProjectAtlas` führt Datenbankmigrationen mit einer internen Versions-/Migrationstabelle durch.
Inkonsistente Schema-Stände werden erkannt und sauber auf den aktuellen Stand gebracht, ohne bestehende
Daten zu verlieren.

**Was in der Desktop-App fehlt:**
`registry.rs` setzt `REGISTRY_VERSION = 1` und bricht kompatibel ab, wenn die Version nicht passt –
es gibt aber keine automatische Forward-Migration. Beim Ergänzen neuer Felder (z. B. `purpose_summary`)
werden bestehende Registry-Dateien beim Laden still deserialisiert, aber unvollständig befüllt.

**Vorgeschlagene Erweiterung:**
1. Registry-Migrations-Tabelle nach dem `styler-ai/ProjectAtlas`-Muster implementieren: eine
   `migrate(version: u32, file: &mut RegistryFile) -> AppResult<()>` pro Versionssprung.
2. `load()` so anpassen, dass es die gespeicherte Version prüft und alle notwendigen Migrations-Schritte
   der Reihe nach ausführt, bevor es zurückgibt.
3. `REGISTRY_VERSION` nach jedem Schema-Sprung inkrementieren und einen zugehörigen Migrations-Handler
   eintragen.

**Warum P2:**
Ohne saubere Migrationen blockiert jede neue Registry-Erweiterung (P1, P4, P5) bestehende Nutzer mit
einer leeren oder ungültigen Registry nach dem Update.

---

### P3 – Dokument- und Source-Relationen im Atlas-View sichtbar machen

**Was es ist:**
`styler-ai/ProjectAtlas` verbindet Markdown-Dokumente, Quellcode-Dateien und Relations (z. B.
`imports`, `referenced_by`, `implements`) in einem gemeinsamen Navigationsmodell. Über die MCP-Tools
`atlas_relations` und `atlas_slice` können Agenten direkt in dieses Netz einsteigen.

**Was in der Desktop-App fehlt:**
Die Views `AtlasView`, `OverviewView` und `TrendView` zeigen Token-Metriken und Aktivitäten, aber keine
strukturellen Relationen zwischen Dateien oder Dokumenten.

**Vorgeschlagene Erweiterung:**
1. `AtlasView` um einen `RelationSummary`-Block erweitern (Top-5 Dateien mit den meisten eingehenden
   Relationen, geladen aus dem `repository_graph`-Modul des `projectatlas-db`-Crates).
2. Im Frontend eine neue „Relations"-Sektion im Detailbereich ergänzen, die den Graphen als
   kompakte Liste darstellt.
3. Klickziel für einen Relation-Drill-Down anlegen, der per Tauri-Kommando die direkten Nachbarn
   einer Datei zurückgibt.

**Warum P3:**
Macht den strukturellen Mehrwert des Atlas für Desktop-Nutzer sichtbar, die heute nur Token-Zahlen
sehen.

---

### P4 – Exakte Dokument-Referenzen über Heading-Selektoren im UI unterstützen

**Was es ist:**
`styler-ai/ProjectAtlas` unterstützt Heading-basierte Selektoren (z. B. `docs/workflow.md#quick-start`),
die Agenten direkt zu einem Abschnitt einer Dokumentation führen, ohne die ganze Datei lesen zu müssen.
Das spart Tokens und beschleunigt Navigation.

**Was in der Desktop-App fehlt:**
Wenn die Desktop-App eine Datei im Projekt anzeigt oder verlinkt, gibt es keinen Mechanismus, um direkt
auf einen Abschnitt zu verweisen. Klick auf einen Eintrag öffnet das Dateisystem-Verzeichnis, nicht einen
präzisen Dokument-Punkt.

**Vorgeschlagene Erweiterung:**
1. Im `query`-Modul eine `headings(db_path, root, file_path)`-Funktion ergänzen, die alle Heading-Anker
   einer Markdown-Datei aus dem Store zurückgibt.
2. Im Frontend einen „Abschnitt"-Picker (Dropdown) neben relevanten Dokument-Links anzeigen.
3. Den Clipboard-Copy-Button so erweitern, dass er wahlweise `<datei>#<heading>` als Selektor kopiert,
   bereit zum Einfügen in ein Agent-Prompt oder ein MCP-Tool-Argument.

**Warum P4:**
Ergänzt P3: erst Relationen, dann präzise Sprungziele innerhalb von Dokumenten.

---

### P5 – Agent-Routing nach Purpose im Desktop-Schnellzugriff

**Was es ist:**
`styler-ai/ProjectAtlas` leitet Agenten über `atlas_session_brief` und `atlas_folders` zu den
Purpose-relevantesten Ordnern, bevor ein Vollscan gestartet wird. Dieses Routing-Modell lässt sich auf
die Desktop-Oberfläche übertragen: Nutzer und Agenten sollen schnell zu „wo ist hier der Test-Code?" oder
„zeig mir alles mit Purpose `config`" gelangen.

**Was in der Desktop-App fehlt:**
Es gibt keine Purpose-Filterung in der Sidebar oder in der Atlas-Map. Alle Projekte werden gleichrangig
ohne thematische Filterung gezeigt.

**Vorgeschlagene Erweiterung:**
1. In `commands.rs` ein neues Tauri-Kommando `list_projects_by_purpose(purpose: String)` ergänzen, das
   nur Projekte zurückgibt, in denen eine Purpose-Kategorie mindestens einen Eintrag hat.
2. In der Sidebar ein Purpose-Filter-Dropdown ergänzen, das die Liste live einschränkt.
3. In der Atlas-Map Purpose-Badges neben den Projekteinträgen anzeigen, analog zum vorhandenen
   `ProjectStatusView`-Badge.

**Warum P5:**
Schließt den Kreis: Purpose-Daten (P1) werden nicht nur angezeigt, sondern als Routing-Achse verwendet.

---

### P6 – Token- und Effizienz-Reporting im Desktop vertiefen

**Was es ist:**
`styler-ai/ProjectAtlas` liefert über `atlas_session_brief` und das TUI-Dashboard detaillierte
Aufschlüsselungen nach Bucket, Baseline-Szenario und Kalibrier-Stand. Die Desktop-App zeigt heute bereits
`OverviewView` und `TrendView`, aber die Darstellung bleibt auf Gesamtzahlen begrenzt.

**Was in der Desktop-App fehlt:**
- Keine Bucket-Aufschlüsselung in der Trend-Ansicht
- Kein Kalibrier-Hinweis in der Overview, wenn noch keine Tokenizer-Kalibrierung stattgefunden hat
- Kein direkter Link zu „Kalibrierung starten"

**Vorgeschlagene Erweiterung:**
1. `TrendView` erweitern, um die vorhandenen `BucketView`-Daten (bereits in `view.rs` definiert)
   im Frontend zu rendern.
2. In `OverviewView` einen sichtbaren Kalibrier-Hinweis-Block ergänzen, wenn
   `calibration` in der View `None` ist.
3. Einen „Kalibrierung starten"-Button auf der Overview-Seite verdrahten, der das vorhandene
   `calibrate`-Kommando auslöst.

**Warum P6 (niedrigste Priorität):**
Die Infrastruktur ist bereits vorhanden (`BucketView`, `CalibrationView`, `calibrate`-Kommando), der
Aufwand ist daher gering. Dennoch niedriger priorisiert, weil keine neue Datenstruktur benötigt wird
und Token-Reporting heute bereits funktioniert.

---

## Abhängigkeiten zwischen den Kandidaten

```
P2 (Migrationen)
  └── P1 (Purpose-Metadaten)
        ├── P3 (Relationen)
        │     └── P4 (Heading-Selektoren)
        └── P5 (Purpose-Routing)
P6 (Token-Reporting) – unabhängig
```

P2 sollte vor P1 implementiert werden, damit das neue Purpose-Feld sauber migriert werden kann.
P3 und P5 können parallel zu P4 starten, sobald P1 fertig ist.
P6 kann jederzeit unabhängig umgesetzt werden.

## Zerlegung in Sub-Issues

Jeder Kandidat entspricht genau einem Issue. Empfohlene Titel:

| Issue | Titel |
|-------|-------|
| P1 | `feat(registry): Purpose-Zusammenfassung pro Projekt in RegisteredProject und Sidebar` |
| P2 | `feat(registry): Atomare Registry-Migrationen mit Versions-Handler` |
| P3 | `feat(desktop): Source- und Dokument-Relationen in AtlasView anzeigen` |
| P4 | `feat(desktop): Heading-Selektoren für Dokument-Referenzen im UI` |
| P5 | `feat(commands): list_projects_by_purpose und Purpose-Filter in der Sidebar` |
| P6 | `feat(desktop): Bucket-Aufschlüsselung und Kalibrier-Hinweis in Overview/Trend` |

## Nicht-Ziele dieses Requests

- Keine Änderungen an CLI- oder MCP-Kommando-Namen.
- Keine Einführung einer Python- oder Node.js-Implementierung.
- Kein automatisches Purpose-Setzen ohne explizite Nutzer- oder Agent-Bestätigung.
- Kein Ersetzen von SQLite, `serde_json`, `tauri`, `ignore` oder anderen bestehenden
  Abhängigkeiten.
- Keine Änderungen an der `styler-ai/ProjectAtlas`-Upstream-Codebasis.

## Akzeptanzkriterien

- Alle sechs Kandidaten sind als priorisierte Vorhaben mit konkretem Änderungs-Scope beschrieben.
- Die Abhängigkeitsreihenfolge ist explizit dokumentiert.
- Jeder Kandidat kann direkt in ein eigenständiges Issue mit Titel, Kontext und Änderungs-Scope
  überführt werden.
- Keine bestehenden Registrierungs-, Scan- oder Token-Report-Funktionen werden durch diesen
  Request beschädigt.
