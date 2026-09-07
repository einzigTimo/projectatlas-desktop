#Requires -Version 7.5
<# Installiert ausschliesslich das persoenliche Atlas-Paket im laufenden Zentrale-Auftrag. #>
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
# Der Preflight allein darf keinen manuellen Aufruf des Installers legitimieren.
$ancestor = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$controller = $null
for ($depth = 0; $depth -lt 12 -and $ancestor.ParentProcessId -gt 0; $depth++) {
    $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId=$($ancestor.ParentProcessId)"
    if (-not $ancestor) { break }
    if ($ancestor.Name -ieq 'DeploymentController.exe' -or ($ancestor.Name -ieq 'dotnet.exe' -and $ancestor.CommandLine -match '(?i)(?:^|[\\/\s"])(?:DeploymentController\.dll)(?:"|\s|$)')) { $controller = $ancestor; break }
}
if (-not $controller) { throw 'Lokale Atlas-Installation muss Kind des laufenden Zentrale-Controllers sein.' }

function Read-AtlasInstallPreflight {
    $results = @(& (Join-Path $Root '.github/scripts/Assert-ControllerPreflight.ps1') `
        -ArtifactPath $PreflightArtifact -ProjectRoot $Root -ProjectId projectatlas-desktop `
        -ComponentId desktop-app -Environment prod -SourcePath 'crates/projectatlas-desktop/Cargo.toml' `
        -TargetResourceGroup local-windows -TargetAppName projectatlas-desktop-local -PassThru)
    if ($results.Count -ne 1 -or $results[0].ExpectedCommit -cne $ExpectedCommit) { throw 'Zentrale hat keinen eindeutigen lokalen Installationsauftrag attestiert.' }
    return $results[0]
}

$attestation = Read-AtlasInstallPreflight
$preflight = Get-Content -LiteralPath $PreflightArtifact -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$package = $null
$lease = $null
$backup = $null
$oldGui = $null
$script:installedGui = $null
$script:installedHashes = $null
$script:atlasMutationStarted = $false
$script:atlasRestored = $false
$script:atlasInstallerIdentity = $null
try {
    $package = Open-AtlasLocalPackage -Root $Root -ExpectedCommit $ExpectedCommit -ExpectedThumbprint $attestation.AuthenticodeCertificateThumbprint
    if ($package.Manifest.certificateThumbprint -ine $attestation.AuthenticodeCertificateThumbprint) { throw 'Paket und zentral attestierter Herausgeber unterscheiden sich.' }
    foreach ($relative in @('scripts/Test-ProjectAtlasDesktopFirstRun.ps1','.github/scripts/Assert-ControllerPreflight.ps1')) {
        foreach ($guard in (Open-AtlasPathGuards (Join-Path $Root $relative))) { $package.Handles.Add($guard) }
    }
    $lockPath = Join-Path (Get-AtlasLocalStateDirectory) 'install.lock'
    [void](Assert-AtlasRegularPath -Path $lockPath -AllowMissing)
    $lease = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $installedReceiptPath = Join-Path $package.Directory 'installed.json'
    if (Test-Path -LiteralPath $installedReceiptPath) {
        $previous = Get-Content -LiteralPath $installedReceiptPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        if ($previous.result -cnotin @('failed-before-install','failed-restored')) { throw 'Fuer dieses Paket existiert bereits ein erfolgreicher oder ungeklaerter Installationsnachweis.' }
        if ($previous.runId -cnotmatch '^[A-Za-z0-9_-]{1,100}$') { throw 'Vorheriger Installationsnachweis hat keine gueltige Laufbindung.' }
        [void](Assert-AtlasRegularPath $installedReceiptPath)
        $receiptArchive = Join-Path (Get-AtlasLocalStateDirectory) "receipts/$ExpectedCommit"
        [void](Assert-AtlasRegularPath -Path $receiptArchive -AllowMissing)
        [void][IO.Directory]::CreateDirectory($receiptArchive)
        $previousPath = Join-Path $receiptArchive ("installed-$($previous.runId).json")
        if (Test-Path -LiteralPath $previousPath) { throw 'Vorheriger Installationsversuch ist bereits archiviert; Wiederanlauf muss zuerst geklaert werden.' }
        [IO.File]::Move($installedReceiptPath, $previousPath, $false)
    }
    Assert-AtlasWebViewRuntime
    Assert-AtlasNoInstalledSidecar
    $oldGui = Get-AtlasRunningGui
    Stop-AtlasExactGui -Identity $oldGui
    Assert-AtlasNoInstalledSidecar
    $backup = New-AtlasInstallBackup -RunId $preflight.run_id
    $install = Get-AtlasLocalInstallDirectory
    $operations = @{
        Revalidate = {
            [void](Assert-AtlasLocalSource -Root $Root -ExpectedCommit $ExpectedCommit)
            $fresh = Read-AtlasInstallPreflight
            if ($fresh.ArtifactSha256 -cne $attestation.ArtifactSha256 -or $fresh.AuthenticodeCertificateThumbprint -ine $package.Manifest.certificateThumbprint) { throw 'Installationsauftrag hat sich nach der Sicherung veraendert.' }
            Assert-AtlasNoInstalledSidecar
            if (Get-AtlasRunningGui) { throw 'Atlas wurde waehrend der Vorbereitung erneut geoeffnet.' }
            Assert-AtlasRestoredBackup $backup
        }
        Install = {
            $script:atlasMutationStarted = $true
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $package.Directory 'installer.exe'
            $start.WorkingDirectory = $package.Directory
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            Remove-AtlasSigningEnvironment $start
            # NSIS verlangt /D als letztes Argument ohne Anfuehrungszeichen um seinen Wert.
            $start.Arguments = "/S /UPDATE /NS /D=$install"
            $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
            try {
                if (-not $process.Start()) { throw 'Der zentral gebundene Installer konnte nicht starten.' }
                $identity = Get-AtlasProcessIdentity $process
                $script:atlasInstallerIdentity = $identity
                if (-not $process.WaitForExit(300000)) {
                    if (-not (Test-AtlasProcessIdentity $identity)) { throw 'Installer-Prozessidentitaet hat sich geaendert; Wiederherstellung bleibt gesperrt.' }
                    $process.Kill($true)
                    if (-not $process.WaitForExit(15000)) { throw 'Installer laeuft nach Zeitlimit weiter; Wiederherstellung ist nicht sicher.' }
                    throw 'Lokaler Installer wurde wegen Zeitueberschreitung beendet.'
                }
                if ($process.ExitCode -ne 0) { throw "Lokaler Installer meldet Exitcode $($process.ExitCode)." }
            } finally { $process.Dispose() }
        }
        Verify = {
            $script:installedHashes = Assert-AtlasInstalledPayload $package
            Assert-AtlasUserRegistryUnchanged $backup
            & pwsh -NoProfile -File (Join-Path $Root 'scripts/Test-ProjectAtlasDesktopFirstRun.ps1') -SidecarPath (Join-Path $install 'projectatlas-cli.exe')
            if ($LASTEXITCODE -ne 0) { throw 'Ersteinrichtungs-Abnahme mit dem installierten Sidecar ist fehlgeschlagen.' }
            Assert-AtlasUserRegistryUnchanged $backup
            $script:installedGui = Start-AtlasInstalledGui
            Assert-AtlasUserRegistryUnchanged $backup
            $script:installedHashes = Assert-AtlasInstalledPayload $package
        }
        Restore = {
            if ($script:atlasInstallerIdentity -and (Test-AtlasProcessIdentity $script:atlasInstallerIdentity)) { throw 'Ein noch laufender Installer verhindert die sichere Wiederherstellung.' }
            Stop-AtlasExactGui -Identity $script:installedGui -AllowForce
            $unexpected = Get-AtlasRunningGui
            if ($unexpected) { throw 'Ein nicht vom Update gestarteter Atlas-Prozess blockiert die Wiederherstellung.' }
            Assert-AtlasNoInstalledSidecar
            Restore-AtlasInstallBackup $backup
            $script:atlasRestored = $true
        }
        VerifyRestored = {
            Assert-AtlasRestoredBackup $backup
            if ($oldGui) { $script:installedGui = Start-AtlasInstalledGui }
        }
        WriteReceipt = {
            param($Result)
            $receipt = [ordered]@{
                schema='projectatlas.desktop.local-install.v1'; target='projectatlas-desktop/desktop-app/prod'; scope='local-windows'
                sourceRoot=$Root; sourceCommit=$ExpectedCommit; version=$package.Manifest.version; runId=$preflight.run_id
                preflightPath=$attestation.ArtifactPath; preflightSha256=$attestation.ArtifactSha256
                packageManifestSha256=$package.ManifestHash; certificateThumbprint=$package.Manifest.certificateThumbprint
                installPath=$install; backupPath=$backup.directory; backupManifestSha256=$backup.manifestSha256
                result=$Result; actualHashes=$script:installedHashes; process=$script:installedGui
                completedAtUtc=[DateTimeOffset]::UtcNow.ToString('O')
            }
            Write-AtlasLocalJson -Path $installedReceiptPath -Value $receipt
        }
    }
    Invoke-AtlasLocalInstallTransaction $operations
    Write-Host "[OK] ProjectAtlas Desktop $($package.Manifest.version) lokal installiert und am echten Fenster abgenommen."
} catch {
    # Ein Vorbereitungsfehler nach dem regulaeren Schliessen darf das alte Fenster nicht unnoetig geschlossen lassen.
    if ($oldGui -and (-not $script:atlasMutationStarted -or $script:atlasRestored) -and -not (Get-AtlasRunningGui)) {
        try { [void](Start-AtlasInstalledGui) } catch { Write-Warning 'Das vorherige Atlas-Fenster konnte nicht wieder geoeffnet werden.' }
    }
    throw
} finally {
    if ($lease) { $lease.Dispose() }
    Close-AtlasLocalPackage $package
}
