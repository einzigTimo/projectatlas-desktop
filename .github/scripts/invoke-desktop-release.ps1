#Requires -Version 7
<#
.SYNOPSIS
    Baut und veroeffentlicht eine Ausgabe von ProjectAtlas Desktop.

.DESCRIPTION
    Technischer, ausschliesslich von der Develop Zentrale aufgerufener Release-Weg fuer das
    Desktop-Dashboard. Die CLI/MCP-Veroeffentlichung in .github/workflows/release.yml ist bis
    zu ihrer zentralen Integration stillgelegt.

    Ablauf: Version in Cargo.toml und tauri.conf.json gegenpruefen, projectatlas-cli-Sidecar
    bauen und in das Desktop-Crate kopieren, cargo tauri build ausfuehren (signiert ueber die
    unten genannten Umgebungsvariablen), danach Installer plus Updater-Manifest in das
    getrennte Release-Repo laden.

    Der Upload passiert NUR mit -Publish. Ohne den Schalter endet das Skript nach dem Bauen
    und zeigt an, welche Artefakte entstanden sind — so laesst sich ein Release gefahrlos
    proben, bevor er wirklich hochgeht.

.PARAMETER Version
    Version ohne fuehrendes v, z. B. 0.2.0. Muss bereits in
    crates/projectatlas-desktop/Cargo.toml UND tauri.conf.json stehen — das Skript prueft nur,
    es bumpt nicht. Eine Abweichung ist ein Abbruch, keine stille Datei-Aenderung.
    Ohne Angabe wird die Version aus Cargo.toml gelesen. Das ist der normale Startfall
    ueber die Develop Zentrale, die keine separate Versionsnummer uebergibt.

.PARAMETER PreflightArtifact
    Frisches Preflight-Artefakt der Develop Zentrale. Pflicht bei -Publish. Ein produktiver
    Release darf nie direkt ueber dieses Skript gestartet werden.

.PARAMETER NotesFile
    Changelog-Datei, die an gh release create weitergereicht wird. Pflicht bei -Publish.

.PARAMETER SkipSidecar
    Ueberspringt Bau und Buendelung des projectatlas-cli-Sidecars. Nur fuer einen schnellen
    lokalen Neubau des Dashboards allein — nie fuer ein echtes Release, der Installer kaeme
    sonst ohne die KI-Tool-Anbindung heraus.

.PARAMETER AllowUnsigned
    Baut ohne Update-Schluessel. Die Bundles sind dann nicht signiert und der Auto-Updater
    lehnt sie ab; nur zum lokalen Ausprobieren. Mit -Publish nicht kombinierbar.

.EXAMPLE
    pwsh ./.github/scripts/invoke-desktop-release.ps1 -Version 0.2.0
    Baut 0.2.0 lokal und veroeffentlicht nichts.

.NOTES
    Der Produktivmodus ist kein manueller Einstiegspunkt. Die Develop Zentrale uebergibt das
    frische, commitgebundene Preflight-Artefakt und stellt TAURI_SIGNING_PRIVATE_KEY sowie ein
    angemeldetes gh bereit. Geheimnisse nie auf der Befehlszeile uebergeben oder committen.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$")]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$NotesFile,

    [Parameter(Mandatory = $false)]
    [ValidatePattern("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")]
    [string]$ReleaseRepo = "einzigTimo/projectatlas-desktop-releases",

    [Parameter(Mandatory = $false)]
    [switch]$Publish,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSidecar,

    [Parameter(Mandatory = $false)]
    [switch]$AllowUnsigned,

    [Parameter(Mandatory = $false)]
    [string]$PreflightArtifact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$sidecarBinaryName = "projectatlas-cli-x86_64-pc-windows-msvc.exe"
$sourceRepository = "einzigTimo/projectatlas-desktop"
$preflightSourcePath = "crates/projectatlas-desktop/Cargo.toml"

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-RepositoryRoot {
    $candidate = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")
    $manifest = Join-Path $candidate "Cargo.toml"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Workspace-Manifest nicht gefunden unter: $manifest"
    }
    return $candidate.Path
}

