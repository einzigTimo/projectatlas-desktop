<#
.SYNOPSIS
    Bringt alle Projekte unter einem Wurzelordner in ProjectAtlas ein und
    richtet Claude Code so ein, dass auch neue Projekte automatisch
    initialisiert werden.

.DESCRIPTION
    Teil 1 (Bestand): Laeuft ueber alle direkten Unterordner von -ProjectsRoot
    und fuehrt dort `projectatlas init` aus, wo noch keine
    .projectatlas\projectatlas.db liegt. Init erzeugt die Projekt-Datenbank,
    scannt den Quellcode und registriert den MCP-Server in der .mcp.json im
    Projektroot (dort, wo Claude Code sie automatisch laedt).

    Teil 2 (Zukunft): Traegt in ~\.claude\settings.json einen
    SessionStart-Hook ein, der beim Start jeder Claude-Code-Sitzung prueft,
    ob das aktuelle Projekt schon eine ProjectAtlas-Datenbank hat - und
    andernfalls `projectatlas init` ausfuehrt. Damit laeuft jedes neue
    Projekt automatisch durch den Atlas, sobald du es das erste Mal mit
    Claude Code oeffnest.

    Teil 3 (Nutzung): Ergaenzt ~\.claude\CLAUDE.md um die Anweisung, zur
    Orientierung zuerst die atlas_*-Tools zu verwenden. Ohne diese
    Anweisung bleibt der MCP-Server oft ungenutzt und die Token-Zaehler
    stehen auf 0.

    Das Skript ist idempotent: mehrfaches Ausfuehren richtet nichts doppelt
    ein und ueberschreibt keine fremden Eintraege.

.PARAMETER ProjectsRoot
    Wurzelordner mit den Projekten. Standard: $HOME\Projects

.PARAMETER SkipHook
    Teil 2 (SessionStart-Hook) ueberspringen.

.PARAMETER SkipClaudeMd
    Teil 3 (CLAUDE.md-Hinweis) ueberspringen.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\atlas-onboard-alle-projekte.ps1
.EXAMPLE
    .\atlas-onboard-alle-projekte.ps1 -ProjectsRoot "D:\Repos"
#>
[CmdletBinding()]
param(
    [string]$ProjectsRoot = (Join-Path $HOME "Projects"),
    [switch]$SkipHook,
    [switch]$SkipClaudeMd
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command projectatlas -ErrorAction SilentlyContinue)) {
    Write-Error "projectatlas wurde nicht im PATH gefunden. Bitte zuerst die CLI installieren/bauen."
}

# ---------- Teil 1: Bestehende Projekte initialisieren ----------
if (-not (Test-Path $ProjectsRoot)) {
    Write-Error "Projektordner nicht gefunden: $ProjectsRoot"
}

$initialized = @()
$skipped = @()
$failed = @()

Get-ChildItem -Path $ProjectsRoot -Directory | ForEach-Object {
    $project = $_.FullName
    $name = $_.Name
    $db = Join-Path $project ".projectatlas\projectatlas.db"
    if (Test-Path $db) {
        # Bereits initialisiert - init erneut ausfuehren haelt die generierten
        # Host-Configs (u.a. .mcp.json) aktuell, ohne Daten zu verlieren.
        $skipped += $name
        Push-Location $project
        try { projectatlas init --no-scan | Out-Null } catch { }
        Pop-Location
        return
    }
    Write-Host "Initialisiere: $name" -ForegroundColor Cyan
    Push-Location $project
    try {
        projectatlas init | Out-Null
        $initialized += $name
    } catch {
        $failed += "${name}: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
}

# ---------- Teil 2: SessionStart-Hook fuer neue Projekte ----------
$hookCommand = 'powershell -NoProfile -Command "if ((Test-Path .git) -and -not (Test-Path .projectatlas/projectatlas.db)) { projectatlas init | Out-Null }"'
if (-not $SkipHook) {
    $settingsPath = Join-Path $HOME ".claude\settings.json"
    $settings = if (Test-Path $settingsPath) {
        Get-Content $settingsPath -Raw | ConvertFrom-Json
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
        [pscustomobject]@{}
    }
    if (-not $settings.PSObject.Properties["hooks"]) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $settings.hooks.PSObject.Properties["SessionStart"]) {
        $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @()
    }
    $already = $settings.hooks.SessionStart | Where-Object {
        $_.hooks | Where-Object { $_.command -like "*projectatlas init*" }
    }
    if ($already) {
        Write-Host "SessionStart-Hook ist bereits eingerichtet." -ForegroundColor Yellow
    } else {
        $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + @(
            [pscustomobject]@{
                hooks = @([pscustomobject]@{ type = "command"; command = $hookCommand })
            }
        )
        $settings | ConvertTo-Json -Depth 16 | Set-Content -Path $settingsPath -Encoding UTF8
        Write-Host "SessionStart-Hook in $settingsPath eingetragen." -ForegroundColor Green
    }
}

# ---------- Teil 3: Nutzungshinweis in der globalen CLAUDE.md ----------
$atlasGuidance = @"

## ProjectAtlas
In Projekten mit ProjectAtlas (Ordner .projectatlas/ vorhanden): Nutze zur
Orientierung zuerst die atlas_*-MCP-Tools (atlas_search, atlas_file_summary,
atlas_outline, atlas_slice), bevor du ganze Dateien mit Read liest oder breit
mit Grep/Glob suchst. Exakte Quelltext-Belege danach gezielt per atlas_slice
oder Read auf die bereits eingegrenzten Stellen.
"@
if (-not $SkipClaudeMd) {
    $claudeMdPath = Join-Path $HOME ".claude\CLAUDE.md"
    $existing = if (Test-Path $claudeMdPath) { Get-Content $claudeMdPath -Raw } else { "" }
    if ($existing -match "atlas_\*-MCP-Tools") {
        Write-Host "CLAUDE.md enthaelt den ProjectAtlas-Hinweis bereits." -ForegroundColor Yellow
    } else {
        Add-Content -Path $claudeMdPath -Value $atlasGuidance -Encoding UTF8
        Write-Host "ProjectAtlas-Hinweis an $claudeMdPath angehaengt." -ForegroundColor Green
    }
}

# ---------- Zusammenfassung ----------
Write-Host ""
Write-Host "Fertig." -ForegroundColor Green
Write-Host ("  Neu initialisiert : {0}" -f ($(if ($initialized) { $initialized -join ", " } else { "-" })))
Write-Host ("  Schon vorhanden   : {0}" -f ($(if ($skipped) { $skipped -join ", " } else { "-" })))
if ($failed) {
    Write-Host ("  Fehlgeschlagen    : {0}" -f ($failed -join "; ")) -ForegroundColor Red
}
Write-Host ""
Write-Host "Hinweis: Laufende Claude-Code-Sitzungen einmal neu starten, damit die"
Write-Host "neu registrierten MCP-Server geladen werden. Das ProjectAtlas-Desktop"
Write-Host "entdeckt die initialisierten Projekte beim naechsten Scan automatisch."
