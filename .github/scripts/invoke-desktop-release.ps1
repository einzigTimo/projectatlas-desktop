#Requires -Version 7
<#
.SYNOPSIS
    Baut und veroeffentlicht eine Ausgabe von ProjectAtlas Desktop.

.DESCRIPTION
    Technischer, ausschliesslich von der Develop Zentrale aufgerufener Release-Weg fuer das
    Desktop-Dashboard. Die CLI/MCP-Veroeffentlichung in .github/workflows/release.yml ist bis
    zu ihrer zentralen Integration stillgelegt.

    Ablauf: Version in Cargo.toml und tauri.conf.json gegenpruefen, projectatlas-cli-Sidecar
    bauen und in das Desktop-Crate kopieren, dessen Ersteinrichtungs-Smoke-Test ausfuehren,
    cargo tauri build starten und danach Installer plus Updater-Manifest in das getrennte
    Release-Repo laden.

    Zwei unabhaengige Signaturketten werden bewusst getrennt behandelt:
    - TAURI_SIGNING_PRIVATE_KEY[_PATH] erzeugt die Tauri-Updater-Signatur (.sig). Sie
      schuetzt automatische Updates, ist aber keine Windows-Herausgeber-Signatur.
    - PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT und
      PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL aktivieren Windows Authenticode ueber ein
      bereits sicher bereitgestelltes, oeffentlich vertrauenswuerdiges Code-Signing-
      Zertifikat. Tauri signiert Sidecar, paketierte Haupt-EXE und NSIS-Installer. Ein
      selbstsignierter Ersatz ist nicht zulaessig.

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

.PARAMETER AllowUnsignedUpdater
    Baut ohne Tauri-Updater-Schluessel. Dann fehlt ausschliesslich die .sig-Datei fuer den
    Auto-Updater; der Schalter sagt nichts ueber Windows Authenticode aus. Nur zum lokalen
    Ausprobieren, mit -Publish nicht kombinierbar. Der alte Name -AllowUnsigned bleibt als
    Alias fuer bestehende lokale Aufrufe erhalten.

.EXAMPLE
    pwsh ./.github/scripts/invoke-desktop-release.ps1 -Version 0.2.0
    Baut 0.2.0 lokal und veroeffentlicht nichts.

.NOTES
    Der Produktivmodus ist kein manueller Einstiegspunkt. Die Develop Zentrale uebergibt das
    frische, commitgebundene Preflight-Artefakt und stellt die beiden getrennten Signierketten
    sowie ein angemeldetes gh bereit. Geheimnisse nie auf der Befehlszeile uebergeben oder
    committen. Neben TAURI_SIGNING_PRIVATE_KEY wird der geschuetzte lokale Standardpfad unter
    .tauri unterstuetzt. Der Authenticode-Privatschluessel bleibt im Windows-Zertifikatsspeicher
    bzw. dessen geschuetztem Provider; das Skript akzeptiert nur Thumbprint und HTTPS-
    Zeitstempeladresse. TAURI_WINDOWS_SIGNTOOL_PATH ist nur noetig, wenn Tauri das Windows SDK
    nicht selbst findet.
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
    [Alias("AllowUnsigned")]
    [switch]$AllowUnsignedUpdater,

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

function Get-NormalizedCertificateThumbprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $normalized = ($Value -replace '\s', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{40}$') {
        throw 'Der Authenticode-Zertifikatsthumbprint muss der 40-stellige SHA-1-Fingerprint eines vorhandenen Code-Signing-Zertifikats sein.'
    }
    return $normalized
}

function Test-CodeSigningCertificateUsage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $ekuOids = @($Certificate.Extensions |
            Where-Object { $_.Oid.Value -eq '2.5.29.37' } |
            ForEach-Object { $_.EnhancedKeyUsages } |
            ForEach-Object { $_.Value })
    return $ekuOids -contains '1.3.6.1.5.5.7.3.3'
}

