# ProjectAtlas Desktop – Innovation-Übernahme-Request

Closes #10

## Status

Als priorisierter Request dokumentiert und im Desktop-Branch technisch umgesetzt. Die Punkte können
weiterhin getrennt reviewed oder in Sub-Issues nachverfolgt werden.
Die Abschnitte „Was fehlt" beschreiben dabei den Ausgangsstand auf `main`, gegen den die Umsetzung
geprüft wird.

## Fachliche Präzisierung

ProjectAtlas behandelt `purpose` nicht als feste Kategorie. Ein Purpose ist eine freie, kurze
Verantwortungsbeschreibung für eine Datei oder einen Ordner und besitzt zusätzlich einen Lifecycle-Status
(`approved`, `suggested`, `stale`, `missing`) sowie eine Herkunft. Technische Dateirollen wie Quellcode,
Dokumentation oder Konfiguration gehören zur separaten `ContentClassification`. Desktop-Anzeigen und
Routing dürfen diese beiden Achsen nicht vermischen.

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
`styler-ai/ProjectAtlas` versieht Dateien und Ordner mit freien Purpose-Beschreibungen und einem
prüfbaren Lifecycle-Status. Diese Verantwortungsbeschreibungen helfen Agenten bei der inhaltlichen
Priorisierung und ermöglichen gezielte Health-Checks. Sie sind keine technische Dateiklassifikation.

**Was in der Desktop-App fehlt:**
Die `RegisteredProject`-Struktur und die Sidebar zeigen heute kein Purpose-Feld. Das bedeutet, dass die
Desktop-App keine Aussage darüber machen kann, welche Dateien und Ordner eines Projekts für Agenten
primär relevant sind.

**Vorgeschlagene Erweiterung:**
1. `RegisteredProject` um ein optionales `purpose_summary`-Feld erweitern
   (Abdeckung nach `approved`, `suggested`, `stale` und `missing`, gelesen aus dem `AtlasStore`).
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
Der vorhandene Desktop-Atlas liest bereits einen begrenzten Repository-Graphen, verliert im UI aber
Relationstyp, Richtung und vollständigen Pfad. Ein Datei-Drill-down zwischen Code und Dokumentation fehlt.

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
1. Im `query`-Modul eine begrenzte Heading-Abfrage ergänzen, die bereits indizierte
   `SymbolKind::Heading`-Einträge samt stabiler Signatur aus dem Store zurückgibt. Kein zweiter
   Markdown-Parser im Desktop.
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
die Desktop-Oberfläche übertragen: Nutzer und Agenten sollen Projekte über freie Ziele wie
„Deployment vorbereiten" oder „Registry stabil migrieren" eingrenzen können.

**Was in der Desktop-App fehlt:**
Es gibt keine Purpose-Filterung in der Sidebar oder in der Atlas-Map. Alle Projekte werden gleichrangig
ohne thematische Filterung gezeigt.

**Vorgeschlagene Erweiterung:**
1. In `commands.rs` ein neues Tauri-Kommando `list_projects_by_purpose(purpose: String)` ergänzen, das
   Purpose-Texte case-insensitiv durchsucht und nur passende Projekte zurückgibt. Pfade, Quelltext und
   technische Content-Klassifikationen dürfen keine falschen Treffer erzeugen.
2. In der Sidebar eine freie Purpose-Suche ergänzen, die die Liste live einschränkt, ohne die aktive
   Projektauswahl oder den vollständigen Projektkatalog zu ersetzen.
3. In den Sidebar-Projekteinträgen Purpose-Abdeckung und Lifecycle-Status kompakt anzeigen, analog zum
   vorhandenen `ProjectStatusView`-Status.

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
- Der vorhandene Kalibrierbereich ist bei aufgezeichneten Aufrufen ohne Kalibrierung nicht prominent
- Kein direkter Kalibrier-Aufruf unmittelbar am Hinweis

**Vorgeschlagene Erweiterung:**
1. `TrendView` erweitern, um die vorhandenen `BucketView`-Daten (bereits in `view.rs` definiert)
   im Frontend zu rendern.
2. In `OverviewView` einen sichtbaren Kalibrier-Hinweis-Block ergänzen, wenn
   `calibration` in der View `None` ist.
3. Den vorhandenen Kalibrier-Ablauf zusätzlich direkt aus dem prominenten Overview-Hinweis aufrufbar
   machen; die Messung bleibt ausdrücklich nutzergesteuert.

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
