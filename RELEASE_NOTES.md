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

## Auslieferung

- Produktive Desktop-Releases laufen ausschließlich commitgebunden über die Develop Zentrale.
- Installer, Signatur, Update-Manifest, SHA-256-Provenienz und Quellcommit werden nach dem Release
  gemeinsam verifiziert.