function Resolve-WindowsSignTool {
    $configuredPath = [System.Environment]::GetEnvironmentVariable('TAURI_WINDOWS_SIGNTOOL_PATH')
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        $resolvedConfiguredPath = [IO.Path]::GetFullPath($configuredPath)
        if (-not (Test-Path -LiteralPath $resolvedConfiguredPath -PathType Leaf)) {
            throw 'TAURI_WINDOWS_SIGNTOOL_PATH verweist nicht auf eine vorhandene Datei.'
        }
        return $resolvedConfiguredPath
    }

    $command = Get-Command -Name 'signtool.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    $kitsRoot = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' `
        -Name 'KitsRoot10' -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($kitsRoot)) {
        $binRoot = Join-Path $kitsRoot 'bin'
        $candidates = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $binRoot -PathType Container) {
            $versionDirectories = @(Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object -Property Name -Descending)
            foreach ($directory in $versionDirectories) {
                $candidates.Add((Join-Path $directory.FullName 'x64\signtool.exe'))
            }
            $candidates.Add((Join-Path $binRoot 'x64\signtool.exe'))
        }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    throw 'signtool.exe wurde weder ueber TAURI_WINDOWS_SIGNTOOL_PATH noch im Windows SDK gefunden.'
}

function Resolve-AuthenticodeConfiguration {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Required
    )

    $thumbprintValue = [System.Environment]::GetEnvironmentVariable(
        'PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT'
    )
    $timestampValue = [System.Environment]::GetEnvironmentVariable(
        'PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL'
    )
    $hasThumbprint = -not [string]::IsNullOrWhiteSpace($thumbprintValue)
    $hasTimestamp = -not [string]::IsNullOrWhiteSpace($timestampValue)

    if (-not $hasThumbprint -and -not $hasTimestamp) {
        $message = 'Windows Authenticode ist nicht konfiguriert. Erwartet werden PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT und PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL.'
        if ($Required) {
            throw "Produktiver Release blockiert: $message"
        }
        Write-Warning $message
        return $null
    }

    try {
        if (-not $hasThumbprint -or -not $hasTimestamp) {
            throw 'Authenticode ist nur teilweise konfiguriert; Thumbprint und Zeitstempeladresse muessen gemeinsam gesetzt sein.'
        }

        $thumbprint = Get-NormalizedCertificateThumbprint -Value $thumbprintValue
        $timestampUri = $null
        if (
            -not [Uri]::TryCreate($timestampValue, [UriKind]::Absolute, [ref]$timestampUri) -or
            $timestampUri.Scheme -ne [Uri]::UriSchemeHttps -or
            -not [string]::IsNullOrEmpty($timestampUri.UserInfo)
        ) {
            throw 'PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL muss eine absolute HTTPS-Adresse ohne eingebettete Zugangsdaten sein.'
        }

        # Tauri ruft signtool mit /sha1, aber ohne /sm auf und sucht deshalb im
        # Zertifikatsspeicher CurrentUser\My. Einen LocalMachine-Treffer hier zu
        # akzeptieren waere irrefuehrend: der spaetere Build koennte ihn nicht nutzen.
        $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
        if ($null -eq $certificate) {
            throw 'Das angegebene Authenticode-Zertifikat wurde unter CurrentUser\My nicht gefunden.'
        }
        if (-not $certificate.HasPrivateKey) {
            throw 'Das angegebene Authenticode-Zertifikat unter CurrentUser\My hat keinen nutzbaren Privatschluessel.'
        }
        $now = [DateTime]::UtcNow
        if ($certificate.NotBefore.ToUniversalTime() -gt $now -or $certificate.NotAfter.ToUniversalTime() -le $now) {
            throw 'Das angegebene Authenticode-Zertifikat ist noch nicht oder nicht mehr gueltig.'
        }
        if ($certificate.Subject -eq $certificate.Issuer) {
            throw 'Ein selbstsigniertes Authenticode-Zertifikat ist fuer Kolleg:innen-Ausgaben nicht zulaessig.'
        }

        if (-not (Test-CodeSigningCertificateUsage -Certificate $certificate)) {
            throw 'Das angegebene Zertifikat enthaelt keine explizite Code-Signing-EKU.'
        }

        $signToolPath = Resolve-WindowsSignTool
        # Tauri nutzt genau denselben geprueften Pfad. Der Wert enthaelt keinen
        # Schluessel und gilt nur fuer diesen Prozess und seine Build-Kinder.
        $env:TAURI_WINDOWS_SIGNTOOL_PATH = $signToolPath

        return [pscustomobject]@{
            Thumbprint  = $thumbprint
            TimestampUrl = $timestampUri.AbsoluteUri
            SignToolPath = $signToolPath
        }
    }
    catch {
        if ($Required) {
            throw "Produktiver Release blockiert: Authenticode-Konfiguration unbrauchbar. $($_.Exception.Message)"
        }
        Write-Warning "Windows Authenticode bleibt fuer diesen lokalen Bau deaktiviert: $($_.Exception.Message)"
        return $null
    }
}

function Get-AuthenticodeAssessment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedThumbprint
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $problems.Add('Datei fehlt')
        return [pscustomobject]@{ Valid = $false; Problems = $problems.ToArray() }
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $problems.Add("Windows-Status ist $($signature.Status)")
    }
    if ($null -eq $signature.SignerCertificate) {
        $problems.Add('kein Herausgeberzertifikat vorhanden')
    }
    else {
        $actualThumbprint = ([string]$signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
        if (
            -not [string]::IsNullOrWhiteSpace($ExpectedThumbprint) -and
            $actualThumbprint -ne $ExpectedThumbprint
        ) {
            $problems.Add('Herausgeberzertifikat stimmt nicht mit dem freigegebenen Thumbprint ueberein')
        }
        if ($signature.SignerCertificate.Subject -eq $signature.SignerCertificate.Issuer) {
            $problems.Add('Herausgeberzertifikat ist selbstsigniert')
        }
        if (-not (Test-CodeSigningCertificateUsage -Certificate $signature.SignerCertificate)) {
            $problems.Add('Herausgeberzertifikat enthaelt keine explizite Code-Signing-EKU')
        }
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        $problems.Add('vertrauenswuerdiger RFC-3161-Zeitstempel fehlt')
    }

    return [pscustomobject]@{
        Valid    = ($problems.Count -eq 0)
        Problems = $problems.ToArray()
    }
}

function Assert-AuthenticodeArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedThumbprint,

        [Parameter(Mandatory = $false)]
        [switch]$Required
    )

    $assessment = Get-AuthenticodeAssessment -Path $Path -ExpectedThumbprint $ExpectedThumbprint
    if ($assessment.Valid) {
        Write-Host "${Role}: gueltige Windows-Authenticode-Signatur und Zeitstempel." -ForegroundColor Green
        return
    }

    $message = "${Role}: $($assessment.Problems -join '; ') ($Path)"
    if ($Required) {
        throw "Produktiver Release blockiert: $message"
    }
    Write-Warning $message
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
    ) | Out-Host

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
    return $destination
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
if ($Publish -and $AllowUnsignedUpdater) {
    throw "-Publish und -AllowUnsignedUpdater schliessen sich aus: eine Ausgabe ohne Tauri-Updater-Signatur wuerde den Auto-Updater aller bereits installierten Ausgaben brechen."
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

function Get-ReleaseRepositoryBinding {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository
    )

    try {
        $repositoryState = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
            'repo', 'view', "github.com/$ReleaseRepository",
            '--json', 'nameWithOwner,defaultBranchRef'
        ) | ConvertFrom-Json
    }
    catch {
        throw "Produktiver Release blockiert: das Release-Ziel $ReleaseRepository ist nicht eindeutig erreichbar. $($_.Exception.Message)"
    }
    if ([string]$repositoryState.nameWithOwner -ne $ReleaseRepository) {
        throw "Produktiver Release blockiert: gh hat ein anderes Release-Ziel als $ReleaseRepository aufgeloest."
    }

    $defaultBranchRefProperty = $repositoryState.PSObject.Properties['defaultBranchRef']
    $defaultBranch = if (
        $null -ne $defaultBranchRefProperty -and
        $null -ne $defaultBranchRefProperty.Value
    ) {
        [string]$defaultBranchRefProperty.Value.name
    }
    else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        throw "Produktiver Release blockiert: das Release-Repository $ReleaseRepository ist leer und besitzt noch keinen bindbaren Default-Branch."
    }
    $targetCommit = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com',
        "repos/$ReleaseRepository/git/ref/heads/$defaultBranch",
        '--jq', '.object.sha'
    )
    if ($targetCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Produktiver Release blockiert: der Ziel-Commit des Release-Repositories konnte nicht eindeutig gebunden werden."
    }

    try {
        $immutableReleasesEnabled = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
            'api', '--hostname', 'github.com',
            '-H', 'X-GitHub-Api-Version: 2026-03-10',
            "repos/$ReleaseRepository/immutable-releases",
            '--jq', '.enabled'
        )
    }
    catch {
        throw "Produktiver Release blockiert: der Status unveraenderlicher GitHub-Releases konnte nicht geprueft werden. $($_.Exception.Message)"
    }
    if ($immutableReleasesEnabled -ne 'true') {
        throw "Produktiver Release blockiert: im Release-Repository $ReleaseRepository sind unveraenderliche Releases nicht aktiviert."
    }

    return [pscustomobject]@{
        DefaultBranch = $defaultBranch
        TargetCommit  = $targetCommit
    }
}

function Get-ReleaseTagCommit {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag
    )

    $directRef = "refs/tags/$ReleaseTag"
    $peeledRef = "$directRef^{}"
    $remoteUrl = "https://github.com/$ReleaseRepository.git"
    $rawRefs = Invoke-NativeCapture -FilePath 'git' -Arguments @(
        'ls-remote', '--tags', $remoteUrl, $directRef, $peeledRef
    )
    if ([string]::IsNullOrWhiteSpace($rawRefs)) {
        return $null
    }

    $refs = @($rawRefs -split "`r?`n" | ForEach-Object {
            if ($_ -notmatch '^(?<sha>[0-9a-f]{40})\s+(?<ref>refs/tags/.+)$') {
                throw "Unerwartete Tag-Antwort des Release-Repositories: $_"
            }
            [pscustomobject]@{ Sha = $Matches.sha; Ref = $Matches.ref }
        })
    $directMatches = @($refs | Where-Object { $_.Ref -ceq $directRef })
    $peeledMatches = @($refs | Where-Object { $_.Ref -ceq $peeledRef })
    if ($directMatches.Count -ne 1 -or $peeledMatches.Count -gt 1 -or
        $refs.Count -ne ($directMatches.Count + $peeledMatches.Count)) {
        throw "Release-Tag $ReleaseTag konnte nicht eindeutig aufgeloest werden."
    }

    # ^{} wird von Git rekursiv bis zum Nicht-Tag-Objekt aufgeloest. Der API-Aufruf
    # stellt danach sicher, dass dieses Objekt tatsaechlich ein Commit ist.
    $candidateCommit = if ($peeledMatches.Count -eq 1) {
        [string]$peeledMatches[0].Sha
    }
    else {
        [string]$directMatches[0].Sha
    }
    $confirmedCommit = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com',
        "repos/$ReleaseRepository/git/commits/$candidateCommit",
        '--jq', '.sha'
    )
    if ($confirmedCommit -ne $candidateCommit) {
        throw "Release-Tag $ReleaseTag zeigt nicht eindeutig auf einen Commit."
    }
    return $confirmedCommit
}

function New-ReleaseTagBinding {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$TargetCommit
    )

    Invoke-Native -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'POST',
        "repos/$ReleaseRepository/git/refs",
        '-f', "ref=refs/tags/$ReleaseTag",
        '-f', "sha=$TargetCommit",
        '--silent'
    )
    $createdTagCommit = Get-ReleaseTagCommit `
        -GhPath $GhPath -ReleaseRepository $ReleaseRepository -ReleaseTag $ReleaseTag
    if ($createdTagCommit -ne $TargetCommit) {
        throw "Der neu angelegte Release-Tag $ReleaseTag ist nicht an den geprueften Ziel-Commit gebunden."
    }
}

