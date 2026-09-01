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
  Ziel `projectatlas-desktop/desktop-app/prod`.
- Umfasst der aktuelle Auftrag die Auslieferung, darf sie nach grünen Projekt-Gates ohne erneute
  Chat-Rückfrage über den Controller-Helper
  `%USERPROFILE%\Projects\Deployment-Controller\scripts\Request-CentralDeploy.ps1` mit dem Ziel
  `projectatlas-desktop` persistent vorgemerkt werden. Die Zentrale prüft, startet seriell und
  überwacht; sie ist keine zweite fachliche Freigabestufe. Umfasst der aktuelle Auftrag keine
  Auslieferung, darf daraus keine Vormerkung abgeleitet werden.
- Jede persistente Vormerkung ist an den kanonischen Controller-Root, die vollständige Zielidentität
  `projectatlas-desktop/desktop-app/prod` und den exakten, bei der Vormerkung geprüften
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
- Technische Plattform- und Systemfreigaben sowie die Fail-closed-Gates der Zentrale bleiben von der
  Regel „keine zweite Chat-Genehmigung“ unberührt.

## Aktuelle Migrationsgrenze

Der Controller-Root darf erst von `ProjectAtlas-studio-hamburg` auf dieses Repository umgestellt
werden, wenn die zentrale Härtung auf `main` gemergt, CI grün, der saubere Controller-Checkout
synchronisiert und das Release-Ziel erreichbar ist. Bis dahin wird kein Desktop-Release vorgemerkt.
