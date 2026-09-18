# STAND — ProjectAtlas Desktop

Stand: 17.09.2026

## Timo muss entscheiden / tun

- **Windows Sandbox aktivieren (Admin):** Windows-Features → „Windows-Sandbox“ → Neustart. Ohne das
  lässt sich die Clean-Windows-Prüfung nicht live testen.

## Offen

- **Öffentlicher Release:** Umbau gebaut, nicht committet (Branch `claude/festive-poitras-cb8c98`):
  Draft ohne Tag → Windows-Sandbox-Prüfung → Promotion. Die Gate-, Paket- und Installtests sind grün (17.09.2026).
  Offen: Sandbox-Live-Lauf, Commit/PR, `projects.json` der Zentrale (Timeout 5400 → 11400 s, neue
  rollbackPaths), Regeltext in AGENTS.md und DEPLOY-RICHTLINIE.md. Die Vorschläge liegen im Sitzungs-Scratchpad.
- Release-Repo `einzigTimo/projectatlas-desktop-releases` hat noch keinen einzigen Release.
- **Token-Report nur mit Messwerten** (Timo, 17.09.2026): hochgerechnete Ersparnis („directory_walk“,
  „modeled_avoidance“) raus, nur echt gemessene Werte zeigen. Dazu die Diagnose, ob Atlas falsch gebaut
  ist oder falsch genutzt wird. Gebaut in Worktree `atlas-token-messwerte`, nicht committet. Diagnose:
  überwiegend Bau (unfokussierte Ausgaben). Offen: e2e 4 Installer-Tests rot (gegen main ungeprüft),
  openspec `token-impact-estimate-reporting`, Frontend-Beschriftung „Tokens“, README-Aussage „über 90 %“.

## Zuletzt erledigt

- 17.09.2026: Analyse des Release-Blockers; Entscheidung Windows Sandbox als saubere Umgebung.
- Lokales Windows-Update 0.2.3 über die Zentrale abgesichert (#51–#53).
