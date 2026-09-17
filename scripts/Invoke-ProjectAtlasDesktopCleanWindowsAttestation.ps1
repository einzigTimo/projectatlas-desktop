#Requires -Version 7
<#
.SYNOPSIS
    Attestierungsphase des zweiphasigen Desktop-Releases: Clean-Windows-Installation in Windows Sandbox.

.DESCRIPTION
    Wird ausschliesslich vom -Publish-Einstieg von .github/scripts/invoke-desktop-release.ps1 als
    eigener Prozess zwischen Draft- und Promote-Phase gestartet. Veroeffentlicht nichts, setzt
    keinen Tag und loescht keinen Draft.

    1. Draft-State lesen (SHA-256-gebunden) und Frist pruefen.
    2. Privaten Draft per ID remote pruefen (Draft, Tag, Commit, Asset-IDs, Digests) und
       sicherstellen, dass noch kein Versions-Tag existiert.
    3. Installer per Asset-ID aus dem Draft laden (nicht aus target\), Hash gegen Draft-State.
    4. .wsb erzeugen: Eingabeordner read-only, Ergebnisordner schreibbar, LogonCommand startet
       scripts/ProjectAtlasDesktopSandboxProbe.ps1 (Windows PowerShell 5.1).
    5. Windows Sandbox starten, mit Timeout auf done.marker warten, Sandbox beenden.
    6. Ergebnis mit Test-SandboxAttestationResult fail-closed bewerten, Draft erneut pruefen und
       attestation.json schreiben (gebunden an Draft-State-SHA, Draft-ID, Asset-Hashes,
       Quell-Commit; mit Ablauf).

    Netzwerk: standardmaessig aktiv. Begruendung: Ein frisches Windows laedt nicht vorinstallierte
    Stammzertifikate fuer die Authenticode-Kettenpruefung bei Bedarf nach, und der NSIS-
    WebView2-Bootstrapper (webviewInstallMode downloadBootstrapper) braucht Netz, falls die
    Laufzeit fehlt. Der Nachweis unterscheidet WebView2 vor und nach der Installation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{32}$')]
    [string]$RunId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$DraftStateSha256,

    [ValidateRange(300, 7200)]
    [int]$SandboxTimeoutSeconds = 2400,

    [ValidateSet('Enable', 'Disable')]
    [string]$SandboxNetworking = 'Enable'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repositoryRoot '.github\scripts\ProjectAtlasReleasePhases.ps1')
$policy = Get-ReleasePhasePolicy

function Write-AttestationStep {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not $IsWindows) {
    throw 'Die Clean-Windows-Attestierung laeuft nur unter Windows.'
}

$runDirectory = Get-ReleaseRunDirectory -RunId $RunId
$draftStatePath = Join-Path $runDirectory 'draft-state.json'
$attestationPath = Join-Path $runDirectory 'attestation.json'
if (Test-Path -LiteralPath $attestationPath) {
    throw 'Produktiver Release blockiert: fuer diesen Lauf existiert bereits eine Attestierung; sie wird nie ueberschrieben.'
}

Write-AttestationStep 'Draft-State pruefen'
$draftState = Read-BoundReleasePhaseDocument -Path $draftStatePath -ExpectedSha256 $DraftStateSha256 -Label 'Draft-State'
Assert-ReleasePhaseProblemsEmpty -Context 'Draft-State' -Problems @(
    Test-ReleaseDraftStateDocument -State $draftState -RunId $RunId -NowUtc ([DateTimeOffset]::UtcNow))

$sandboxExecutable = Resolve-WindowsSandboxExecutable
$ghCommand = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $ghCommand) {
    throw 'Produktiver Release blockiert: gh fehlt im PATH.'
}
$ghPath = $ghCommand.Source
Invoke-Native -FilePath $ghPath -Arguments @('auth', 'status', '--hostname', 'github.com')

$releaseRepository = [string]$draftState.release_repository
$releaseId = [string]$draftState.release_id
$releaseTag = [string]$draftState.release_tag
$expectedAssets = @($draftState.assets | ForEach-Object {
        [pscustomobject]@{
            Name    = [string]$_.name
            Length  = [Int64]$_.size
            Sha256  = [string]$_.sha256
            AssetId = [string]$_.asset_id
        }
    })