function Assert-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Hint
    )

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Benoetigtes Werkzeug fehlt im PATH: $Name. $Hint"
    }
    return $command.Source
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory
    )

    # Bewusst OHNE Pipeline: sobald die Ausgabe eines native command durch eine Pipeline
    # laeuft, ist $LASTEXITCODE danach leer und jede Erfolgspruefung waere still falsch.
    $usesWorkingDirectory = $PSBoundParameters.ContainsKey("WorkingDirectory")
    if ($usesWorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }
    try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($usesWorkingDirectory) {
            Pop-Location
        }
    }

    if ($exitCode -ne 0) {
        throw "Aufruf fehlgeschlagen (Exitcode $exitCode): $FilePath $($Arguments -join ' ')"
    }
}

function Get-CargoPackageVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Auf den Abschnitt [package] verankert, damit keine Abhaengigkeits-Version verwechselt wird.
    $lines = [System.IO.File]::ReadAllLines($Path)
    $inPackageSection = $false
    foreach ($line in $lines) {
        if ($line -match "^\s*\[") {
            $inPackageSection = ($line -match "^\s*\[package\]\s*$")
            continue
        }
        if ($inPackageSection -and $line -match "^version\s*=\s*""([^""]+)""") {
            return $Matches[1]
        }
    }

    throw "Keine version-Zeile im Abschnitt [package] von $Path gefunden."
}

function Get-TauriConfigVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $config = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($config.version)) {
        throw "Kein version-Eintrag in $Path gefunden."
    }
    return $config.version
}

function Build-Sidecar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$CargoPath,

        [Parameter(Mandatory = $true)]
        [string]$DesktopCrateRoot
    )

    Write-Step "Sidecar bauen: projectatlas-cli"
    Invoke-Native -FilePath $CargoPath -WorkingDirectory $RepositoryRoot -Arguments @(
        "build", "--locked", "--release", "-p", "projectatlas-cli", "--bin", "projectatlas"
    )

    $built = Join-Path $RepositoryRoot "target\release\projectatlas.exe"
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) {
        throw "Erwartetes Sidecar-Binary nicht gefunden: $built"
    }

    $binariesDir = Join-Path $DesktopCrateRoot "binaries"
    if (-not (Test-Path -LiteralPath $binariesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $binariesDir | Out-Null
    }

    $destination = Join-Path $binariesDir $sidecarBinaryName
    Copy-Item -LiteralPath $built -Destination $destination -Force
    Write-Host "Sidecar kopiert nach $destination" -ForegroundColor Green
}

function Get-BundleArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundleRoot,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        throw "Bundle-Verzeichnis fehlt: $BundleRoot"
    }

    $all = @()
    foreach ($pattern in @("nsis\*.exe", "msi\*.msi")) {
        $found = Get-ChildItem -Path (Join-Path $BundleRoot $pattern) -File -ErrorAction SilentlyContinue
        if ($null -ne $found) {
            $all += $found
        }
    }

    # NUR die Installer dieser Version. Der Bundle-Ordner wird zwischen Laeufen nicht
    # geleert, es liegen also die Ausgaben frueherer Versionen daneben. Ohne diesen
    # Filter wandert eine alte Datei ins Release und das Manifest verweist auf sie -
    # die Anwendung wuerde beim Update die alte Ausgabe installieren und danach
    # endlos weiter dasselbe Update anbieten.
    $artifacts = @($all | Where-Object { $_.Name -like "*_$($Version)_*" })

    if ($artifacts.Count -eq 0) {
        $vorhanden = ($all | ForEach-Object { $_.Name }) -join ", "
        throw "Kein Installer der Version $Version unter $BundleRoot gefunden. Vorhanden: $vorhanden"
    }

    $fremd = @($all | Where-Object { $_.Name -notlike "*_$($Version)_*" })
    if ($fremd.Count -gt 0) {
        Write-Host ("Uebergangen (andere Version): " + (($fremd | ForEach-Object { $_.Name }) -join ", ")) -ForegroundColor DarkGray
    }

    return $artifacts
}

