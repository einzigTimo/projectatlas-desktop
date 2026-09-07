# ProjectAtlas Desktop für Kolleg:innen installieren

Diese Anleitung gilt für die produktiv freigegebene Windows-x64-Ausgabe von ProjectAtlas
Desktop. Ein lokaler Probebau oder eine Datei ohne gültige Windows-Herausgebersignatur darf nicht
weitergegeben werden.

## Vor der Installation

- Windows x64 und ein normales Benutzerkonto genügen. Der NSIS-Installer installiert
  `currentUser`, also nur für die angemeldete Person und ohne geplante Administratorrechte.
- Die Installationsdatei muss aus dem freigegebenen ProjectAtlas-Desktop-Release stammen. Unter
  **Eigenschaften > Digitale Signaturen** muss Windows eine gültige Signatur des intern
  freigegebenen Herausgebers anzeigen. Bei „Unbekannter Herausgeber“, fehlender Signatur oder einer
  Zertifikatswarnung nicht fortfahren und die ausgebende Stelle informieren.
- ProjectAtlas Desktop verwendet Microsoft Edge WebView2. Fehlt die Laufzeit, startet der Installer
  den mitgelieferten Microsoft-Bootstrapper. Der Unternehmensproxy muss dessen Download zulassen;
  Zugangsdaten gehören in die Windows-/Unternehmens-Proxykonfiguration und niemals in die App.
- Für spätere Updateprüfungen muss der Proxy außerdem den freigegebenen GitHub-Releases-Kanal des
  Projekts zulassen. Wenn diese Ziele gesperrt sind, funktioniert die lokale Arbeit weiter, aber
  WebView2-Nachinstallation bzw. Updateabruf schlagen fehl.

## Installation und erster Start

1. Eine eventuell laufende ältere ProjectAtlas-Desktop-Ausgabe schließen.
2. Den signierten x64-Installer starten und die Installation für den aktuellen Benutzer beenden.
3. ProjectAtlas Desktop über das Startmenü öffnen.
4. Bei einer leeren lokalen Projektliste öffnet sich automatisch **ProjectAtlas einrichten**. Über
   **Projektordner wählen …** den eigenen Projektordner auswählen. Auch ein Unterordner innerhalb
   eines Git-Projekts ist zulässig; ProjectAtlas verwendet den kanonischen Projekt-Root. Später
   öffnet **+ Ordner** in der Seitenleiste denselben geführten Dialog.
5. **Index neu aufbauen (Scan)** ist beim ersten Lauf standardmäßig aktiviert. Bei großen
   Projektordnern kann die Indizierung einige Minuten dauern. Wer den Scan bewusst abwählt, erhält
   zunächst nur die Konfiguration; der lokale Index, die Karte und aufgelöste Beziehungen entstehen
   erst beim ersten vollständigen Scan.
6. Nach erfolgreicher Einrichtung Codex, Claude Code bzw. OpenCode vollständig beenden und neu
   starten, damit der jeweilige Host die neue MCP-Konfiguration lädt. Ein Windows-Neustart ist
   normalerweise nicht erforderlich.

Die Einrichtung darf wiederholt werden. Sie soll bestehende MCP-Einträge erhalten und den
ProjectAtlas-Eintrag idempotent ergänzen bzw. aktualisieren.

## Welche lokalen Dateien entstehen?

ProjectAtlas verarbeitet den Projektindex lokal. Die Desktop-App führt nur eine lokale Liste der
bekannten Projekte; Projektquelltext wird durch diese Einrichtung nicht an den Release- oder
Updatekanal übertragen.

- `%LOCALAPPDATA%\ProjectAtlasDesktop\registry.json` enthält die lokale Projektliste der
  Desktop-App.
- `<Projekt>\.projectatlas\projectatlas.db` enthält den lokalen SQLite-Index.
- Die Dateien `<Projekt>\.projectatlas\projectatlas*.json` enthalten die hostbezogenen
  MCP-Konfigurationen.
- `<Projekt>\.mcp.json` wird für die lokale Host-Anbindung atomar zusammengeführt; vorhandene,
  fremde MCP-Server sollen dabei erhalten bleiben.

Wichtig: Die erzeugte Root-Datei `<Projekt>\.mcp.json` und die Dateien
`<Projekt>\.projectatlas\projectatlas*.json` enthalten absolute lokale Benutzer- und
Installationspfade. Sie dürfen deshalb nicht ungeprüft geteilt oder committet werden. Ist eine
dieser Dateien bereits versioniert, vor jedem Commit den Diff prüfen. ProjectAtlas Desktop ändert
`.gitignore` nicht automatisch; ob und wie die lokale Host-Konfiguration versioniert wird, muss das
jeweilige Projekt bewusst festlegen.

Die später verwendeten KI-Werkzeuge können eigene Konten, Netzdienste und Datenschutzregeln haben.
Das ist von der lokalen ProjectAtlas-Einrichtung getrennt.

## Aktualisierungen

ProjectAtlas Desktop installiert Updates nicht ungefragt. Im Updatefenster wird zuerst nach einer
neuen Version gesucht und das Changelog angezeigt. Erst nach ausdrücklicher Auswahl wird das Paket
heruntergeladen, gegen den in der App hinterlegten Tauri-Updater-Schlüssel geprüft, installiert und
die App neu gestartet.

Die Tauri-Updater-Signatur und die Windows-Authenticode-Signatur sind zwei verschiedene Kontrollen:

- Die Tauri-Datei `.sig` schützt den Updatekanal technisch.
- Windows Authenticode bestätigt den Herausgeber von Installer und Programmdateien und enthält
  einen vertrauenswürdigen Zeitstempel.

Eine erfolgreiche Updateprüfung ersetzt deshalb nicht die Windows-Signaturprüfung des installierten
Programms.

## Abnahme vor der Weitergabe

Die ausgebende Stelle gibt eine Version erst weiter, wenn mindestens Folgendes aktuell belegt ist:

- Windows Authenticode ist am Installer und am gebündelten ProjectAtlas-CLI-Sidecar gültig und auf
  das freigegebene Zertifikat gebunden.
- Installation auf einem sauberen Windows-x64-System funktioniert als normaler Benutzer.
- Die tatsächlich installierte Haupt-EXE und das installierte Sidecar tragen dieselbe gültige,
  zeitgestempelte Authenticode-Signatur.
- Geführte Ordnerwahl, erster Scan, MCP-Zusammenführung und erneuter idempotenter Einrichtungslauf
  funktionieren.
- Nach Neustart des jeweiligen KI-Hosts ist ProjectAtlas erreichbar.
- Updateprüfung, Signaturprüfung, Installation und App-Neustart wurden mit der freigegebenen
  Release-Ausgabe getestet.

Ein grüner lokaler Build allein erfüllt diese Abnahme nicht.

## Wenn etwas nicht klappt

- **WebView2-Download oder Updateabruf scheitert:** Proxy-/Firewallfreigabe durch die IT prüfen
  lassen; keine Zertifikats- oder Proxywarnung umgehen.
- **Projekt wird nicht erkannt:** den Ordner innerhalb des tatsächlichen Git-Projekts erneut wählen
  und prüfen, ob er lokal erreichbar ist.
- **KI-Host sieht ProjectAtlas nicht:** Host vollständig schließen und neu starten; danach die
  Projektdateien `.mcp.json` und `.projectatlas\projectatlas.*.json` auf Vorhandensein prüfen.
- **Windows meldet einen unbekannten Herausgeber:** Installation abbrechen. Die Datei ist nicht als
  Kolleg:innen-Ausgabe nachgewiesen.