$assertDraftUnchanged = {
    $state = Get-GitHubReleaseById -GhPath $ghPath -ReleaseRepository $releaseRepository -ReleaseId $releaseId
    Assert-GitHubReleaseState -State $state -ExpectedDatabaseId $releaseId -ExpectedTag $releaseTag `
        -ExpectedTargetCommit ([string]$draftState.release_repository_commit) -ExpectedDraft $true `
        -ExpectedAssets $expectedAssets
    $tagCommit = Get-ReleaseTagCommit -GhPath $ghPath -ReleaseRepository $releaseRepository -ReleaseTag $releaseTag
    if (-not [string]::IsNullOrWhiteSpace([string]$tagCommit)) {
        throw "Produktiver Release blockiert: der Versions-Tag $releaseTag existiert vor der Promotion bereits."
    }
    return $state
}

Write-AttestationStep "Privaten Draft $releaseId remote pruefen"
[void](& $assertDraftUnchanged)

$sandboxRoot = Join-Path $runDirectory ('sandbox-' + [Guid]::NewGuid().ToString('N'))
$inputDirectory = Join-Path $sandboxRoot 'input'
$resultDirectory = Join-Path $sandboxRoot 'result'
[void](New-Item -ItemType Directory -Path $inputDirectory, $resultDirectory)

$installerName = [string]$draftState.updater_installer_name
$installerAsset = @($expectedAssets | Where-Object { $_.Name -ceq $installerName })
if ($installerAsset.Count -ne 1) {
    throw 'Produktiver Release blockiert: der Installer ist im Draft-State nicht eindeutig.'
}
Write-AttestationStep 'Installer per Asset-ID aus dem privaten Draft laden'
$installerPath = Join-Path $inputDirectory $installerName
Save-GitHubReleaseAssetById -GhPath $ghPath -ReleaseRepository $releaseRepository `
    -AssetId $installerAsset[0].AssetId -Destination $installerPath
$downloadedInstaller = Get-Item -LiteralPath $installerPath
if ([Int64]$downloadedInstaller.Length -ne $installerAsset[0].Length -or
    (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $installerAsset[0].Sha256) {
    throw 'Produktiver Release blockiert: der Installer aus dem Draft weicht vom Draft-State ab.'
}

$probeSource = Join-Path $PSScriptRoot 'ProjectAtlasDesktopSandboxProbe.ps1'
$probePath = Join-Path $inputDirectory 'sandbox-probe.ps1'
Copy-Item -LiteralPath $probeSource -Destination $probePath
$probeSha256 = (Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash.ToLowerInvariant()

$expectation = [ordered]@{
    schema_version                      = $policy.SandboxExpectationSchema
    nonce                               = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    version                             = [string]$draftState.version
    installer_name                      = $installerName
    installer_sha256                    = $installerAsset[0].Sha256
    authenticode_certificate_thumbprint = [string]$draftState.authenticode_certificate_thumbprint
    shutdown_when_done                  = $true
}
$expectation | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $inputDirectory 'expectation.json') -Encoding utf8NoBOM

$wsbPath = Join-Path $sandboxRoot 'attestation.wsb'
New-CleanWindowsSandboxConfiguration -InputDirectory $inputDirectory -ResultDirectory $resultDirectory `
    -Networking $SandboxNetworking | Set-Content -LiteralPath $wsbPath -Encoding utf8NoBOM