$repositoryRoot = Get-RepositoryRoot
$desktopCrateRoot = Join-Path $repositoryRoot "crates\projectatlas-desktop"
$cargoManifest = Join-Path $desktopCrateRoot "Cargo.toml"
$tauriConfig = Join-Path $desktopCrateRoot "tauri.conf.json"

Write-Step "Voraussetzungen pruefen"

if (-not $IsWindows) {
    throw "Dieses Skript baut einen Windows-Installer und laeuft nur unter Windows."
}
# Argumente zuerst pruefen: widerspruechliche Schalter sollen gemeldet werden, bevor
# irgendetwas am Dateisystem oder an der Werkzeugkette haengt.
if ($Publish -and $AllowUnsigned) {
    throw "-Publish und -AllowUnsigned schliessen sich aus: ein unsigniertes Release wuerde den Auto-Updater aller bereits installierten Ausgaben brechen."
}
if ($Publish -and $SkipSidecar) {
    throw "-Publish und -SkipSidecar schliessen sich aus: ein produktiver Installer muss das ProjectAtlas-CLI-Sidecar enthalten."
}
if ($Publish -and -not $PSBoundParameters.ContainsKey("NotesFile")) {
    throw "-Publish verlangt -NotesFile: ohne Changelog erfaehrt niemand, was sich geaendert hat."
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory
    )

    $usesWorkingDirectory = $PSBoundParameters.ContainsKey("WorkingDirectory")
    if ($usesWorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($usesWorkingDirectory) {
            Pop-Location
        }
    }

    if ($exitCode -ne 0) {
        throw "Aufruf fehlgeschlagen (Exitcode $exitCode): $FilePath $($Arguments -join ' ')"
    }
    return ($output | Out-String).Trim()
}

function Get-SourceFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSource
    )

    $manifest = [Text.StringBuilder]::new()
    if (Test-Path -LiteralPath $ResolvedSource -PathType Leaf) {
        $item = Get-Item -LiteralPath $ResolvedSource
        $hash = (Get-FileHash -LiteralPath $ResolvedSource -Algorithm SHA256).Hash
        [void]$manifest.Append($item.Name).Append('|').Append($item.Length).Append('|').Append($hash).Append("`n")
    }
    else {
        $root = [IO.Path]::GetFullPath($ResolvedSource).TrimEnd([char]'\', [char]'/')
        $files = [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories) |
            ForEach-Object {
                [pscustomobject]@{
                    FullPath     = $_
                    RelativePath = [IO.Path]::GetRelativePath($root, $_).Replace('\', '/')
                }
            } | Sort-Object -Property RelativePath -CaseSensitive
        foreach ($file in $files) {
            $item = Get-Item -LiteralPath $file.FullPath
            $hash = (Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash
            [void]$manifest.Append($file.RelativePath).Append('|').Append($item.Length).Append('|').Append($hash).Append("`n")
        }
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifest.ToString())))
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-GitHubRepositorySlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $value = $RemoteUrl.Trim().TrimEnd('/')
    foreach ($pattern in @(
            '^https://github\.com/(?<slug>[^/]+/[^/]+?)(?:\.git)?$',
            '^git@github\.com:(?<slug>[^/]+/[^/]+?)(?:\.git)?$',
            '^ssh://git@github\.com/(?<slug>[^/]+/[^/]+?)(?:\.git)?$')) {
        if ($value -match $pattern) {
            return $Matches.slug
        }
    }
    return ''
}

