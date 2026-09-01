#Requires -Version 7
<#
.SYNOPSIS
    Prueft den gebuendelten ProjectAtlas-Sidecar auf einem frischen Projektordner.

.DESCRIPTION
    Der Test bildet den nicht-grafischen Kern der Desktop-Ersteinrichtung nach:
    Ein Nutzer waehlt einen Unterordner eines neuen Git-Projekts, der Sidecar ermittelt
    den kanonischen Root, erzeugt Datenbank, lokalen Index und Host-Konfigurationen und
    darf einen zweiten Lauf ohne Konfigurationsdrift ueberstehen. Alles geschieht in
    einem eindeutig begrenzten temporaeren Ordner; weder Benutzer-Registry noch echte
    Projekte werden veraendert.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SidecarPath = (Join-Path $PSScriptRoot '..\crates\projectatlas-desktop\binaries\projectatlas-cli-x86_64-pc-windows-msvc.exe'),

    [Parameter(Mandatory = $false)]
    [switch]$KeepEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Prozess konnte nicht gestartet werden: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.GetAwaiter().GetResult()
            Stderr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Read-InitReport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$ProcessResult
    )

    if ($ProcessResult.ExitCode -ne 0) {
        throw "projectatlas init ist mit Exitcode $($ProcessResult.ExitCode) fehlgeschlagen: $($ProcessResult.Stderr.Trim())"
    }
    try {
        $payload = $ProcessResult.Stdout | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "projectatlas init lieferte kein gueltiges JSON: $($ProcessResult.Stdout.Trim())"
    }
    $initProperty = $payload.PSObject.Properties['init']
    $report = if ($null -ne $initProperty) { $initProperty.Value } else { $payload }
    if (-not [bool]$report.ok) {
        throw 'projectatlas init meldete mindestens eine fehlgeschlagene Phase.'
    }
    return $report
}

function Get-ConfigHashes {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $relativePaths = @(
        '.mcp.json',
        '.projectatlas\config.toml',
        '.projectatlas\projectatlas-nonsource-files.toon',
        '.projectatlas\projectatlas.mcp.json',
        '.projectatlas\projectatlas.claude.mcp.json',
        '.projectatlas\projectatlas.opencode.json'
    )
    $hashes = [ordered]@{}
    foreach ($relativePath in $relativePaths) {
        $path = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Erwartete Ersteinrichtungsdatei fehlt: $relativePath"
        }
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return $hashes
}

$resolvedSidecar = (Resolve-Path -LiteralPath $SidecarPath -ErrorAction Stop).Path
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/')
$testRoot = Join-Path $tempBase ("projectatlas-desktop-first-run-{0}" -f [Guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot).TrimEnd([char]'\', [char]'/')
$safePrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedTestRoot.StartsWith($safePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsicherer temporaerer Testpfad wurde verworfen: $resolvedTestRoot"
}

[void](New-Item -ItemType Directory -Path $resolvedTestRoot)
try {
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $gitResult = Invoke-CapturedProcess -FilePath $git.Source -WorkingDirectory $resolvedTestRoot -Arguments @('init', '--quiet')
    if ($gitResult.ExitCode -ne 0) {
        throw "Temporäres Git-Projekt konnte nicht erzeugt werden: $($gitResult.Stderr.Trim())"
    }

    $nestedRoot = Join-Path $resolvedTestRoot 'src'
    [void](New-Item -ItemType Directory -Path $nestedRoot)
    Set-Content -LiteralPath (Join-Path $nestedRoot 'lib.rs') -Encoding utf8 -Value 'pub fn first_run_probe() {}'
    $foreignMcp = [ordered]@{
        mcpServers = [ordered]@{
            existing = [ordered]@{
                command = 'existing-tool'
                args    = @('--keep')
            }
        }
    }
    $foreignMcp | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedTestRoot '.mcp.json') -Encoding utf8

    $first = Invoke-CapturedProcess -FilePath $resolvedSidecar -WorkingDirectory $nestedRoot -Arguments @('--format', 'json', 'init')
    $firstReport = Read-InitReport -ProcessResult $first
    $reportedRoot = [System.IO.Path]::GetFullPath([string]$firstReport.root).TrimEnd([char]'\', [char]'/')
    if (-not $reportedRoot.Equals($resolvedTestRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Init meldete '$reportedRoot' statt des kanonischen Git-Roots '$resolvedTestRoot'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedTestRoot '.projectatlas\projectatlas.db') -PathType Leaf)) {
        throw 'Die Ersteinrichtung hat keine ProjectAtlas-Datenbank erzeugt.'
    }
    $scanProperty = $firstReport.PSObject.Properties['scan']
    if ($null -eq $scanProperty) {
        throw 'Der Init-Bericht enthaelt keinen Scan-Nachweis.'
    }
    $scanReport = $scanProperty.Value
    if (-not [bool]$scanReport.requested -or [string]$scanReport.status -ne 'verified') {
        throw 'Der erste Einrichtungslauf hat den standardmaessigen lokalen Scan nicht bestaetigt.'
    }
    if ([int]$scanReport.report.overview.files -lt 1) {
        throw 'Der erste Einrichtungslauf hat die Test-Quelldatei nicht in den lokalen Index aufgenommen.'
    }

    $mergedMcp = Get-Content -LiteralPath (Join-Path $resolvedTestRoot '.mcp.json') -Raw | ConvertFrom-Json -Depth 100
    if ([string]$mergedMcp.mcpServers.existing.command -ne 'existing-tool') {
        throw 'Die Ersteinrichtung hat einen vorhandenen fremden MCP-Server nicht bewahrt.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$mergedMcp.mcpServers.projectatlas.command)) {
        throw 'Die Ersteinrichtung hat ProjectAtlas nicht in der Root-.mcp.json registriert.'
    }

    $hashesBefore = Get-ConfigHashes -ProjectRoot $resolvedTestRoot
    $second = Invoke-CapturedProcess -FilePath $resolvedSidecar -WorkingDirectory $nestedRoot -Arguments @('--format', 'json', 'init', '--no-scan')
    [void](Read-InitReport -ProcessResult $second)
    $hashesAfter = Get-ConfigHashes -ProjectRoot $resolvedTestRoot
    foreach ($relativePath in $hashesBefore.Keys) {
        if ($hashesBefore[$relativePath] -ne $hashesAfter[$relativePath]) {
            throw "Der zweite Init-Lauf veraenderte die bestehende Konfiguration: $relativePath"
        }
    }

    Write-Host 'ProjectAtlas-Desktop-First-Run: PASS' -ForegroundColor Green
    Write-Host "Kanonischer Test-Root: $resolvedTestRoot"
}
finally {
    if ($KeepEvidence) {
        Write-Host "Testdaten bleiben zur Nachpruefung erhalten: $resolvedTestRoot" -ForegroundColor Yellow
    }
    elseif (Test-Path -LiteralPath $resolvedTestRoot) {
        $finalTarget = [System.IO.Path]::GetFullPath($resolvedTestRoot).TrimEnd([char]'\', [char]'/')
        if (-not $finalTarget.StartsWith($safePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsicherer Bereinigungspfad wurde blockiert: $finalTarget"
        }
        Remove-Item -LiteralPath $finalTarget -Recurse -Force
    }
}
