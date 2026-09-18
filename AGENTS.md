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

## Einziger Auslieferungsweg: lokales Windows-Update

Übergreifend gilt `%USERPROFILE%\Projects\Deployment-Controller\DEPLOY-RICHTLINIE.md`.
Timo-Entscheidung 18.09.2026 „GitHub raus aus allen Wegen“: GitHub ist für Auslieferung und
Betrieb kein Gate mehr. Push bleibt freiwillige Sicherung, nie Voraussetzung.

- Der öffentliche Release `projectatlas-desktop/desktop-release/prod`
  (`github-release/projectatlas-desktop-releases`) ist seit 18.09.2026 **stillgelegt** und in der
  Zentrale nicht mehr registriert. Keine GitHub-Releases, keine Uploads, keine Produktiv-Tags.
  Nicht ohne neuen ausdrücklichen Auftrag wieder aufnehmen.
- Kein Aufruf von `.github/scripts/invoke-desktop-release.ps1 -Publish`, `gh workflow run`,
  `gh release create/upload`, Produktiv-Tag-Push oder anderem Veröffentlichungsweg. Die
  `-Publish`-Sperre im Wrapper bleibt fail-closed bestehen. Ein lokaler Probebau ohne `-Publish`
  bleibt zulässig. `.github/workflows/release.yml` veröffentlicht nichts.
- Umfasst der aktuelle Auftrag die Auslieferung, darf das lokale Update nach grünen Projekt-Gates
  ohne erneute Chat-Rückfrage über
  `%USERPROFILE%\Projects\Deployment-Controller\scripts\Request-CentralDeploy.ps1` persistent
  vorgemerkt werden. Die Vormerkung ist an kanonischen Controller-Root, Zielidentität und exakten
  lokalen Commit gebunden und zeitlich begrenzt; Drift oder Ablauf stoppen fail-closed.
- Technische Plattform- und Systemfreigaben sowie die Fail-closed-Gates der Zentrale bleiben von der
  Regel „keine zweite Chat-Genehmigung“ unberührt.

## Persönliches lokales Windows-Update

Der Updateweg benötigt keinen zweiten Windows-Rechner. Er läuft ausschließlich über die Develop
Zentrale mit der Zielidentität `projectatlas-desktop/desktop-app/prod` und der lokalen
Ressourcenbindung `local-windows/projectatlas-desktop-local`.

- Quelle ist ein sauberer lokaler `main`, dessen HEAD exakt dem gebundenen Commit entspricht. Kein
  `git fetch`, kein `ls-remote`, kein `gh`, keine Remote-Prüfung; ein fehlender oder abweichender
  Remote blockiert nicht.
- An die Stelle der früheren GitHub-CI treten die lokalen Prechecks der Zentrale gegen exakt diesen
  Commit: Quell-/Versionsbindung, `cargo fmt --check`, strict-strings-Lint, `cargo check`,
  `clippy -D warnings` und Tests des Desktop-Crates sowie die projektlokalen PowerShell-Gate-Tests.
- Versionen in `crates/projectatlas-desktop/Cargo.toml` und `tauri.conf.json` sind identisch,
  `RELEASE_NOTES.md` nennt die Version.
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
- Kein Upload, kein GitHub-Release und kein Produktiv-Tag. Das Update ist keine Freigabe zur
  Weitergabe an andere Rechner.