function Get-GitHubReleaseState {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag
    )

    $releaseJson = & $GhPath release view $ReleaseTag --repo "github.com/$ReleaseRepository" `
        --json assets,databaseId,isDraft,isImmutable,publishedAt,tagName,targetCommitish
    if ($LASTEXITCODE -ne 0) {
        throw "Release-Zustand fuer $ReleaseRepository@$ReleaseTag konnte nicht eindeutig abgefragt werden."
    }
    return ($releaseJson | ConvertFrom-Json)
}

function Assert-GitHubReleaseState {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedDatabaseId,
        [Parameter(Mandatory = $true)][string]$ExpectedTag,
        [Parameter(Mandatory = $true)][string]$ExpectedTargetCommit,
        [Parameter(Mandatory = $true)][bool]$ExpectedDraft,
        [Parameter(Mandatory = $true)][object[]]$ExpectedAssets,
        [switch]$RequireImmutable
    )

    if ([string]$State.databaseId -ne $ExpectedDatabaseId -or
        [string]$State.tagName -cne $ExpectedTag -or
        [string]$State.targetCommitish -ne $ExpectedTargetCommit -or
        [bool]$State.isDraft -ne $ExpectedDraft) {
        throw "Release $ExpectedTag hat seine gebundene Identitaet oder seinen erwarteten Draft-Status veraendert."
    }
    if (-not $ExpectedDraft -and [string]::IsNullOrWhiteSpace([string]$State.publishedAt)) {
        throw "Release $ExpectedTag besitzt trotz Veroeffentlichung keinen Live-Zeitpunkt."
    }
    if ($RequireImmutable -and -not [bool]$State.isImmutable) {
        throw "Release $ExpectedTag ist veroeffentlicht, aber GitHub schuetzt Tag und Assets nicht unveraenderlich."
    }

    $duplicateExpectations = @($ExpectedAssets | Group-Object -Property Name | Where-Object { $_.Count -ne 1 })
    $actualAssets = @($State.assets)
    if ($duplicateExpectations.Count -gt 0 -or $actualAssets.Count -ne $ExpectedAssets.Count) {
        throw "Release $ExpectedTag besitzt kein eindeutiges erwartetes Asset-Inventar."
    }
    foreach ($expectedAsset in $ExpectedAssets) {
        $matches = @($actualAssets | Where-Object { [string]$_.name -ceq [string]$expectedAsset.Name })
        if ($matches.Count -ne 1 -or [Int64]$matches[0].size -ne [Int64]$expectedAsset.Length) {
            throw "Release-Asset $($expectedAsset.Name) fehlt, ist doppelt oder hat eine unerwartete Groesse."
        }
        $digestProperty = $matches[0].PSObject.Properties['digest']
        $actualDigest = if ($null -ne $digestProperty) {
            [string]$digestProperty.Value
        }
        else {
            ''
        }
        $expectedDigest = "sha256:$([string]$expectedAsset.Sha256)".ToLowerInvariant()
        if ($actualDigest -notmatch '^sha256:[0-9a-fA-F]{64}$' -or
            $actualDigest.ToLowerInvariant() -ne $expectedDigest) {
            throw "GitHub-Digest fuer $($expectedAsset.Name) fehlt oder stimmt nicht mit dem lokal geprueften SHA-256 ueberein."
        }
    }
}

function Assert-PublishBinding {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$ExpectedArtifactPath,
        [Parameter(Mandatory = $true)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSourceTreeSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedCargoSha256,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ExpectedExpiresAtUtc
    )

    if ([DateTimeOffset]::UtcNow -ge $ExpectedExpiresAtUtc) {
        throw 'Produktiver Release blockiert: die zeitgebundene Develop-Zentrale-Attestierung ist inzwischen abgelaufen.'
    }

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
    if ([DateTimeOffset]::UtcNow -ge $ExpectedExpiresAtUtc) {
        throw 'Produktiver Release blockiert: die zeitgebundene Develop-Zentrale-Attestierung ist waehrend der erneuten Bindungspruefung abgelaufen.'
    }
}

function New-ReleaseProvenance {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$SourceCommit,
        [Parameter(Mandatory = $true)][string]$ReleaseRepositoryCommit,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$SignaturePath,
        [Parameter(Mandatory = $true)][string]$LatestManifestPath,
        [Parameter(Mandatory = $true)][string]$AuthenticodeCertificateThumbprint
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
        release_repository = $ReleaseRepo
        release_repository_commit = $ReleaseRepositoryCommit
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
        authenticode      = [ordered]@{
            certificate_thumbprint = $AuthenticodeCertificateThumbprint.ToUpperInvariant()
            digest_algorithm       = 'sha256'
            timestamp_protocol     = 'RFC3161'
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
    try {
        $attestedExpiresAtUtc = [DateTimeOffset]::Parse(
            [string]$preflightAttestation.ExpiresAtUtc,
            [Globalization.CultureInfo]::InvariantCulture
        ).ToUniversalTime()
    }
    catch {
        throw 'Develop-Zentrale-Preflight enthaelt keine gueltige Ablaufzeit.'
    }
    $attestedAuthenticodeThumbprint = (
        [string]$preflightAttestation.AuthenticodeCertificateThumbprint -replace '\s', ''
    ).ToUpperInvariant()
    if ($attestedCommit -notmatch '^[0-9a-f]{40}$' -or
        $attestedArtifactSha256 -notmatch '^[0-9a-f]{64}$' -or
        $attestedSourceTreeSha256 -notmatch '^[0-9a-f]{64}$' -or
        $attestedAuthenticodeThumbprint -notmatch '^[0-9A-F]{40}$' -or
        [string]$preflightAttestation.SourcePath -ne $preflightSourcePath) {
        throw 'Develop-Zentrale-Preflight enthaelt keine vollstaendige Commit-, Quell- und Herausgeberbindung.'
    }
    $attestedCargoSha256 = (Get-FileHash -LiteralPath $cargoManifest -Algorithm SHA256).Hash
    Assert-PublishBinding `
        -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
        -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
        -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
        -ExpectedCargoSha256 $attestedCargoSha256 -ExpectedExpiresAtUtc $attestedExpiresAtUtc
}

