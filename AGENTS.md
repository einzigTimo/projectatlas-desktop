# ProjectAtlas Desktop — Arbeitsregeln

Diese Datei ist die verbindliche, agent-neutrale Regelquelle für Codex, Claude Code und weitere
Agenten in diesem Repository. `CLAUDE.md` importiert ausschließlich diese Datei.

## Sprache

- Antworte in diesem Repository immer auf Deutsch, sofern der Nutzer nicht ausdrücklich eine andere
  Sprache verlangt.
- Commit-Messages, PR-Titel, PR-Beschreibungen, Reviews und neue Dokumentation sind deutsch.
- Technische Bezeichner, Code, Dateinamen, Pfade, Befehle und bestehende englische Inhalte werden
  nicht ungefragt übersetzt. UI-Texte folgen der jeweiligen Produktsprache.

## Pull Requests

- Lege für abgeschlossene Arbeit auf einem Feature-Branch einen Pull Request an, sobald der Branch
  gepusht und prüfbar ist. Ausnahme: Der Nutzer schließt einen PR ausdrücklich aus.
- Titel und Beschreibung sind deutsch und verwenden `.github/pull_request_template.md` als
  Gliederung. Checklistenpunkte nur bei tatsächlichem Nachweis abhaken; sonst als nicht zutreffend
  oder offen kennzeichnen.
- Ein Feature-Branch-Push ist reine Quellcodeübertragung, solange er keinen produktiven Workflow
  auslöst. Er ist kein Deployment.

## Einziger Release- und Deployweg

Übergreifend gilt `%USERPROFILE%\Projects\Deployment-Controller\DEPLOY-RICHTLINIE.md`.

- Jeder produktive Release von ProjectAtlas Desktop läuft ausschließlich über die Develop Zentrale,
  Ziel `projectatlas-desktop/desktop-release/prod` mit der Ressourcenbindung
  `github-release/projectatlas-desktop-releases`. Die Veröffentlichung und das persönliche lokale
  Windows-Update sind bewusst getrennte Komponenten desselben Projekts: Ein Preflight der einen
  autorisiert die andere nicht, und beide können nebeneinander registriert bleiben.
- Umfasst der aktuelle Auftrag die Auslieferung, darf sie nach grünen Projekt-Gates ohne erneute
  Chat-Rückfrage über den Controller-Helper
  `%USERPROFILE%\Projects\Deployment-Controller\scripts\Request-CentralDeploy.ps1` mit dem Ziel
  `projectatlas-desktop-release` persistent vorgemerkt werden. Die Zentrale prüft, startet seriell und
  überwacht; sie ist keine zweite fachliche Freigabestufe. Umfasst der aktuelle Auftrag keine
  Auslieferung, darf daraus keine Vormerkung abgeleitet werden.
- Jede persistente Vormerkung ist an den kanonischen Controller-Root, die vollständige Zielidentität
  `projectatlas-desktop/desktop-release/prod` und den exakten, bei der Vormerkung geprüften
  `origin/main`-Commit gebunden sowie zeitlich begrenzt. Root-, Ziel- oder Commit-Drift und der
  Ablauf der Attestierung stoppen fail-closed; für den neuen Stand ist eine neue Vormerkung nötig.
- Kein direkter Aufruf von `.github/scripts/invoke-desktop-release.ps1 -Publish`, `gh workflow run`,
  `gh release create/upload`, Produktiv-Tag-Push oder anderer Veröffentlichungsweg. Ein lokaler
  Probebau ohne `-Publish` bleibt zulässig.
- Die CLI/MCP-Veröffentlichung über `.github/workflows/release.yml` ist bis zu ihrer Einbindung in
  die Develop Zentrale stillgelegt. Erlaubt sind dort nur nicht veröffentlichende Vorprüfungen;
  weder Tags noch GitHub-Releases oder Assets dürfen aus dem Workflow publiziert werden.
- Der Release-Wrapper muss bei `-Publish` ohne frisches, ziel- und commitgebundenes
  Zentrale-Preflight-Artefakt fail-closed abbrechen. Die Zentrale darf nur einen sauberen, vollständig
  gepushten `main`-Stand veröffentlichen.
