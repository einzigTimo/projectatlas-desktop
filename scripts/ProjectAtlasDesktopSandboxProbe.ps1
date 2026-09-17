#Requires -Version 5.1
<#
.SYNOPSIS
    Laeuft INNERHALB einer frischen Windows Sandbox und prueft den Installer aus dem privaten Draft.

.DESCRIPTION
    Wird von scripts/Invoke-ProjectAtlasDesktopCleanWindowsAttestation.ps1 als LogonCommand
    gestartet. Die Sandbox enthaelt nur Windows PowerShell 5.1, kein pwsh 7 und kein git;
    das Skript ist deshalb bewusst 5.1-kompatibel und nutzt keine Werkzeuge ausser Windows.

    Es sammelt ausschliesslich Nachweise und bewertet sie NICHT abschliessend. Die
    verbindliche Bewertung macht der Host mit Test-SandboxAttestationResult.

    Ablauf: WebView2-Laufzeit feststellen, Installer-Hash und -Signatur pruefen, NSIS still
    installieren, installierte Haupt-EXE und Sidecar (Authenticode, Zeitstempel, Version),
    Ersteinrichtungs-Smoke mit dem installierten Sidecar, GUI starten und Hauptfenster
    nachweisen. Ergebnis nach result.json, danach done.marker und Herunterfahren.

    Der Ersteinrichtungs-Smoke entspricht fachlich scripts/Test-ProjectAtlasDesktopFirstRun.ps1.
    Jenes Skript verlangt pwsh 7 und git, die in der Sandbox fehlen. Das Git-Projekt wird hier
    deshalb als minimales, spezifikationsgemaesses leeres Repository (HEAD, config, objects,
    refs) angelegt - genau die Struktur, die `git init` erzeugt.
#>
[CmdletBinding()]
param(
    [string]$InputDirectory = 'C:\AtlasAttestation\input',
    [string]$ResultDirectory = 'C:\AtlasAttestation\result'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$result = [ordered]@{
    schema_version           = 'projectatlas.desktop.sandbox-result.v1'
    nonce                    = $null
    completed                = $false
    fatal_error              = $null
    started_at_utc           = [DateTime]::UtcNow.ToString('o')
    finished_at_utc          = $null
    os_version               = [Environment]::OSVersion.VersionString
    installer                = $null
    installer_exit_code      = $null
    webview2_before_install  = $null
    webview2                 = $null
    install_directory        = $null
    registry_display_version = $null
    main_executable          = $null
    sidecar                  = $null
    first_run                = [ordered]@{ passed = $false; detail = 'nicht ausgefuehrt' }
    gui                      = [ordered]@{ main_window = $false; responding = $false; title = $null }
}
$expectation = $null

function Write-ProbeLog {
    param([string]$Message)
    $line = '{0} {1}{2}' -f [DateTime]::UtcNow.ToString('o'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText((Join-Path $ResultDirectory 'sandbox.log'), $line, $utf8NoBom)
}

function Get-ProbeSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BinaryEvidence {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Erwartete Datei fehlt: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $thumbprint = $null
    if ($null -ne $signature.SignerCertificate) {
        $thumbprint = ([string]$signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    }
    return [ordered]@{
        name              = [IO.Path]::GetFileName($Path)
        path              = $Path
        sha256            = Get-ProbeSha256 -Path $Path
        signature_status  = [string]$signature.Status
        signer_thumbprint = $thumbprint
        signer_subject    = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { $null }
        timestamp_present = ($null -ne $signature.TimeStamperCertificate)
        product_version   = '{0}.{1}.{2}' -f $info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart
        file_version      = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    }
}

function Get-WebView2Evidence {
    $clientId = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $keys = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$clientId",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$clientId",
        "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$clientId"
    )
    foreach ($key in $keys) {
        $value = Get-ItemProperty -LiteralPath $key -Name 'pv' -ErrorAction SilentlyContinue
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value.pv) -and [string]$value.pv -ne '0.0.0.0') {
            return [ordered]@{ present = $true; version = [string]$value.pv; source = $key }
        }
    }
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $applicationRoot = Join-Path $programFilesX86 'Microsoft\EdgeWebView\Application'
    if (Test-Path -LiteralPath $applicationRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $applicationRoot -Directory | Sort-Object Name -Descending)) {
            $runtime = Join-Path $directory.FullName 'msedgewebview2.exe'
            if ($directory.Name -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-Path -LiteralPath $runtime -PathType Leaf)) {
                $signature = Get-AuthenticodeSignature -LiteralPath $runtime
                if ($signature.Status -eq 'Valid') {
                    return [ordered]@{ present = $true; version = $directory.Name; source = $runtime }
                }
            }
        }
    }
    return [ordered]@{ present = $false; version = $null; source = $null }
}

