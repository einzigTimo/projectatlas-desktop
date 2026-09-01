# ProjectAtlas Desktop 0.2.3

Veröffentlichungsstand: 1. September 2026

## Neue Agenten-Navigation und Wissenssicht

- Purpose-Zusammenfassungen pro Projekt zeigen Abdeckung und Lifecycle-Status für Dateien und Ordner.
- Die Purpose-Suche führt Nutzer und Agenten schneller zu passenden Projekten, ohne technische
  Dateiklassifikationen mit Verantwortungsbeschreibungen zu vermischen.
- Der Atlas-Detailbereich verbindet Quellcode, Dokumentation und direkte Relationen mit Richtung,
  Relationstyp und vollständigem Pfad.
- Exakte Heading-Selektoren lassen sich für Dokumentabschnitte auswählen und in die Zwischenablage
  übernehmen.

## Daten- und Registry-Sicherheit

- Bestehende Registry-Stände werden schrittweise und verlustfrei auf das aktuelle Schema migriert.
- Registry-Schreibvorgänge ersetzen immer eine vollständige JSON-Datei; unbekannte zukünftige
  Schema-Versionen werden ohne Umschreiben abgelehnt.
- Purpose-Daten werden bei Projektprüfungen aktualisiert, ohne einen zusätzlichen vollständigen
  Dateisystemlauf zu erzwingen.

## Effizienz und Transparenz

- Trendansichten zeigen Token-Buckets und begrenzte Zeiträume nachvollziehbarer an.
- Ein sichtbarer Kalibrierungshinweis führt direkt in den nutzergesteuerten Kalibrierungsablauf.
- Lange Bezeichnungen behalten den identifizierenden hinteren Teil, damit Projekte und Pfade
  unterscheidbar bleiben.

## Installation und Ersteinrichtung

- Der Windows-x64-Installer richtet ProjectAtlas Desktop pro Benutzer ein und benötigt im
  vorgesehenen Standardablauf keine Administratorrechte.
- Bei leerer Projektliste öffnet sich die geführte Ersteinrichtung automatisch. Nach sichtbarer
  Ordnerwahl werden lokaler Atlas, Host-Konfigurationen und – standardmäßig – der erste Scan in
  einem kontrollierten Ablauf angelegt.
- Bestehende fremde MCP-Einträge bleiben beim atomaren Zusammenführen erhalten; wiederholte
  Einrichtung ist idempotent und ungültige vorhandene Konfigurationen werden nicht überschrieben.
- Die Oberfläche weist auf die entstehenden lokalen Pfade sowie den nötigen Neustart verbundener
  KI-Hosts hin und startet keinen stillen Scan eines allgemeinen Benutzerordners mehr.

## Auslieferung

- Produktive Desktop-Releases laufen ausschließlich commitgebunden über die Develop Zentrale.
- Tauri-Updater-Signatur und Windows-Authenticode-Signatur werden getrennt erzeugt und geprüft;
  produktive Ausgaben verlangen einen zentral attestierten, vertrauenswürdigen Herausgeber samt
  RFC-3161-Zeitstempel.
- Ein Release bleibt bis zur vollständigen Bindung von Git-Tag, Draft-Identität, Installer,
  Updater-Signatur, Update-Manifest und SHA-256-Provenienz privat und wird erst danach als
  unveränderlicher GitHub-Release freigegeben.
- Die tatsächliche Installation und die Signaturen der installierten Programmdateien bleiben Teil
  der verpflichtenden Abnahme auf einem sauberen Windows-x64-System.