$cargoPath = Assert-Tool -Name "cargo" -Hint "Rust-Toolchain installieren (rustup)."
Invoke-Native -FilePath $cargoPath -Arguments @("tauri", "--version")

$updaterSigningKey = [System.Environment]::GetEnvironmentVariable("TAURI_SIGNING_PRIVATE_KEY")
$updaterSigningKeyPath = [System.Environment]::GetEnvironmentVariable("TAURI_SIGNING_PRIVATE_KEY_PATH")
$defaultUpdaterSigningKeyPath = Join-Path $env:USERPROFILE ".tauri\projectatlas-desktop.key"
if (
    [string]::IsNullOrWhiteSpace($updaterSigningKey) -and
    [string]::IsNullOrWhiteSpace($updaterSigningKeyPath) -and
    (Test-Path -LiteralPath $defaultUpdaterSigningKeyPath -PathType Leaf)
) {
    $updaterSigningKeyPath = $defaultUpdaterSigningKeyPath
    $env:TAURI_SIGNING_PRIVATE_KEY_PATH = $defaultUpdaterSigningKeyPath
}
if (
    -not [string]::IsNullOrWhiteSpace($updaterSigningKeyPath) -and
    -not (Test-Path -LiteralPath $updaterSigningKeyPath -PathType Leaf)
) {
    throw "TAURI_SIGNING_PRIVATE_KEY_PATH verweist nicht auf eine vorhandene Datei."
}
if ([string]::IsNullOrWhiteSpace($updaterSigningKey) -and -not [string]::IsNullOrWhiteSpace($updaterSigningKeyPath)) {
    $updaterSigningKey = (Get-Content -LiteralPath $updaterSigningKeyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($updaterSigningKey)) {
        throw "Die Datei aus TAURI_SIGNING_PRIVATE_KEY_PATH enthaelt keinen Signierschluessel."
    }
    # Nur der kurzlebige Wrapper-Prozess und seine Build-Kinder erhalten den
    # Schluessel. Weder Elternprozess noch Benutzer-/Maschinenumgebung werden
    # veraendert, und der Wert wird nicht ausgegeben.
    $env:TAURI_SIGNING_PRIVATE_KEY = $updaterSigningKey
}
$hasUpdaterSigningKey =
    -not [string]::IsNullOrWhiteSpace($updaterSigningKey) -or
    -not [string]::IsNullOrWhiteSpace($updaterSigningKeyPath)