Write-AttestationStep "Windows Sandbox starten (Timeout $SandboxTimeoutSeconds s, Netzwerk $SandboxNetworking)"
Assert-NoWindowsSandboxRunning
$doneMarker = Join-Path $resultDirectory 'done.marker'
$resultPath = Join-Path $resultDirectory 'result.json'
try {
    Start-Process -FilePath $sandboxExecutable -ArgumentList @("`"$wsbPath`"") | Out-Null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($SandboxTimeoutSeconds)
    $sandboxSeen = $false
    $sandboxGoneSince = $null
    while (-not (Test-Path -LiteralPath $doneMarker -PathType Leaf)) {
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Produktiver Release blockiert: die Sandbox-Pruefung lieferte innerhalb von $SandboxTimeoutSeconds Sekunden kein Ergebnis."
        }
        $running = @(Get-WindowsSandboxProcess).Count -gt 0
        if ($running) {
            $sandboxSeen = $true
            $sandboxGoneSince = $null
        }
        elseif ($sandboxSeen) {
            if ($null -eq $sandboxGoneSince) {
                $sandboxGoneSince = [DateTimeOffset]::UtcNow
            }
            elseif ([DateTimeOffset]::UtcNow -ge $sandboxGoneSince.AddSeconds(60)) {
                throw 'Produktiver Release blockiert: die Windows Sandbox wurde ohne Ergebnis beendet.'
            }
        }
        Start-Sleep -Seconds 5
    }
    # Kurz warten, damit result.json vollstaendig geschrieben ist (done.marker folgt ihm).
    Start-Sleep -Seconds 2
}
finally {
    Stop-WindowsSandbox
}

Write-AttestationStep 'Sandbox-Ergebnis fail-closed bewerten'
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw 'Produktiver Release blockiert: die Sandbox hat kein result.json hinterlassen.'
}
$resultItem = Get-Item -LiteralPath $resultPath -Force
if (($resultItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $resultItem.Length -gt 1MB) {
    throw 'Produktiver Release blockiert: das Sandbox-Ergebnis ist kein regulaeres, begrenztes Dokument.'
}
$resultSha256 = (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
try {
    $sandboxResult = Read-BoundReleasePhaseDocument -Path $resultPath -ExpectedSha256 $resultSha256 -Label 'Sandbox-Ergebnis'
}
catch {
    throw "Produktiver Release blockiert: Sandbox-Ergebnis unlesbar. $($_.Exception.Message)"
}
$problems = @(Test-SandboxAttestationResult -Result $sandboxResult -Expectation ([pscustomobject]$expectation))
if ($problems.Count -gt 0) {
    Write-Host "Sandbox-Nachweise bleiben erhalten: $sandboxRoot" -ForegroundColor Yellow
}
Assert-ReleasePhaseProblemsEmpty -Context 'Clean-Windows-Attestierung' -Problems $problems

Write-AttestationStep 'Privaten Draft nach der Sandbox erneut pruefen'
[void](& $assertDraftUnchanged)
$now = [DateTimeOffset]::UtcNow
Assert-ReleasePhaseProblemsEmpty -Context 'Draft-State nach der Sandbox' -Problems @(
    Test-ReleaseDraftStateDocument -State $draftState -RunId $RunId -NowUtc $now)

$runDeadline = ConvertTo-ReleasePhaseUtc $draftState.run_deadline_utc
$expiresAt = $now.AddMinutes($policy.AttestationValidityMinutes)
if ($expiresAt -gt $runDeadline) {
    $expiresAt = $runDeadline
}
$attestation = [ordered]@{
    schema_version                      = $policy.AttestationSchema
    result                              = 'pass'
    run_id                              = $RunId
    draft_state_sha256                  = $DraftStateSha256.ToLowerInvariant()
    release_id                          = $releaseId
    release_tag                         = $releaseTag
    release_repository                  = $releaseRepository
    release_repository_commit           = [string]$draftState.release_repository_commit
    source_commit                       = [string]$draftState.source_commit
    version                             = [string]$draftState.version
    authenticode_certificate_thumbprint = [string]$draftState.authenticode_certificate_thumbprint
    assets                              = @($draftState.assets | ForEach-Object {
            [ordered]@{ name = [string]$_.name; size = [Int64]$_.size; sha256 = [string]$_.sha256; asset_id = [string]$_.asset_id }
        })
    sandbox                             = [ordered]@{
        result_sha256          = $resultSha256
        probe_script_sha256    = $probeSha256
        networking             = $SandboxNetworking
        webview2_before_install = [bool]$sandboxResult.webview2_before_install.present
        webview2_version       = [string]$sandboxResult.webview2.version
        main_window_title      = [string]$sandboxResult.gui.title
        evidence_directory     = $sandboxRoot
    }
    attested_at_utc                     = $now.ToString('o')
    expires_at_utc                      = $expiresAt.ToString('o')
}
$attestationSha256 = Write-ReleasePhaseDocument -Path $attestationPath -Document $attestation

Write-AttestationStep 'Clean-Windows-Attestierung bestanden'
Write-Host "Attestierung: $attestationPath (SHA-256 $attestationSha256, gueltig bis $($expiresAt.ToString('o')))" -ForegroundColor Green