function Invoke-ProbeProcess {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds
    )

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Prozess konnte nicht gestartet werden: $FilePath" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "Prozess ueberschritt das Zeitlimit: $FilePath $Arguments"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.Result
            Stderr   = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Read-ProbeInitReport {
    param($ProcessResult)

    if ($ProcessResult.ExitCode -ne 0) {
        throw "projectatlas init endete mit Exitcode $($ProcessResult.ExitCode): $($ProcessResult.Stderr.Trim())"
    }
    $payload = $ProcessResult.Stdout | ConvertFrom-Json
    $initProperty = $payload.PSObject.Properties['init']
    $report = $payload
    if ($null -ne $initProperty) { $report = $initProperty.Value }
    if (-not [bool]$report.ok) { throw 'projectatlas init meldete mindestens eine fehlgeschlagene Phase.' }
    return $report
}

function Get-ProbeConfigHashes {
    param([string]$ProjectRoot)

    $hashes = [ordered]@{}
    foreach ($relativePath in @(
            '.mcp.json',
            '.projectatlas\config.toml',
            '.projectatlas\projectatlas-nonsource-files.toon',
            '.projectatlas\projectatlas.mcp.json',
            '.projectatlas\projectatlas.claude.mcp.json',
            '.projectatlas\projectatlas.opencode.json')) {
        $path = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Erwartete Ersteinrichtungsdatei fehlt: $relativePath" }
        $hashes[$relativePath] = Get-ProbeSha256 -Path $path
    }
    return $hashes
}