if (-not $hasUpdaterSigningKey) {
    if (-not $AllowUnsignedUpdater) {
        throw "Kein Tauri-Updater-Signierschluessel gefunden. TAURI_SIGNING_PRIVATE_KEY oder TAURI_SIGNING_PRIVATE_KEY_PATH sicher bereitstellen — nie im Klartext an das Skript uebergeben oder committen. Nur zum lokalen Ausprobieren: -AllowUnsignedUpdater."
    }
    Write-Warning "Ohne Tauri-Updater-Schluessel gebaut: es entsteht keine .sig-Datei und der Auto-Updater lehnt diese Ausgabe ab. Das ist unabhaengig von Windows Authenticode."
}

$authenticodeConfiguration = Resolve-AuthenticodeConfiguration -Required:$Publish
if (
    $Publish -and
    $authenticodeConfiguration.Thumbprint -ne $attestedAuthenticodeThumbprint
) {
    throw 'Produktiver Release blockiert: das konfigurierte Authenticode-Zertifikat stimmt nicht mit dem von der Develop Zentrale attestierten Herausgeber ueberein.'
}

if ($Publish) {
    $ghPath = Assert-Tool -Name "gh" -Hint "GitHub CLI installieren und mit gh auth login anmelden."
    $releaseRepoQualified = "github.com/$ReleaseRepo"
    Invoke-Native -FilePath $ghPath -Arguments @("auth", "status", "--hostname", "github.com")
    $releaseRepositoryBinding = Get-ReleaseRepositoryBinding `
        -GhPath $ghPath -ReleaseRepository $ReleaseRepo
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
if ($Publish) {
    $existingReleaseTagCommit = Get-ReleaseTagCommit `
        -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
    if (-not [string]::IsNullOrWhiteSpace([string]$existingReleaseTagCommit)) {
        throw "Produktiver Release blockiert: der Versions-Tag $releaseTag existiert im Release-Repository bereits. Eine Version wird nie automatisch ueberschrieben."
    }
}
Write-Host "Version $Version bestaetigt in Cargo.toml und tauri.conf.json." -ForegroundColor Green
Write-Host "Tauri-Updater-Signatur konfiguriert: $($hasUpdaterSigningKey ? 'ja' : 'nein')"
Write-Host "Windows Authenticode konfiguriert: $($null -ne $authenticodeConfiguration ? 'ja' : 'nein')"

