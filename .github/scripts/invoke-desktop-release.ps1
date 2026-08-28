#Requires -Version 7
<#
.SYNOPSIS
    Baut und veroeffentlicht eine Ausgabe von ProjectAtlas Desktop.

.DESCRIPTION
    Manueller, von Timo ausgeloester Release-Weg fuer das Desktop-Dashboard — getrennt vom
    CLI/MCP-Release in .github/workflows/release.yml, das dieses Skript nicht anfasst.

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

.EXAMPLE
    pwsh ./.github/scripts/invoke-desktop-release.ps1 -Version 0.2.0 -NotesFile ./RELEASE_NOTES.md -Publish
    Baut 0.2.0 und legt das GitHub-Release im Release-Repo an.

.NOTES
    Voraussetzungen: TAURI_SIGNING_PRIVATE_KEY (und TAURI_SIGNING_PRIVATE_KEY_PASSWORD, falls
    der Schluessel eines hat) VOR dem Start in der Umgebung setzen — aus dem Passwortmanager
    holen, nie auf der Befehlszeile uebergeben, nie committen. Ausserdem noetig: cargo tauri
    im PATH sowie ein angemeldetes gh mit Schreibrecht auf das Release-Repo.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter(Mandatory = $true)]
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
    [switch]$AllowUnsigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$sidecarBinaryName = "projectatlas-cli-x86_64-pc-windows-msvc.exe"
$releaseTag = "v$Version"

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
if ($Publish -and -not $PSBoundParameters.ContainsKey("NotesFile")) {
    throw "-Publish verlangt -NotesFile: ohne Changelog erfaehrt niemand, was sich geaendert hat."
}
foreach ($required in @($cargoManifest, $tauriConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Erwartete Datei fehlt: $required"
    }
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
$signaturePath = "$($artifacts[0].FullName).sig"
if ($hasSigningKey -and -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
    throw "Keine Signaturdatei neben $($artifacts[0].Name) gefunden. Steht bundle.createUpdaterArtifacts in tauri.conf.json auf true? Ohne Signatur lehnt der Auto-Updater die Ausgabe ab."
}

Write-Host ""
Write-Host "Fertige Artefakte:"
foreach ($upload in $uploads) {
    $sizeMb = [math]::Round((Get-Item -LiteralPath $upload).Length / 1MB, 2)
    Write-Host "  $upload ($sizeMb MB)" -ForegroundColor Green
}

if (-not $Publish) {
    Write-Step "Fertig (nichts veroeffentlicht)"
    Write-Host "Kein Upload durchgefuehrt. Mit -Publish und -NotesFile erneut aufrufen, um das GitHub-Release anzulegen."
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
    Invoke-Native -FilePath $ghPath -Arguments @(
        "release", "upload", $releaseTag, $manifestPath, "--repo", $ReleaseRepo, "--clobber"
    )
    Write-Host "latest.json nachgereicht, verweist auf $($installerAsset.url)" -ForegroundColor Green
}
else {
    Write-Warning "Ohne Update-Schluessel gebaut: es wurde KEIN latest.json erzeugt, der Auto-Updater findet diese Ausgabe nicht."
}

Write-Step "Fertig"
Write-Host "ProjectAtlas Desktop $releaseTag veroeffentlicht unter $ReleaseRepo." -ForegroundColor Green
Write-Host "Bereits installierte Ausgaben bieten das Update beim naechsten Pruefen an." -ForegroundColor Green