function ConvertTo-ProbeComparablePath {
    param([string]$Path)
    $value = [string]$Path
    if ($value.StartsWith('\\?\')) { $value = $value.Substring(4) }
    return [IO.Path]::GetFullPath($value).TrimEnd('\', '/')
}

function Invoke-FirstRunProbe {
    param([string]$SidecarPath, [string]$WorkRoot)

    $projectRoot = Join-Path $WorkRoot 'first-run-project'
    $gitDirectory = Join-Path $projectRoot '.git'
    foreach ($directory in @(
            (Join-Path $gitDirectory 'objects\info'),
            (Join-Path $gitDirectory 'objects\pack'),
            (Join-Path $gitDirectory 'refs\heads'),
            (Join-Path $gitDirectory 'refs\tags'),
            (Join-Path $projectRoot 'src'))) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'HEAD'), "ref: refs/heads/main`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $gitDirectory 'config'), "[core]`n`trepositoryformatversion = 0`n`tfilemode = false`n`tbare = false`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $projectRoot 'src\lib.rs'), "pub fn first_run_probe() {}`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.mcp.json'), '{"mcpServers":{"existing":{"command":"existing-tool","args":["--keep"]}}}', $utf8NoBom)

    $nested = Join-Path $projectRoot 'src'
    $first = Invoke-ProbeProcess -FilePath $SidecarPath -Arguments '--format json init' -WorkingDirectory $nested -TimeoutSeconds 300
    $firstReport = Read-ProbeInitReport -ProcessResult $first
    if ((ConvertTo-ProbeComparablePath ([string]$firstReport.root)) -ne (ConvertTo-ProbeComparablePath $projectRoot)) {
        throw "Init meldete einen anderen Root als das Testprojekt: $($firstReport.root)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.projectatlas\projectatlas.db') -PathType Leaf)) {
        throw 'Die Ersteinrichtung hat keine ProjectAtlas-Datenbank erzeugt.'
    }
    $scanProperty = $firstReport.PSObject.Properties['scan']
    if ($null -eq $scanProperty -or -not [bool]$scanProperty.Value.requested -or
        [string]$scanProperty.Value.status -ne 'verified' -or [int]$scanProperty.Value.report.overview.files -lt 1) {
        throw 'Der erste Einrichtungslauf hat den lokalen Scan nicht bestaetigt.'
    }
    $mcp = [IO.File]::ReadAllText((Join-Path $projectRoot '.mcp.json')) | ConvertFrom-Json
    if ([string]$mcp.mcpServers.existing.command -ne 'existing-tool' -or
        [string]::IsNullOrWhiteSpace([string]$mcp.mcpServers.projectatlas.command)) {
        throw 'Die Ersteinrichtung hat die Root-.mcp.json nicht korrekt zusammengefuehrt.'
    }
    $before = Get-ProbeConfigHashes -ProjectRoot $projectRoot
    $second = Invoke-ProbeProcess -FilePath $SidecarPath -Arguments '--format json init --no-scan' -WorkingDirectory $nested -TimeoutSeconds 300
    [void](Read-ProbeInitReport -ProcessResult $second)
    $after = Get-ProbeConfigHashes -ProjectRoot $projectRoot
    foreach ($key in $before.Keys) {
        if ($before[$key] -ne $after[$key]) { throw "Der zweite Init-Lauf veraenderte $key." }
    }
}

function Test-ProbeMainWindow {
    param([string]$ExecutablePath)

    $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    try {
        do {
            Start-Sleep -Milliseconds 500
            $process.Refresh()
            if ($process.HasExited) { throw "Installierte App wurde vor der Fensterabnahme mit Exitcode $($process.ExitCode) beendet." }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.Responding) {
                return [ordered]@{ main_window = $true; responding = $true; title = [string]$process.MainWindowTitle }
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        return [ordered]@{ main_window = $false; responding = [bool]$process.Responding; title = $null }
    }
    finally {
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(10000)) {
                try { $process.Kill() } catch { }
            }
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $ResultDirectory -PathType Container)) {
        throw 'Ergebnisordner der Sandbox fehlt.'
    }
    Write-ProbeLog 'Sandbox-Pruefung gestartet.'
    $expectation = [IO.File]::ReadAllText((Join-Path $InputDirectory 'expectation.json')) | ConvertFrom-Json
    if ([string]$expectation.schema_version -ne 'projectatlas.desktop.sandbox-expectation.v1') {
        throw 'Unbekanntes Erwartungsschema.'
    }
    $result.nonce = [string]$expectation.nonce
    if ([string]$expectation.installer_name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$') {
        throw 'Installername ist ungueltig.'
    }

    $result.webview2_before_install = Get-WebView2Evidence
    Write-ProbeLog "WebView2 vor Installation: $($result.webview2_before_install.present) $($result.webview2_before_install.version)"

    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ('atlas-attestation-' + [Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $workRoot)
    $installerCopy = Join-Path $workRoot ([string]$expectation.installer_name)
    Copy-Item -LiteralPath (Join-Path $InputDirectory ([string]$expectation.installer_name)) -Destination $installerCopy
    $result.installer = Get-BinaryEvidence -Path $installerCopy
    if ($result.installer.sha256 -ne [string]$expectation.installer_sha256) {
        throw 'Installer-Hash in der Sandbox weicht vom Draft-State ab.'
    }

    Write-ProbeLog 'Stille NSIS-Installation startet.'
    $installerProcess = Start-Process -FilePath $installerCopy -ArgumentList '/S' -PassThru
    $null = $installerProcess.Handle
    if (-not $installerProcess.WaitForExit(900000)) {
        try { $installerProcess.Kill() } catch { }
        throw 'NSIS-Installation ueberschritt 15 Minuten.'
    }
    $result.installer_exit_code = [int]$installerProcess.ExitCode
    Write-ProbeLog "NSIS-Exitcode: $($result.installer_exit_code)"
    # Fehlt WebView2 auf einem frischen System, installiert der NSIS-Bootstrapper sie nach
    # (Netzbedarf). Massgeblich ist deshalb der Zustand nach der Installation.
    $result.webview2 = Get-WebView2Evidence
    Write-ProbeLog "WebView2 nach Installation: $($result.webview2.present) $($result.webview2.version)"

    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ProjectAtlas Desktop'
    $registration = Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction SilentlyContinue
    $installDirectory = Join-Path $env:LOCALAPPDATA 'ProjectAtlas Desktop'
    if ($null -ne $registration) {
        $result.registry_display_version = [string]$registration.DisplayVersion
        $locationProperty = $registration.PSObject.Properties['InstallLocation']
        if ($null -ne $locationProperty -and -not [string]::IsNullOrWhiteSpace([string]$locationProperty.Value)) {
            $installDirectory = ([string]$locationProperty.Value).Trim('"')
        }
    }
    $result.install_directory = $installDirectory

    $mainExecutable = Join-Path $installDirectory 'projectatlas-desktop.exe'
    $sidecar = Join-Path $installDirectory 'projectatlas-cli.exe'
    $result.main_executable = Get-BinaryEvidence -Path $mainExecutable
    $result.sidecar = Get-BinaryEvidence -Path $sidecar

    try {
        Invoke-FirstRunProbe -SidecarPath $sidecar -WorkRoot $workRoot
        $result.first_run = [ordered]@{ passed = $true; detail = 'Init, Scan, MCP-Zusammenfuehrung und driftfreier Zweitlauf bestaetigt.' }
    }
    catch {
        $result.first_run = [ordered]@{ passed = $false; detail = $_.Exception.Message }
    }
    Write-ProbeLog "Ersteinrichtung: $($result.first_run.passed)"

    $result.gui = Test-ProbeMainWindow -ExecutablePath $mainExecutable
    Write-ProbeLog "Hauptfenster: $($result.gui.main_window) '$($result.gui.title)'"
    $result.completed = $true
}
catch {
    $result.fatal_error = $_.Exception.Message
    try { Write-ProbeLog "FEHLER: $($_.Exception.Message)" } catch { }
}
finally {
    $result.finished_at_utc = [DateTime]::UtcNow.ToString('o')
    $json = New-Object PSObject -Property $result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $ResultDirectory 'result.json'), $json, $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $ResultDirectory 'done.marker'), [string]$result.nonce, $utf8NoBom)
    $shutdown = $true
    if ($null -ne $expectation -and $null -ne $expectation.PSObject.Properties['shutdown_when_done']) {
        $shutdown = [bool]$expectation.shutdown_when_done
    }
    if ($shutdown) {
        & shutdown.exe /s /t 5 /f
    }
}