# Eingebettete Pfade neutralisieren: Rust schreibt absolute Quellpfade (samt
# Windows-Benutzername) in Panik-Texte und Debug-Infos jedes Binaries. Ohne die
# Remaps stuende der lokale Benutzerpfad in Sidecar UND Installer.
# CARGO_ENCODED_RUSTFLAGS trennt Argumente mit 0x1f. Das ist auf Windows
# notwendig, weil ein normales RUSTFLAGS den Repository-Pfad an Leerzeichen
# zerlegt. Reihenfolge ist tragend: rustc laesst bei mehreren Treffern das
# LETZTE Flag gewinnen.
$encodedRustFlagSeparator = [char]0x1f
$encodedRustFlags = [System.Collections.Generic.List[string]]::new()
$existingEncodedRustFlags = [System.Environment]::GetEnvironmentVariable("CARGO_ENCODED_RUSTFLAGS")
if (-not [string]::IsNullOrWhiteSpace($existingEncodedRustFlags)) {
    foreach ($flag in $existingEncodedRustFlags.Split($encodedRustFlagSeparator)) {
        if (-not [string]::IsNullOrWhiteSpace($flag)) {
            $encodedRustFlags.Add($flag)
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($env:RUSTFLAGS)) {
    throw "RUSTFLAGS ist bereits gesetzt. Fuer den Release bitte argumentgetreue Flags ueber CARGO_ENCODED_RUSTFLAGS bereitstellen."
}
$encodedRustFlags.Add("--remap-path-prefix=$env:USERPROFILE=~")
$encodedRustFlags.Add("--remap-path-prefix=$repositoryRoot=atlas")
$env:CARGO_ENCODED_RUSTFLAGS = $encodedRustFlags -join $encodedRustFlagSeparator
$env:RUSTFLAGS = $null

$builtSidecarPath = $null
if (-not $SkipSidecar) {
    $builtSidecarPath = Build-Sidecar `
        -RepositoryRoot $repositoryRoot -CargoPath $cargoPath -DesktopCrateRoot $desktopCrateRoot

    $firstRunTestPath = Join-Path $repositoryRoot 'scripts\Test-ProjectAtlasDesktopFirstRun.ps1'
    if (-not (Test-Path -LiteralPath $firstRunTestPath -PathType Leaf)) {
        throw "Ersteinrichtungs-Smoke-Test fehlt: $firstRunTestPath"
    }
    Write-Step 'Ersteinrichtung mit dem zu buendelnden Sidecar pruefen'
    & $firstRunTestPath -SidecarPath $builtSidecarPath
}
else {
    Write-Host "Sidecar-Bau uebersprungen (-SkipSidecar) — NICHT fuer echte Releases verwenden." -ForegroundColor Yellow
}

Write-Step "cargo tauri build"
# Sidecar und Authenticode werden nur fuer diesen Bundle-Lauf in eine gemeinsame
# JSON-Overlay-Konfiguration aufgenommen. Waere bundle.externalBin dauerhaft in
# tauri.conf.json gesetzt, braeche bereits `cargo check` ab, solange das Binary
# fehlt. Der Authenticode-Thumbprint ist kein Geheimnis; der Privatschluessel
# bleibt im Windows-Zertifikatsspeicher und wird nie in die Konfiguration kopiert.
$buildArguments = @("tauri", "build", "--ci")
$bundleOverlay = [ordered]@{}
if (-not $SkipSidecar) {
    $bundleOverlay.externalBin = @('binaries/projectatlas-cli')
}
if ($null -ne $authenticodeConfiguration) {
    $bundleOverlay.windows = [ordered]@{
        certificateThumbprint = $authenticodeConfiguration.Thumbprint
        digestAlgorithm       = 'sha256'
        timestampUrl          = $authenticodeConfiguration.TimestampUrl
        tsp                   = $true
    }
}
if ($bundleOverlay.Count -gt 0) {
    $buildOverlay = [ordered]@{ bundle = $bundleOverlay }
    $buildArguments += @(
        '--config',
        ($buildOverlay | ConvertTo-Json -Depth 8 -Compress)
    )
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
if ($hasUpdaterSigningKey -and $updaterInstallers.Count -ne 1) {
    $namen = ($artifacts | ForEach-Object { $_.Name }) -join ', '
    throw "Erwartet wurde genau ein signierbarer Setup-Installer der Version $Version. Vorhanden: $namen"
}
if ($hasUpdaterSigningKey) {
    $updaterInstaller = $updaterInstallers[0]
    $signaturePath = "$($updaterInstaller.FullName).sig"
    if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
        throw "Keine Tauri-Updater-Signaturdatei neben $($updaterInstaller.Name) gefunden. Steht bundle.createUpdaterArtifacts in tauri.conf.json auf true? Ohne .sig lehnt der Auto-Updater die Ausgabe ab."
    }
    $uploads.Add($signaturePath)

    Write-Step 'Tauri-Updater-Signatur kryptografisch pruefen'
    Invoke-Native -FilePath $cargoPath -WorkingDirectory $repositoryRoot -Arguments @(
        'run', '--locked', '--quiet', '--release', '-p', 'projectatlas-desktop',
        '--example', 'verify_updater_signature', '--',
        $updaterInstaller.FullName, $signaturePath, $tauriConfig
    )
    Write-Host 'Updater-Signatur passt zum exakten Installer und zum eingebetteten Public Key.' -ForegroundColor Green
}

Write-Step 'Windows-Authenticode-Signaturen pruefen'
$expectedAuthenticodeThumbprint = if ($null -ne $authenticodeConfiguration) {
    $authenticodeConfiguration.Thumbprint
}
else {
    ''
}
if (-not $SkipSidecar) {
    Assert-AuthenticodeArtifact `
        -Role 'ProjectAtlas-CLI-Sidecar' -Path $builtSidecarPath `
        -ExpectedThumbprint $expectedAuthenticodeThumbprint -Required:$Publish
}
foreach ($artifact in $artifacts) {
    Assert-AuthenticodeArtifact `
        -Role 'Windows-Installer' -Path $artifact.FullName `
        -ExpectedThumbprint $expectedAuthenticodeThumbprint -Required:$Publish
}

# Tauri signiert die fuer NSIS gepatchte Haupt-EXE innerhalb des Bundle-Laufs und
# stellt target\release\projectatlas-desktop.exe danach absichtlich aus einer
# unsignierten Kopie wieder her. Diesen Build-Pfad als "installierte EXE" zu
# pruefen waere deshalb ein falscher Negativbefund. Die tatsaechlich installierte
# Haupt-EXE muss nach der Installation auf einem sauberen Windows-System separat
# gegen denselben Thumbprint und einen RFC-3161-Zeitstempel geprueft werden.
Write-Host 'Installierte Haupt-EXE: verpflichtender Clean-System-Installations-E2E nach Bereitstellung; target\release ist dafuer kein gueltiger Ersatz.' -ForegroundColor Yellow

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
$releaseArguments.Add($releaseRepoQualified)
$releaseArguments.Add("--title")
$releaseArguments.Add("ProjectAtlas Desktop $releaseTag")
$releaseArguments.Add("--notes-file")
$releaseArguments.Add((Resolve-Path -LiteralPath $NotesFile).Path)
$releaseArguments.Add("--verify-tag")
$releaseArguments.Add("--draft")

if (-not $PSCmdlet.ShouldProcess("$ReleaseRepo ($releaseTag)", "privaten GitHub-Draft anlegen, vollstaendig bestuecken und erst danach veroeffentlichen")) {
    return
}

Assert-PublishBinding `
    -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
    -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
    -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
    -ExpectedCargoSha256 $attestedCargoSha256 -ExpectedExpiresAtUtc $attestedExpiresAtUtc
$tagBeforeDraft = Get-ReleaseTagCommit `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
if (-not [string]::IsNullOrWhiteSpace([string]$tagBeforeDraft)) {
    throw "Produktiver Release blockiert: der Versions-Tag $releaseTag wurde waehrend des Release-Laufs angelegt."
}
if ([DateTimeOffset]::UtcNow -ge $attestedExpiresAtUtc) {
    throw 'Produktiver Release blockiert: die Develop-Zentrale-Attestierung ist unmittelbar vor der Tag-Erstellung abgelaufen.'
}
New-ReleaseTagBinding `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag `
    -TargetCommit $releaseRepositoryBinding.TargetCommit
if ([DateTimeOffset]::UtcNow -ge $attestedExpiresAtUtc) {
    throw 'Produktiver Release blockiert: die Develop-Zentrale-Attestierung ist unmittelbar vor der Draft-Erstellung abgelaufen.'
}
Invoke-Native -FilePath $ghPath -Arguments $releaseArguments.ToArray()

if ($hasUpdaterSigningKey) {
    Write-Step "Update-Manifest latest.json erzeugen und nachreichen"

    # Die Download-Adresse wird beim Release ABGEFRAGT statt aus dem Dateinamen
    # zusammengebaut: GitHub normalisiert Asset-Namen (Leerzeichen werden zu Punkten),
    # ein geratener Link liefe ins Leere und der Updater faende die Ausgabe nie.
    $draftRelease = Get-GitHubReleaseState `
        -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
    $draftDatabaseId = [string]$draftRelease.databaseId
    if ([string]::IsNullOrWhiteSpace($draftDatabaseId)) {
        throw "Privater Release-Draft $releaseTag besitzt keine bindbare GitHub-Identitaet."
    }
    $assets = $draftRelease.assets
    # Auch hier an die Version gebunden: ein Release kann Artefakte mehrerer Laeufe
    # tragen, und "das erste setup.exe" waere dann Gluecksache.
    $installerAsset = $assets |
        Where-Object { $_.name -like "*setup.exe" -and $_.name -like "*_$($Version)_*" } |
        Select-Object -First 1
    if ($null -eq $installerAsset) {
        $namen = ($assets | ForEach-Object { $_.name }) -join ", "
        throw "Im Release $releaseTag ist kein Installer der Version $Version zu finden. Vorhanden: $namen"
    }

    $expectedReleaseAssets = [System.Collections.Generic.List[object]]::new()
    foreach ($upload in $uploads) {
        $localAsset = Get-Item -LiteralPath $upload
        $candidateNames = @($localAsset.Name, $localAsset.Name.Replace(' ', '.')) |
            Select-Object -Unique
        $remoteMatches = @($assets | Where-Object { $candidateNames -ccontains [string]$_.name })
        if ($remoteMatches.Count -ne 1) {
            throw "Lokales Release-Asset $($localAsset.Name) konnte im privaten Draft nicht eindeutig gebunden werden."
        }
        $expectedReleaseAssets.Add([pscustomobject]@{
                Name   = [string]$remoteMatches[0].name
                Length = [Int64]$localAsset.Length
                Sha256 = (Get-FileHash -LiteralPath $localAsset.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
    }
    Assert-GitHubReleaseState `
        -State $draftRelease -ExpectedDatabaseId $draftDatabaseId -ExpectedTag $releaseTag `
        -ExpectedTargetCommit $releaseRepositoryBinding.TargetCommit -ExpectedDraft $true `
        -ExpectedAssets $expectedReleaseAssets.ToArray()
    $draftTagCommit = Get-ReleaseTagCommit `
        -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
    if ($draftTagCommit -ne $releaseRepositoryBinding.TargetCommit) {
        throw "Privater Release-Draft $releaseTag verweist auf einen abweichenden Git-Tag."
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
        -SourceCommit $attestedCommit -ReleaseRepositoryCommit $releaseRepositoryBinding.TargetCommit `
        -InstallerPath $updaterInstaller.FullName `
        -SignaturePath $signaturePath -LatestManifestPath $manifestPath `
        -AuthenticodeCertificateThumbprint $attestedAuthenticodeThumbprint

    foreach ($generatedAssetPath in @($manifestPath, $provenancePath)) {
        $generatedAsset = Get-Item -LiteralPath $generatedAssetPath
        $expectedReleaseAssets.Add([pscustomobject]@{
                Name   = $generatedAsset.Name
                Length = [Int64]$generatedAsset.Length
                Sha256 = (Get-FileHash -LiteralPath $generatedAsset.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
    }

    Assert-PublishBinding `
        -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
        -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
        -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
        -ExpectedCargoSha256 $attestedCargoSha256 -ExpectedExpiresAtUtc $attestedExpiresAtUtc
    Invoke-Native -FilePath $ghPath -Arguments @(
        "release", "upload", $releaseTag, $manifestPath, $provenancePath,
        "--repo", $releaseRepoQualified
    )

    $draftRelease = Get-GitHubReleaseState `
        -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
    Assert-GitHubReleaseState `
        -State $draftRelease -ExpectedDatabaseId $draftDatabaseId -ExpectedTag $releaseTag `
        -ExpectedTargetCommit $releaseRepositoryBinding.TargetCommit -ExpectedDraft $true `
        -ExpectedAssets $expectedReleaseAssets.ToArray()
    Write-Host "latest.json und $(Split-Path -Leaf $provenancePath) im vollstaendigen privaten Draft bestaetigt; Manifest verweist auf $($installerAsset.url)" -ForegroundColor Green
}
else {
    Write-Warning "Ohne Tauri-Updater-Schluessel gebaut: es wurde KEIN latest.json erzeugt, der Auto-Updater findet diese Ausgabe nicht. Die Windows-Authenticode-Pruefung ist davon unabhaengig."
}

Assert-PublishBinding `
    -RepositoryRoot $repositoryRoot -ExpectedCommit $attestedCommit `
    -ExpectedArtifactPath $attestedArtifactPath -ExpectedArtifactSha256 $attestedArtifactSha256 `
    -SourcePath $preflightSourcePath -ExpectedSourceTreeSha256 $attestedSourceTreeSha256 `
    -ExpectedCargoSha256 $attestedCargoSha256 -ExpectedExpiresAtUtc $attestedExpiresAtUtc
$finalDraftRelease = Get-GitHubReleaseState `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
Assert-GitHubReleaseState `
    -State $finalDraftRelease -ExpectedDatabaseId $draftDatabaseId -ExpectedTag $releaseTag `
    -ExpectedTargetCommit $releaseRepositoryBinding.TargetCommit -ExpectedDraft $true `
    -ExpectedAssets $expectedReleaseAssets.ToArray()
$tagBeforePublish = Get-ReleaseTagCommit `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
if ($tagBeforePublish -ne $releaseRepositoryBinding.TargetCommit) {
    throw "Produktiver Release blockiert: der Versions-Tag $releaseTag zeigt unmittelbar vor der Veroeffentlichung auf einen abweichenden Commit."
}
if ([DateTimeOffset]::UtcNow -ge $attestedExpiresAtUtc) {
    throw 'Produktiver Release blockiert: die Develop-Zentrale-Attestierung ist unmittelbar vor der oeffentlichen Freigabe abgelaufen.'
}
Invoke-Native -FilePath $ghPath -Arguments @(
    "release", "edit", $releaseTag, "--repo", $releaseRepoQualified,
    "--verify-tag", "--draft=false"
)
$publishedRelease = Get-GitHubReleaseState `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
Assert-GitHubReleaseState `
    -State $publishedRelease -ExpectedDatabaseId $draftDatabaseId -ExpectedTag $releaseTag `
    -ExpectedTargetCommit $releaseRepositoryBinding.TargetCommit -ExpectedDraft $false `
    -ExpectedAssets $expectedReleaseAssets.ToArray() -RequireImmutable
$publishedTagCommit = Get-ReleaseTagCommit `
    -GhPath $ghPath -ReleaseRepository $ReleaseRepo -ReleaseTag $releaseTag
if ($publishedTagCommit -ne $releaseRepositoryBinding.TargetCommit) {
    throw "Release $releaseTag ist live, aber sein Git-Tag zeigt nicht auf den zuvor gebundenen Release-Repository-Commit."
}

Write-Step "Fertig"
Write-Host "ProjectAtlas Desktop $releaseTag veroeffentlicht unter $ReleaseRepo." -ForegroundColor Green
Write-Host "Bereits installierte Ausgaben bieten das Update beim naechsten Pruefen an." -ForegroundColor Green