function Assert-PublishBinding {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedArtifactPath,
        [Parameter(Mandatory = $true)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTreeSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedCargoSha256
    )

    if (-not (Test-Path -LiteralPath $ExpectedArtifactPath -PathType Leaf)) {
        throw 'Produktiver Release blockiert: das attestierte Preflight-Artefakt fehlt inzwischen.'
    }
    $currentArtifactSha256 = (Get-FileHash -LiteralPath $ExpectedArtifactPath -Algorithm SHA256).Hash
    if ($currentArtifactSha256 -ne $ExpectedArtifactSha256) {
        throw 'Produktiver Release blockiert: das Preflight-Artefakt wurde nach der Pruefung veraendert.'
    }

    $branchName = Invoke-NativeCapture -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'branch', '--show-current')
    if ($branchName -ne 'main') {
        throw "Produktiver Release blockiert: die Develop Zentrale darf nur den Branch main veroeffentlichen, aktuell ist $branchName ausgecheckt."
    }

    $originUrl = Invoke-NativeCapture -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'remote', 'get-url', 'origin')
    $originRepository = ConvertTo-GitHubRepositorySlug -RemoteUrl $originUrl
    if ($originRepository -ne $sourceRepository) {
        throw "Produktiver Release blockiert: origin zeigt auf '$originUrl' statt auf $sourceRepository."
    }

    Invoke-Native -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'fetch', 'origin', 'main', '--prune')
    $localHead = Invoke-NativeCapture -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
    $remoteHead = Invoke-NativeCapture -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'rev-parse', 'origin/main')
    if ($localHead -notmatch '^[0-9a-f]{40}$' -or $localHead -ne $ExpectedCommit) {
        throw "Produktiver Release blockiert: lokaler Commit $localHead weicht vom attestierten Commit $ExpectedCommit ab."
    }
    if ($remoteHead -ne $ExpectedCommit) {
        throw "Produktiver Release blockiert: origin/main $remoteHead weicht vom attestierten Commit $ExpectedCommit ab."
    }

    $statusOutput = Invoke-NativeCapture -FilePath 'git' -Arguments @('-C', $RepositoryRoot, 'status', '--porcelain')
    if (-not [string]::IsNullOrWhiteSpace($statusOutput)) {
        throw 'Produktiver Release blockiert: der Arbeitsbaum ist nicht sauber.'
    }

    $resolvedSource = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $SourcePath))
    $currentSourceTreeSha256 = Get-SourceFingerprint -ResolvedSource $resolvedSource
    if ($currentSourceTreeSha256 -ne $ExpectedSourceTreeSha256) {
        throw 'Produktiver Release blockiert: der attestierte Quell-Fingerprint hat sich veraendert.'
    }
    $currentCargoSha256 = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
    if ($currentCargoSha256 -ne $ExpectedCargoSha256) {
        throw 'Produktiver Release blockiert: Cargo.toml wurde waehrend des Release-Laufs veraendert.'
    }
}

