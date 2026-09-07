#Requires -Version 7.5
<# Schreibfreie Nachpruefung der tatsaechlichen lokalen Atlas-Installation. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$PreflightArtifact
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('TAURI_SIGNING_PRIVATE_KEY','TAURI_SIGNING_PRIVATE_KEY_PATH','TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
. "$PSScriptRoot/ProjectAtlasLocalInstall.ps1"
$Root = Assert-AtlasLocalSource -Root $Root -ExpectedCommit $ExpectedCommit
$package = $null
try {
    $preflight = Get-Content -LiteralPath $PreflightArtifact -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $package = Open-AtlasLocalPackage -Root $Root -ExpectedCommit $ExpectedCommit -ExpectedThumbprint $preflight.authenticode_certificate_thumbprint
    $receiptPath = Join-Path $package.Directory 'installed.json'
    [void](Assert-AtlasRegularPath $receiptPath)
    if ((Get-Item -LiteralPath $receiptPath).Length -gt 65536) { throw 'Installationsnachweis ist unplausibel gross.' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $preflight = Get-Content -LiteralPath $PreflightArtifact -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    if ($receipt.schema -cne 'projectatlas.desktop.local-install.v1' -or $receipt.target -cne 'projectatlas-desktop/desktop-app/prod' -or
        $receipt.scope -cne 'local-windows' -or $receipt.result -cne 'succeeded' -or
        -not (Test-AtlasSamePath $receipt.sourceRoot $Root) -or $receipt.sourceCommit -cne $ExpectedCommit -or
        $receipt.version -cne $package.Manifest.version -or $receipt.packageManifestSha256 -cne $package.ManifestHash -or
        $receipt.certificateThumbprint -ine $package.Manifest.certificateThumbprint -or
        -not (Test-AtlasSamePath $receipt.installPath (Get-AtlasLocalInstallDirectory)) -or
        -not (Test-AtlasSamePath $receipt.preflightPath $PreflightArtifact) -or
        $receipt.preflightSha256 -isnot [string] -or $receipt.preflightSha256 -cnotmatch '\A[0-9a-fA-F]{64}\z' -or
        $receipt.preflightSha256 -ine (Get-AtlasFileHash $PreflightArtifact) -or
        $receipt.runId -cne $preflight.run_id -or $preflight.expected_commit -cne $ExpectedCommit -or
        $preflight.project_id -cne 'projectatlas-desktop' -or $preflight.component_id -cne 'desktop-app' -or $preflight.environment -cne 'prod' -or
        $preflight.target_resource_group -cne 'local-windows' -or $preflight.target_app_name -cne 'projectatlas-desktop-local') {
        throw 'Installationsnachweis gehoert nicht zu diesem exakten zentralen Auftrag und Paket.'
    }
    $hashes = Assert-AtlasInstalledPayload $package
    foreach ($name in $hashes.Keys) { if ($receipt.actualHashes[$name] -cne $hashes[$name]) { throw 'Installierte Datei weicht vom Abschlussnachweis ab.' } }
    if (-not $receipt.process -or -not (Test-AtlasSamePath $receipt.process.path (Join-Path (Get-AtlasLocalInstallDirectory) 'projectatlas-desktop.exe')) -or
        -not (Test-AtlasProcessIdentity $receipt.process)) { throw 'Der bei Installation gestartete Atlas-Prozess ist nicht mehr eindeutig aktiv.' }
    $process = Get-Process -Id ([int]$receipt.process.pid) -ErrorAction Stop
    if (-not $process.Responding -or $process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Installiertes Atlas-Fenster antwortet nicht.' }
    $backupManifest = Join-Path $receipt.backupPath 'backup.json'
    [void](Assert-AtlasRegularPath $backupManifest)
    if ((Get-AtlasFileHash $backupManifest) -cne $receipt.backupManifestSha256) { throw 'Rollback-Nachweis ist nicht mehr unveraendert.' }
    $backup = Get-Content -LiteralPath $backupManifest -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    Assert-AtlasUserRegistryUnchanged $backup
    Write-Host "[OK] Installierte Atlas-Version $($receipt.version), Paketdateien, Signaturen, Zentrale-Auftrag, Benutzer-Registry und antwortendes Fenster exakt bestaetigt."
} finally { Close-AtlasLocalPackage $package }