- Vor der Vormerkung müssen CI und projektspezifische Tests grün, der kanonische Controller-Checkout
  sauber und aktuell, Versionen in `crates/projectatlas-desktop/Cargo.toml` und
  `crates/projectatlas-desktop/tauri.conf.json` identisch sowie `RELEASE_NOTES.md` aktuell sein.
- Installer, Signatur, Updater-Manifest und commitgebundene SHA-256-Provenienz müssen nach dem
  Release live verifiziert werden. Ein Upload oder erfolgreicher Prozess allein ist kein
  Produktivnachweis.
- `-Publish` bleibt fail-closed blockiert, bis der Controller einen zweiphasigen Ablauf aus
  privatem Draft, unabhängiger Clean-Windows-Attestierung und erst danach ausgeführter Promotion
  implementiert. Eine Prüfung erst nach der öffentlichen Freigabe genügt nicht.
- Technische Plattform- und Systemfreigaben sowie die Fail-closed-Gates der Zentrale bleiben von der
  Regel „keine zweite Chat-Genehmigung“ unberührt.

## Persönliches lokales Windows-Update

Der ausdrücklich beauftragte lokale Updateweg benötigt keinen zweiten Windows-Rechner. Er läuft
weiterhin ausschließlich über die Develop Zentrale mit der Zielidentität
`projectatlas-desktop/desktop-app/prod`, aber mit der eindeutigen lokalen Ressourcenbindung
`local-windows/projectatlas-desktop-local`. Ein Preflight für `github-release` autorisiert ihn nicht.

- Nur sauberer, vollständig gepushter `main == origin/main` mit grüner CI für exakt diesen Commit.
- Der letzte registrierte Precheck baut vor Ausstellung des kurzlebigen Preflights das Paket über
  `scripts/Prepare-ProjectAtlasDesktopLocal.ps1`. Ein Probebau installiert nichts.
- Der registrierte `scripts/Install-ProjectAtlasDesktopLocal.ps1` aktualisiert ausschließlich die
  vorhandene Benutzerinstallation unter `%LOCALAPPDATA%\ProjectAtlas Desktop`.
- Für diesen Rechner darf das bereits lokal vertrauenswürdige, im Preflight gepinnte
  Code-Signing-Zertifikat verwendet werden. Keine neue Vertrauenswurzel importieren. Gültige
  Authenticode-Signaturen, Zeitstempel und Tauri-Updatersignatur bleiben erforderlich.
- Vorherige Installation und betroffene Windows-Einträge werden gesichert. Die installierten
  Programmdateien müssen exakt dem gehashten Paket entsprechen. Versions-, Signatur-,
  Ersteinrichtungs- und GUI-Abnahme sind obligatorisch; Fehler lösen eine geprüfte Wiederherstellung
  aus. Projektquellen, Projektindizes und die persönliche Projektliste sind keine Installationsziele.
- `scripts/Assert-ProjectAtlasDesktopInstalled.ps1` prüft das tatsächliche installierte Ergebnis
  unabhängig vom Build-Verzeichnis. Ein mit dem im Preflight gepinnten Zertifikat CMS-signiertes
  Manifest bindet Quelle, Rechner, Benutzer und sämtliche Paketdateien. Ein persistenter Beleg
  bindet zusätzlich Preflight und Backup.
- Kein Upload, kein GitHub-Release und kein Produktiv-Tag in diesem lokalen Modus. Er ist keine
  Freigabe zur Weitergabe an andere Rechner. Die öffentliche `-Publish`-Sperre bleibt bestehen.

## Migrationsgrenze für öffentliche Veröffentlichungen

Der Controller-Root darf erst von `ProjectAtlas-studio-hamburg` auf dieses Repository umgestellt
werden, wenn die zentrale Härtung auf `main` gemergt, CI grün, der saubere Controller-Checkout
synchronisiert und das Release-Ziel erreichbar ist. Bis dahin wird kein Desktop-Release vorgemerkt.