function New-ReleaseProvenance {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$LatestManifestPath
    )

    foreach ($requiredAsset in @($InstallerPath, $SignaturePath, $LatestManifestPath)) {
        if (-not (Test-Path -LiteralPath $requiredAsset -PathType Leaf)) {
            throw "Provenance kann nicht erzeugt werden; Release-Asset fehlt: $requiredAsset"
        }
    }
    if ($SourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Provenance kann nicht erzeugt werden; Source-Commit ist keine vollstaendige Git-ID.'
    }

    $provenance = [ordered]@{
        schema_version    = 'projectatlas.desktop.release-provenance.v1'
        version           = $Version
        release_tag       = $ReleaseTag
        source_repository = $sourceRepository
        source_commit     = $SourceCommit
        installer         = [ordered]@{
            name   = (Split-Path -Leaf $InstallerPath)
            sha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        signature         = [ordered]@{
            name   = (Split-Path -Leaf $SignaturePath)
            sha256 = (Get-FileHash -LiteralPath $SignaturePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        latest_manifest   = [ordered]@{
            name   = 'latest.json'
            sha256 = (Get-FileHash -LiteralPath $LatestManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        generated_at_utc  = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Destination -Encoding utf8
}

foreach ($required in @($cargoManifest, $tauriConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Erwartete Datei fehlt: $required"
    }
}

if ($Publish) {
    if ($ReleaseRepo -ne "einzigTimo/projectatlas-desktop-releases") {
        throw "Produktiver Release blockiert: das attestierte Ziel ist einzigTimo/projectatlas-desktop-releases."
    }
    if ([string]::IsNullOrWhiteSpace($PreflightArtifact)) {
        throw "Produktiver Release blockiert: -Publish verlangt das Preflight-Artefakt der Develop Zentrale. Einstieg ist die Develop Zentrale, nicht dieses Skript."
    }
    $preflightCheck = Join-Path $PSScriptRoot "Assert-ControllerPreflight.ps1"
    if (-not (Test-Path -LiteralPath $preflightCheck -PathType Leaf)) {
        throw "Produktiver Release blockiert: Preflight-Pruefer fehlt: $preflightCheck"
    }
    $preflightResults = @(& $preflightCheck `
        -ArtifactPath $PreflightArtifact -ProjectRoot $repositoryRoot `
        -ProjectId "projectatlas-desktop" -ComponentId "desktop-app" `
        -SourcePath $preflightSourcePath `
        -TargetResourceGroup "github-release" -TargetAppName "projectatlas-desktop-releases" `
        -PassThru)
    if ($preflightResults.Count -ne 1) {
        throw 'Develop-Zentrale-Preflight lieferte keine eindeutige Attestierung.'
    }
    $preflightAttestation = $preflightResults[0]
    $attestedCommit = [string]$preflightAttestation.ExpectedCommit
    $attestedArtifactPath = [string]$preflightAttestation.ArtifactPath
    $attestedArtifactSha256 = [string]$preflightAttestation.ArtifactSha256
    $attestedSourceTreeSha256 = [string]$preflightAttestation.SourceTreeSha256
    if ($attestedCommit -notmatch '^[0-9a-f]{40}$' -or
        $attestedArtifactSha256 -notmatch '^[0-9a-f]{64}$' -or
        $attestedSourceTreeSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$preflightAttestation.SourcePath -ne $preflightSourcePath) {
        throw 'Develop-Zentrale-Preflight enthaelt keine vollstaendige Commit- und Quellbindung.'
    }
    $attestedCargoSha256 = (Get-FileHash -LiteralPath $cargoManifest -Algorithm SHA256).Hash
    Assert-PublishBinding `
        -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
        -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
        -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
        -ExpectedCargoSha256 $attestedCargoSha256
}

$cargoPath = Assert-Tool -Name "cargo" -Hint "Rust-Toolchain installieren (rustup)."
Invoke-Native -FilePath $cargoPath -Arguments @("tauri", "--version")

$signingKey = [System.Environment]::GetEnvironmentVariable("TAURI_SIGNING_PRIVATE_KEY")
$hasSigningKey = -not [string]::IsNullOrWhiteSpace($signingKey)
if (-not $hasSigningKey) {
    if (-not $AllowUnsigned) {
        throw "TAURI_SIGNING_PRIVATE_KEY ist nicht gesetzt. Schluessel aus dem Passwortmanager holen und in dieser Sitzung als Umgebungsvariable setzen, bevor das Skript laeuft — nie im Klartext an das Skript uebergeben oder committen. Nur zum Ausprobieren: -AllowUnsigned."
    }
    Write-Warning "Ohne Update-Schluessel gebaut: die Bundles sind nicht signiert und der Auto-Updater lehnt sie ab."
}

if ($Publish) {
    $ghPath = Assert-Tool -Name "gh" -Hint "GitHub CLI installieren und mit gh auth login anmelden."
    Invoke-Native -FilePath $ghPath -Arguments @("auth", "status")
}

Write-Step "Versionsnummer gegenpruefen (kein automatischer Bump)"
$cargoVersion = Get-CargoPackageVersion -Path $cargoManifest
$configVersion = Get-TauriConfigVersion -Path $tauriConfig
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $cargoVersion
    Write-Host "Version aus Cargo.toml uebernommen: $Version"
}
$releaseTag = "v$Version"
foreach ($check in @(
        @{ Name = "crates/projectatlas-desktop/Cargo.toml"; Value = $cargoVersion },
        @{ Name = "crates/projectatlas-desktop/tauri.conf.json"; Value = $configVersion })) {
    if ($check.Value -ne $Version) {
        throw "$($check.Name) steht auf $($check.Value), angefordert wurde $Version. Erst die Version in Cargo.toml UND tauri.conf.json auf $Version setzen, dann erneut starten."
    }
}
Write-Host "Version $Version bestaetigt in Cargo.toml und tauri.conf.json." -ForegroundColor Green
Write-Host "Signiert: $($hasSigningKey ? 'ja' : 'nein')"

# Eingebettete Pfade neutralisieren: Rust schreibt absolute Quellpfade (samt
# Windows-Benutzername) in Panik-Texte und Debug-Infos jedes Binaries. Ohne die
# Remaps stuende der lokale Benutzerpfad in Sidecar UND Installer.
# Reihenfolge ist tragend: rustc laesst bei mehreren Treffern das LETZTE Flag
# gewinnen. Stuende das Benutzerprofil zuletzt, hiesse der Repo-Pfad im Binary
# "~\Projects\<Repo-Name>\..." - der Ordnername leckte weiter.
$env:RUSTFLAGS = (@(
        $env:RUSTFLAGS,
        "--remap-path-prefix=$env:USERPROFILE=~",
        "--remap-path-prefix=$repositoryRoot=atlas"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "

if (-not $SkipSidecar) {
    Build-Sidecar -RepositoryRoot $repositoryRoot -CargoPath $cargoPath -DesktopCrateRoot $desktopCrateRoot
}
else {
    Write-Host "Sidecar-Bau uebersprungen (-SkipSidecar) — NICHT fuer echte Releases verwenden." -ForegroundColor Yellow
}

Write-Step "cargo tauri build"
# Der Sidecar wird nur ueber diese Overlay-Konfiguration deklariert, nicht in
# tauri.conf.json: waere bundle.externalBin dauerhaft gesetzt, braeche schon
# `cargo check` ab, solange die Programmdatei fehlt - und damit der CI-Schritt.
$buildArguments = @("tauri", "build")
if (-not $SkipSidecar) {
    $buildArguments += @("--config", "tauri.sidecar.conf.json")
}
Invoke-Native -FilePath $cargoPath -WorkingDirectory $desktopCrateRoot -Arguments $buildArguments

Write-Step "Freigegebene Artefakte suchen"
$bundleRoot = Join-Path $repositoryRoot "target\release\bundle"
$artifacts = Get-BundleArtifact -BundleRoot $bundleRoot -Version $Version

$uploads = [System.Collections.Generic.List[string]]::new()
foreach ($artifact in $artifacts) {
    $uploads.Add($artifact.FullName)
}

# tauri erzeugt KEIN latest.json - nur den Installer und, wenn
# bundle.createUpdaterArtifacts gesetzt ist, eine .sig-Datei daneben. Das Manifest
# baut dieses Skript weiter unten selbst, sobald die echte Download-Adresse des
# hochgeladenen Artefakts bekannt ist (raten waere hier eine Fehlerquelle: GitHub
# ersetzt Leerzeichen im Dateinamen durch Punkte).
$updaterInstallers = @($artifacts | Where-Object { $_.Name -like '*setup.exe' })
if ($hasSigningKey -and $updaterInstallers.Count -ne 1) {
    $namen = ($artifacts | ForEach-Object { $_.Name }) -join ', '
    throw "Erwartet wurde genau ein signierbarer Setup-Installer der Version $Version. Vorhanden: $namen"
}
if ($hasSigningKey) {
    $updaterInstaller = $updaterInstallers[0]
    $signaturePath = "$($updaterInstaller.FullName).sig"
    if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
        throw "Keine Signaturdatei neben $($updaterInstaller.Name) gefunden. Steht bundle.createUpdaterArtifacts in tauri.conf.json auf true? Ohne Signatur lehnt der Auto-Updater die Ausgabe ab."
    }
    $uploads.Add($signaturePath)
}

Write-Host ""
Write-Host "Fertige Artefakte:"
foreach ($upload in $uploads) {
    $sizeMb = [math]::Round((Get-Item -LiteralPath $upload).Length / 1MB, 2)
    Write-Host "  $upload ($sizeMb MB)" -ForegroundColor Green
}

if (-not $Publish) {
    Write-Step "Fertig (nichts veroeffentlicht)"
    Write-Host "Kein Upload durchgefuehrt. Produktive Auslieferungen startet ausschliesslich die Develop Zentrale."
    return
}

Write-Step "Release veroeffentlichen: $ReleaseRepo@$releaseTag"
$releaseArguments = [System.Collections.Generic.List[string]]::new()
$releaseArguments.Add("release")
$releaseArguments.Add("create")
$releaseArguments.Add($releaseTag)
foreach ($upload in $uploads) {
    $releaseArguments.Add($upload)
}
$releaseArguments.Add("--repo")
$releaseArguments.Add($ReleaseRepo)
$releaseArguments.Add("--title")
$releaseArguments.Add("ProjectAtlas Desktop $releaseTag")
$releaseArguments.Add("--notes-file")
$releaseArguments.Add((Resolve-Path -LiteralPath $NotesFile).Path)

if (-not $PSCmdlet.ShouldProcess("$ReleaseRepo ($releaseTag)", "GitHub-Release anlegen und Artefakte hochladen")) {
    return
}

Assert-PublishBinding `
    -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
    -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
    -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
    -ExpectedCargoSha256 $attestedCargoSha256
Invoke-Native -FilePath $ghPath -Arguments $releaseArguments.ToArray()

if ($hasSigningKey) {
    Write-Step "Update-Manifest latest.json erzeugen und nachreichen"

    # Die Download-Adresse wird beim Release ABGEFRAGT statt aus dem Dateinamen
    # zusammengebaut: GitHub normalisiert Asset-Namen (Leerzeichen werden zu Punkten),
    # ein geratener Link liefe ins Leere und der Updater faende die Ausgabe nie.
    $assetJson = & $ghPath release view $releaseTag --repo $ReleaseRepo --json assets
    if ($LASTEXITCODE -ne 0) {
        throw "Konnte die Artefakte des Releases $releaseTag nicht abfragen."
    }
    $assets = ($assetJson | ConvertFrom-Json).assets
    # Auch hier an die Version gebunden: ein Release kann Artefakte mehrerer Laeufe
    # tragen, und "das erste setup.exe" waere dann Gluecksache.
    $installerAsset = $assets |
        Where-Object { $_.name -like "*setup.exe" -and $_.name -like "*_$($Version)_*" } |
        Select-Object -First 1
    if ($null -eq $installerAsset) {
        $namen = ($assets | ForEach-Object { $_.name }) -join ", "
        throw "Im Release $releaseTag ist kein Installer der Version $Version zu finden. Vorhanden: $namen"
    }

    $manifest = [ordered]@{
        version   = $Version
        notes     = (Get-Content -LiteralPath $NotesFile -Raw)
        pub_date  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        platforms = [ordered]@{
            "windows-x86_64" = [ordered]@{
                signature = (Get-Content -LiteralPath $signaturePath -Raw).Trim()
                url       = $installerAsset.url
            }
        }
    }

    $manifestPath = Join-Path $bundleRoot "latest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $provenancePath = Join-Path $bundleRoot "projectatlas-desktop-v$Version.provenance.json"
    New-ReleaseProvenance `
        -Destination $provenancePath -Version $Version -ReleaseTag $releaseTag `
        -SourceCommit $attestedCommit -InstallerPath $updaterInstaller.FullName `
        -SignaturePath $signaturePath -LatestManifestPath $manifestPath

    Assert-PublishBinding `
        -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
        -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
        -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
        -ExpectedCargoSha256 $attestedCargoSha256
    Invoke-Native -FilePath $ghPath -Arguments @(
        "release", "upload", $releaseTag, $manifestPath, $provenancePath,
        "--repo", $ReleaseRepo, "--clobber"
    )
    Write-Host "latest.json und $(Split-Path -Leaf $provenancePath) nachgereicht; Manifest verweist auf $($installerAsset.url)" -ForegroundColor Green
}
else {
    Write-Warning "Ohne Update-Schluessel gebaut: es wurde KEIN latest.json erzeugt, der Auto-Updater findet diese Ausgabe nicht."
}

Write-Step "Fertig"
Write-Host "ProjectAtlas Desktop $releaseTag veroeffentlicht unter $ReleaseRepo." -ForegroundColor Green
Write-Host "Bereits installierte Ausgaben bieten das Update beim naechsten Pruefen an." -ForegroundColor Green
