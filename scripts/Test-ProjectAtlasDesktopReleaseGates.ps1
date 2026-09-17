#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReleaseScript = (Join-Path $PSScriptRoot '..\.github\scripts\invoke-desktop-release.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseScriptPath = (Resolve-Path -LiteralPath $ReleaseScript).Path
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $releaseScriptPath) '..\..'))
$releaseScriptText = Get-Content -LiteralPath $releaseScriptPath -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $releaseScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Release-Skript kann fuer den Gate-Test nicht geparst werden: $($parseErrors[0].Message)"
}

$phasesScriptPath = Join-Path (Split-Path -Parent $releaseScriptPath) 'ProjectAtlasReleasePhases.ps1'
$attestationScriptPath = Join-Path $repositoryRoot 'scripts\Invoke-ProjectAtlasDesktopCleanWindowsAttestation.ps1'
$sandboxProbePath = Join-Path $repositoryRoot 'scripts\ProjectAtlasDesktopSandboxProbe.ps1'
$parsedSupportScripts = @{}
foreach ($supportPath in @($phasesScriptPath, $attestationScriptPath, $sandboxProbePath)) {
    $supportTokens = $null
    $supportErrors = $null
    $supportAst = [Management.Automation.Language.Parser]::ParseFile($supportPath, [ref]$supportTokens, [ref]$supportErrors)
    if ($supportErrors.Count -gt 0) {
        throw "Release-Phasenskript kann nicht geparst werden: $supportPath - $($supportErrors[0].Message)"
    }
    $parsedSupportScripts[$supportPath] = $supportAst
}
$phasesAst = $parsedSupportScripts[$phasesScriptPath]
$phasesText = Get-Content -LiteralPath $phasesScriptPath -Raw
$attestationText = Get-Content -LiteralPath $attestationScriptPath -Raw

# 1. Der Einphasen-Altpfad ist entfernt; der Wrapper selbst kann keinen Draft freigeben.
if ($releaseScriptText -match 'legacySingleInvocation|executeLegacy') {
    throw 'Der gesperrte Einphasen-Altpfad ist im Release-Wrapper noch vorhanden.'
}
foreach ($forbidden in @('draft=false', "'release', 'edit'", 'git/refs', '--verify-tag', 'New-ReleaseTagBinding')) {
    if ($releaseScriptText.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Der Release-Wrapper enthaelt einen unzulaessigen Freigabe- oder Tag-Pfad: $forbidden"
    }
}
foreach ($forbidden in @('draft=false', 'Publish-GitHubDraftRelease', "'release', 'create'", "'release', 'edit'", "'--method', 'POST'")) {
    if ($attestationText.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Die Attestierungsphase darf nichts veroeffentlichen oder anlegen: $forbidden"
    }
}

# 2. Die einzige Freigabe liegt in Publish-GitHubDraftRelease und ist nur in der Promote-Phase erreichbar.
$publishFunction = @($phasesAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-GitHubDraftRelease'
        }, $true))
$draftFalseCount = ([regex]::Matches($phasesText, 'draft=false')).Count
if ($publishFunction.Count -ne 1 -or $draftFalseCount -ne 1 -or
    -not $publishFunction[0].Extent.Text.Contains('draft=false', [StringComparison]::Ordinal)) {
    throw 'Die Draft-Freigabe ist nicht exklusiv in Publish-GitHubDraftRelease gekapselt.'
}
$publishCalls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Publish-GitHubDraftRelease'
        }, $true))
$topLevelIfs = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] })
$promoteBlocks = @($topLevelIfs | Where-Object { $_.Clauses.Count -eq 1 -and $_.Clauses[0].Item1.Extent.Text -ceq '$promotePhase' })
$publishEntryBlocks = @($topLevelIfs | Where-Object { $_.Clauses.Count -eq 1 -and $_.Clauses[0].Item1.Extent.Text -ceq '$Publish' })
if ($publishCalls.Count -ne 1 -or $promoteBlocks.Count -ne 1 -or
    $publishCalls[0].Extent.StartOffset -lt $promoteBlocks[0].Extent.StartOffset -or
    $publishCalls[0].Extent.EndOffset -gt $promoteBlocks[0].Extent.EndOffset) {
    throw 'Publish-GitHubDraftRelease ist nicht ausschliesslich aus der Promote-Phase erreichbar.'
}
$promoteText = $promoteBlocks[0].Extent.Text
$authorizationOffset = $promoteText.IndexOf('Test-ReleasePromotionAuthorization', [StringComparison]::Ordinal)
$lastAuthorizationOffset = $promoteText.LastIndexOf('Test-ReleasePromotionAuthorization', [StringComparison]::Ordinal)
$publishOffsetInPromote = $promoteText.IndexOf('Publish-GitHubDraftRelease', [StringComparison]::Ordinal)
$remoteVerifyOffset = $promoteText.IndexOf('Confirm-RemoteReleaseAssets', [StringComparison]::Ordinal)
if ($authorizationOffset -lt 0 -or $remoteVerifyOffset -lt $authorizationOffset -or
    $lastAuthorizationOffset -le $remoteVerifyOffset -or $publishOffsetInPromote -le $lastAuthorizationOffset -or
    -not $promoteText.Contains('Read-BoundReleasePhaseDocument -Path $attestationPath', [StringComparison]::Ordinal)) {
    throw 'Die Promotion prueft Attestierung und Remote-Draft nicht vor der Freigabe.'
}
$promoteLastStatement = $promoteBlocks[0].Clauses[0].Item2.Statements[-1]
$buildOffset = $releaseScriptText.IndexOf('$cargoPath = Assert-Tool -Name "cargo"', [StringComparison]::Ordinal)
if ($promoteLastStatement.Extent.Text -cne 'return' -or $buildOffset -lt $promoteBlocks[0].Extent.EndOffset) {
    throw 'Die Promote-Phase endet nicht vor dem Build- und Draft-Pfad.'
}

# 3. Der registrierte -Publish-Einstieg startet genau drei getrennte Prozesse in fester Reihenfolge.
if ($publishEntryBlocks.Count -ne 1) {
    throw 'Der -Publish-Einstieg ist nicht eindeutig.'
}
$entryText = $publishEntryBlocks[0].Extent.Text
$phaseCalls = @($publishEntryBlocks[0].FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-ReleasePhaseProcess'
        }, $true))
$draftCallOffset = $entryText.IndexOf("-PhaseName 'Draft'", [StringComparison]::Ordinal)
$attestCallOffset = $entryText.IndexOf("-PhaseName 'Clean-Windows-Attestierung'", [StringComparison]::Ordinal)
$promoteCallOffset = $entryText.IndexOf("-PhaseName 'Promotion'", [StringComparison]::Ordinal)
if ($phaseCalls.Count -ne 3 -or $draftCallOffset -lt 0 -or $attestCallOffset -le $draftCallOffset -or
    $promoteCallOffset -le $attestCallOffset -or
    $publishEntryBlocks[0].Clauses[0].Item2.Statements[-1].Extent.Text -cne 'return' -or
    $entryText.Contains('Publish-GitHubDraftRelease', [StringComparison]::Ordinal) -or
    $publishEntryBlocks[0].Extent.EndOffset -gt $promoteBlocks[0].Extent.StartOffset) {
    throw 'Der -Publish-Einstieg startet Draft, Attestierung und Promotion nicht getrennt, geordnet und ohne eigene Freigabe.'
}

# 4. Die Draft-Phase legt einen Draft ohne Tag an und bindet ihn an den geprueften Commit.
$draftCreateOffset = $releaseScriptText.IndexOf("`$releaseArguments.Add('create')", [StringComparison]::Ordinal)
$draftTargetOffset = $releaseScriptText.IndexOf("`$releaseArguments.Add('--target')", [StringComparison]::Ordinal)
$draftFlagOffset = $releaseScriptText.IndexOf("`$releaseArguments.Add('--draft')", [StringComparison]::Ordinal)
$draftStateWriteOffset = $releaseScriptText.IndexOf('Write-ReleasePhaseDocument -Path $draftStatePath', [StringComparison]::Ordinal)
if ($draftCreateOffset -lt $buildOffset -or $draftTargetOffset -le $draftCreateOffset -or
    $draftFlagOffset -le $draftCreateOffset -or $draftStateWriteOffset -le $draftFlagOffset) {
    throw 'Die Draft-Phase erzeugt keinen an --target gebundenen privaten Draft mit anschliessendem Draft-State.'
}

. $phasesScriptPath
foreach ($functionName in @(
        'Invoke-TauriBundle',
        'Build-Sidecar',
        'ConvertTo-GitHubRepositorySlug',
        'Get-ReleaseRepositoryBinding',
        'Assert-PublishBinding',
        'New-FrozenAssetInventory',
        'New-ReleaseVerificationRoot',
        'New-ReleaseVerificationStage',
        'Remove-ReleaseVerificationRoot',
        'Copy-FrozenAssetsForUpload',
        'Assert-DownloadedReleaseAssets',
        'Get-VerifiedAsset',
        'New-ReleaseProvenance')) {
    $definition = $ast.FindAll(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        },
        $true
    ) | Select-Object -First 1
    if ($null -eq $definition) {
        throw "Erwartete Funktion fehlt im Release-Skript: $functionName"
    }
    Invoke-Expression $definition.Extent.Text
}
foreach ($functionName in @('New-NativeProcessStartInfo', 'Invoke-NativeCapture', 'Get-ReleaseTagCommit', 'Assert-GitHubReleaseState')) {
    if ($null -eq (Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Erwartete Funktion fehlt in ProjectAtlasReleasePhases.ps1: $functionName"
    }
}

$script:testMode = 'binding'
$script:testCommit = 'a' * 40
$script:testTagObject = 'b' * 40
$script:testPeeledCommit = 'c' * 40
$script:testImmutableReleases = 'true'
$script:testFetchedRemoteMain = $false
$sourceRepository = 'einzigTimo/projectatlas-desktop'
$ReleaseRepo = 'owner/repository'

$releaseSource = Get-Content -LiteralPath $releaseScriptPath -Raw
$firstRunOffset = $releaseSource.IndexOf('Invoke-Native -FilePath $pwshPath', [StringComparison]::Ordinal)
$noBundleOffset = $releaseSource.IndexOf("@('tauri', 'build', '--ci', '--no-bundle')", [StringComparison]::Ordinal)
$keyReadOffset = $releaseSource.IndexOf("GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY')", [StringComparison]::Ordinal)
$bundleOffset = $releaseSource.IndexOf('Invoke-TauriBundle @bundleInvocation', [StringComparison]::Ordinal)
if ($firstRunOffset -lt 0 -or $noBundleOffset -le $firstRunOffset -or
    $keyReadOffset -le $noBundleOffset -or $bundleOffset -le $keyReadOffset) {
    throw 'Der Updater-Schluessel ist nicht eng auf den Bundle-Schritt nach Sidecar, FirstRun und schluessellosem App-Bau begrenzt.'
}
if ($releaseSource -match '\$env:TAURI_SIGNING_PRIVATE_KEY(?:_PATH|_PASSWORD)?\s*=') {
    throw 'Der Release-Wrapper darf Signiergeheimnisse nicht global in seine Prozessumgebung schreiben.'
}
$localUpdaterCheckOffset = $releaseSource.LastIndexOf(
    "Invoke-Native -FilePath `$signatureVerifierPath",
    [StringComparison]::Ordinal
)
$localAuthenticodeCheckOffset = $releaseSource.LastIndexOf(
    "-Role 'Windows-Installer'",
    [StringComparison]::Ordinal
)
$freezeOffset = $releaseSource.IndexOf(
    '$frozenReleaseAssets = @(New-FrozenAssetInventory',
    [StringComparison]::Ordinal
)
if ($freezeOffset -le $localUpdaterCheckOffset -or $freezeOffset -le $localAuthenticodeCheckOffset) {
    throw 'Release-Hashes werden nicht unmittelbar nach den lokalen Kryptopruefungen eingefroren.'
}

$readinessWorkflow = Get-Content -LiteralPath (
    Join-Path $repositoryRoot '.github\workflows\03-auto-release.yml'
) -Raw
if ($readinessWorkflow -notmatch '(?ms)^permissions:\s*\r?\n\s+contents:\s*read\s*\r?\n\s+actions:\s*read\s*$' -or
    $readinessWorkflow -match '(?m)^\s*actions:\s*write\s*$') {
    throw '03-Release-Readiness besitzt mehr als die erforderliche Leseberechtigung fuer Actions.'
}

$secretNames = @(
    'TAURI_SIGNING_PRIVATE_KEY',
    'TAURI_SIGNING_PRIVATE_KEY_PATH',
    'TAURI_SIGNING_PRIVATE_KEY_PASSWORD'
)
$originalSecrets = @{}
foreach ($secretName in $secretNames) {
    $originalSecrets[$secretName] = [Environment]::GetEnvironmentVariable($secretName, 'Process')
}
try {
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'parent-test-key', 'Process')
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', 'parent-test-path', 'Process')
    [Environment]::SetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'parent-test-password', 'Process')

    $normalStart = New-NativeProcessStartInfo -FilePath 'does-not-run' -Arguments @()
    foreach ($secretName in $secretNames) {
        if ($normalStart.Environment.ContainsKey($secretName)) {
            throw "Normaler Kindprozess wuerde $secretName erben."
        }
    }

    $pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $childProbe = @'
$key = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process')
$path = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', 'Process')
$password = [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process')
if ($key -eq 'bundle-child-key' -and $null -eq $path -and $password -eq 'bundle-child-password') {
    exit 0
}
exit 97
'@
    Invoke-TauriBundle `
        -CargoPath $pwshPath -WorkingDirectory $repositoryRoot `
        -Arguments @('-NoProfile', '-Command', $childProbe) `
        -SigningKey 'bundle-child-key' -SigningKeyPassword 'bundle-child-password'

    if ([Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY', 'Process') -ne 'parent-test-key' -or
        [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PATH', 'Process') -ne 'parent-test-path' -or
        [Environment]::GetEnvironmentVariable('TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'Process') -ne 'parent-test-password') {
        throw 'Der isolierte Bundle-Prozess hat die Umgebung des aufrufenden Prozesses veraendert.'
    }
}
finally {
    foreach ($secretName in $secretNames) {
        [Environment]::SetEnvironmentVariable($secretName, $originalSecrets[$secretName], 'Process')
    }
}

$captureProbe = @'
[Console]::Out.Write('machine-readable-stdout')
[Console]::Error.Write('diagnostic-stderr')
exit 0
'@
$capturedStdout = Invoke-NativeCapture `
    -FilePath $pwshPath -WorkingDirectory $repositoryRoot `
    -Arguments @('-NoProfile', '-Command', $captureProbe)
if ($capturedStdout -cne 'machine-readable-stdout') {
    throw 'Invoke-NativeCapture vermischt erfolgreichen stderr weiterhin mit dem maschinenlesbaren stdout.'
}

function Get-TestFunctionDefinition {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SourceLabel
    )

    $matches = @($Ast.FindAll(
            {
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            },
            $true
        ))
    if ($matches.Count -ne 1) {
        throw "$SourceLabel enthaelt nicht genau eine Funktion $Name."
    }
    return $matches[0]
}

function Assert-SourceFingerprintBlocksPathRedirection {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Implementation,
        [Parameter(Mandatory = $true)][string]$Scenario
    )

    $blocked = $false
    try {
        [void](Get-SourceFingerprint -ResolvedSource $Path)
    }
    catch {
        $blocked = $_.Exception.Message -like '*symbolischen Link oder eine Junction*'
    }
    if (-not $blocked) {
        throw "$Implementation blockiert $Scenario nicht fail-closed."
    }
}

function Remove-TestPathRedirection {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$Kind
    )

    try {
        if ($Kind -eq 'Directory') {
            [IO.Directory]::Delete($Path, $false)
        }
        else {
            [IO.File]::Delete($Path)
        }
    }
    catch [IO.DirectoryNotFoundException] {
        return
    }
    catch [IO.FileNotFoundException] {
        return
    }
    $remainingGuard = $null
    try {
        $remainingGuard = [ProjectAtlas.SourceFingerprintPathGuard]::Open(
            $Path,
            $Kind -eq 'Directory'
        )
    }
    catch {
        $exceptionCursor = $_.Exception
        $nativeErrorCode = $null
        while ($null -ne $exceptionCursor) {
            if ($exceptionCursor -is [ComponentModel.Win32Exception]) {
                $nativeErrorCode = $exceptionCursor.NativeErrorCode
            }
            $exceptionCursor = $exceptionCursor.InnerException
        }
        if ($nativeErrorCode -in @(2, 3)) {
            return
        }
        throw
    }
    finally {
        if ($null -ne $remainingGuard) {
            $remainingGuard.Dispose()
        }
    }
    throw "Test-Link konnte nicht sicher entfernt werden: $Kind."
}

function Get-TestNativePathInformation {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $guard = [ProjectAtlas.SourceFingerprintPathGuard]::Open($item.FullName, $item.PSIsContainer)
    try {
        return [pscustomobject]@{
            FileAttributes = $guard.FileAttributes
            ReparseTag     = $guard.ReparseTag
        }
    }
    finally {
        $guard.Dispose()
    }
}

function Assert-TestNativeGuardBlocksReplacement {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Implementation
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $guard = [ProjectAtlas.SourceFingerprintPathGuard]::Open(
        $item.FullName,
        $Kind -eq 'Directory'
    )
    $replacementPath = "$Path.guard-replacement"
    try {
        $replacementBlocked = $false
        try {
            if ($Kind -eq 'Directory') {
                [IO.Directory]::Move($Path, $replacementPath)
            }
            else {
                [IO.File]::Move($Path, $replacementPath)
            }
        }
        catch {
            $exceptionCursor = $_.Exception
            while ($null -ne $exceptionCursor) {
                if (($exceptionCursor.HResult -band 0xFFFF) -eq 32) {
                    $replacementBlocked = $true
                    break
                }
                $exceptionCursor = $exceptionCursor.InnerException
            }
            if (-not $replacementBlocked) {
                throw
            }
        }
        if (-not $replacementBlocked) {
            if (Test-Path -LiteralPath $replacementPath) {
                if ($Kind -eq 'Directory') {
                    [IO.Directory]::Move($replacementPath, $Path)
                }
                else {
                    [IO.File]::Move($replacementPath, $Path)
                }
            }
            throw "$Implementation haelt keinen fail-closed Austauschschutz fuer $Kind-Pfade."
        }

        if ($Kind -eq 'File') {
            $writeHandle = $null
            $writeBlocked = $false
            try {
                $writeHandle = [IO.File]::Open(
                    $Path,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite
                )
            }
            catch {
                $exceptionCursor = $_.Exception
                while ($null -ne $exceptionCursor) {
                    if (($exceptionCursor.HResult -band 0xFFFF) -eq 32) {
                        $writeBlocked = $true
                        break
                    }
                    $exceptionCursor = $exceptionCursor.InnerException
                }
                if (-not $writeBlocked) {
                    throw
                }
            }
            finally {
                if ($null -ne $writeHandle) {
                    $writeHandle.Dispose()
                }
            }
            if (-not $writeBlocked) {
                throw "$Implementation haelt keinen fail-closed Schreibschutz waehrend des Datei-Hashings."
            }
        }
    }
    finally {
        $guard.Dispose()
    }
}

$preflightScriptPath = Join-Path $repositoryRoot '.github\scripts\Assert-ControllerPreflight.ps1'
$preflightTokens = $null
$preflightParseErrors = $null
$preflightAst = [Management.Automation.Language.Parser]::ParseFile(
    $preflightScriptPath,
    [ref]$preflightTokens,
    [ref]$preflightParseErrors
)
if ($preflightParseErrors.Count -gt 0) {
    throw "Preflight-Pruefer kann fuer den Gate-Test nicht geparst werden: $($preflightParseErrors[0].Message)"
}
$schemaGuards = @($preflightAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.Contains('$artifact.schema_version', [StringComparison]::Ordinal)
        }, $true))
if ($schemaGuards.Count -ne 1) {
    throw 'Der Preflight-Pruefer enthaelt nicht genau ein pruefbares Schema-/Producer-Gate.'
}
$schemaCases = @(
    @{ Name = 'aktueller Controller'; Schema = 'deploy-controller.preflight.v1'; Producer = 'Deployment-Controller'; Result = 'pass'; Accept = $true },
    @{ Name = 'veraltetes Schema'; Schema = 'studiohamburg.deploy-preflight.v1'; Producer = 'Deployment-Controller'; Result = 'pass'; Accept = $false },
    @{ Name = 'unbekannte Version'; Schema = 'deploy-controller.preflight.v2'; Producer = 'Deployment-Controller'; Result = 'pass'; Accept = $false },
    @{ Name = 'fehlendes Schema'; Schema = $null; Producer = 'Deployment-Controller'; Result = 'pass'; Accept = $false },
    @{ Name = 'fremder Producer'; Schema = 'deploy-controller.preflight.v1'; Producer = 'anderer-producer'; Result = 'pass'; Accept = $false },
    @{ Name = 'rotes Ergebnis'; Schema = 'deploy-controller.preflight.v1'; Producer = 'Deployment-Controller'; Result = 'fail'; Accept = $false }
)
foreach ($schemaCase in $schemaCases) {
    $accepted = $true
    try {
        & {
            param($Case, $Guard)
            $artifact = [pscustomobject]@{
                schema_version = $Case.Schema
                producer       = $Case.Producer
                result         = $Case.Result
            }
            Invoke-Expression $Guard
        } $schemaCase $schemaGuards[0].Extent.Text
    }
    catch {
        if ($_.Exception.Message -notlike 'Preflight-Artefakt hat ein unbekanntes Schema*') {
            throw
        }
        $accepted = $false
    }
    if ($accepted -ne $schemaCase.Accept) {
        throw "Schema-/Producer-Gate liefert fuer '$($schemaCase.Name)' ein falsches Ergebnis."
    }
}
$fingerprintImplementations = @(
    [pscustomobject]@{
        Name       = 'release-wrapper'
        Definition = Get-TestFunctionDefinition `
            -Ast $ast -Name 'Get-SourceFingerprint' -SourceLabel 'Release-Wrapper'
    },
    [pscustomobject]@{
        Name       = 'preflight-checker'
        Definition = Get-TestFunctionDefinition `
            -Ast $preflightAst -Name 'Get-SourceFingerprint' -SourceLabel 'Preflight-Pruefer'
    }
)
foreach ($implementation in $fingerprintImplementations) {
    $fingerprintSource = $implementation.Definition.Extent.Text
    foreach ($requiredFragment in @(
            'FileAttributeTagInfoClass = 9',
            'GenericRead = 0x80000000',
            'FileFlagOpenReparsePoint = 0x00200000',
            'SourceFingerprintPathGuard]::Open',
            '0x20000000',
            '$heldPathGuards.Add',
            '$heldPathGuards[$index].Dispose()'
        )) {
        if (-not $fingerprintSource.Contains($requiredFragment, [StringComparison]::Ordinal)) {
            throw "$($implementation.Name) enthaelt die erforderliche native Link-/TOCTOU-Sicherung nicht: $requiredFragment"
        }
    }
    if ($fingerprintSource.Contains('FileShareDelete', [StringComparison]::Ordinal)) {
        throw "$($implementation.Name) erlaubt waehrend der Fingerprint-Pruefung weiterhin Pfadaustausch per Delete-Sharing."
    }
}

$reparseVerificationRoot = New-ReleaseVerificationRoot
try {
    foreach ($implementation in $fingerprintImplementations) {
        Invoke-Expression $implementation.Definition.Extent.Text
        $checkoutFingerprint = Get-SourceFingerprint -ResolvedSource $releaseScriptPath
        if ($checkoutFingerprint -notmatch '^[0-9A-F]{64}$') {
            throw "$($implementation.Name) blockiert den realen Checkout ohne symbolischen Link oder Junction."
        }
        $checkoutNativeInformation = Get-TestNativePathInformation -Path $releaseScriptPath
        if (($checkoutNativeInformation.FileAttributes -band [uint32]0x00000400) -ne 0 -and
            ($checkoutNativeInformation.ReparseTag -eq 0 -or
                ($checkoutNativeInformation.ReparseTag -band [uint32]0x20000000) -ne 0)) {
            throw "$($implementation.Name) klassifiziert den realen OneDrive-Cloud-Pfad faelschlich als Pfadumleitung."
        }
        $implementationRoot = New-ReleaseVerificationStage `
            -VerificationRoot $reparseVerificationRoot `
            -Name "fingerprint-$($implementation.Name)"
        $sourceDirectory = Join-Path $implementationRoot 'source'
        $nestedDirectory = Join-Path $sourceDirectory 'nested'
        $outsideDirectory = Join-Path $implementationRoot 'outside'
        [void](New-Item -ItemType Directory -Path $nestedDirectory, $outsideDirectory)
        $normalFile = Join-Path $nestedDirectory 'normal.txt'
        $outsideFile = Join-Path $outsideDirectory 'outside.txt'
        [IO.File]::WriteAllText($normalFile, 'normaler Inhalt')
        [IO.File]::WriteAllText($outsideFile, 'ausserhalb des attestierten Roots')

        $normalFileFingerprint = Get-SourceFingerprint -ResolvedSource $normalFile
        $normalDirectoryFingerprint = Get-SourceFingerprint -ResolvedSource $sourceDirectory
        if ($normalFileFingerprint -notmatch '^[0-9A-F]{64}$' -or
            $normalDirectoryFingerprint -notmatch '^[0-9A-F]{64}$') {
            throw "$($implementation.Name) erzeugt fuer normale Pfade keinen gueltigen SHA-256-Fingerprint."
        }
        Assert-TestNativeGuardBlocksReplacement `
            -Path $normalFile -Kind File -Implementation $implementation.Name
        Assert-TestNativeGuardBlocksReplacement `
            -Path $nestedDirectory -Kind Directory -Implementation $implementation.Name

        $junctionPath = Join-Path $sourceDirectory 'directory-junction'
        $junctionCanary = $null
        try {
            $junctionCanary = [IO.File]::Open(
                $outsideFile,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            [void](New-Item -ItemType Junction -Path $junctionPath -Target $outsideDirectory -ErrorAction Stop)
            $junctionNativeInformation = Get-TestNativePathInformation -Path $junctionPath
            if (($junctionNativeInformation.ReparseTag -band [uint32]0x20000000) -eq 0) {
                throw "$($implementation.Name) erkennt das Name-Surrogate-Bit der Test-Junction nativ nicht."
            }
            Assert-SourceFingerprintBlocksPathRedirection `
                -Path $junctionPath -Implementation $implementation.Name `
                -Scenario 'eine Junction als attestierten Root'
            Assert-SourceFingerprintBlocksPathRedirection `
                -Path (Join-Path $junctionPath 'outside.txt') `
                -Implementation $implementation.Name `
                -Scenario 'einen attestierten Dateipfad unterhalb einer Junction'
            Assert-SourceFingerprintBlocksPathRedirection `
                -Path $sourceDirectory -Implementation $implementation.Name `
                -Scenario 'eine Junction innerhalb des attestierten Roots'
        }
        finally {
            Remove-TestPathRedirection -Path $junctionPath -Kind Directory
            if ($null -ne $junctionCanary) {
                $junctionCanary.Dispose()
            }
        }

        $fileLinkPath = Join-Path $sourceDirectory 'file-link.txt'
        $fileLinkCreated = $false
        $fileLinkCanary = $null
        try {
            $fileLinkCanary = [IO.File]::Open(
                $outsideFile,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            try {
                [void](New-Item -ItemType SymbolicLink -Path $fileLinkPath -Target $outsideFile -ErrorAction Stop)
                $fileLinkCreated = $true
            }
            catch {
                $exceptionCursor = $_.Exception
                $nativeErrorCode = $null
                $platformUnsupported = $false
                while ($null -ne $exceptionCursor) {
                    if ($exceptionCursor -is [ComponentModel.Win32Exception]) {
                        $nativeErrorCode = $exceptionCursor.NativeErrorCode
                    }
                    if ($exceptionCursor -is [PlatformNotSupportedException]) {
                        $platformUnsupported = $true
                    }
                    $exceptionCursor = $exceptionCursor.InnerException
                }
                $unsupportedFileSymlink =
                    $_.FullyQualifiedErrorId -eq 'NewItemSymbolicLinkElevationRequired,Microsoft.PowerShell.Commands.NewItemCommand' -or
                    $nativeErrorCode -eq 1314 -or
                    $platformUnsupported
                if (-not $unsupportedFileSymlink) {
                    throw
                }
                Write-Warning "SKIP Datei-Symlink ($($implementation.Name)): Erstellung ist auf diesem Windows-Host nicht berechtigt oder unterstuetzt ($($_.FullyQualifiedErrorId))."
            }
            if ($fileLinkCreated) {
                $fileLinkNativeInformation = Get-TestNativePathInformation -Path $fileLinkPath
                if (($fileLinkNativeInformation.ReparseTag -band [uint32]0x20000000) -eq 0) {
                    throw "$($implementation.Name) erkennt das Name-Surrogate-Bit des Datei-Symlinks nativ nicht."
                }
                Assert-SourceFingerprintBlocksPathRedirection `
                    -Path $fileLinkPath -Implementation $implementation.Name `
                    -Scenario 'einen Datei-Symlink als attestierten Pfad'
                Assert-SourceFingerprintBlocksPathRedirection `
                    -Path $sourceDirectory -Implementation $implementation.Name `
                    -Scenario 'einen Datei-Symlink innerhalb des attestierten Roots'
            }
        }
        finally {
            Remove-TestPathRedirection -Path $fileLinkPath -Kind File
            if ($null -ne $fileLinkCanary) {
                $fileLinkCanary.Dispose()
            }
        }

        if ([IO.File]::ReadAllText($outsideFile) -cne 'ausserhalb des attestierten Roots') {
            throw "$($implementation.Name) hat trotz Link-Blockade das externe Testziel veraendert."
        }
    }
}
finally {
    Remove-ReleaseVerificationRoot -VerificationRoot $reparseVerificationRoot
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    if ($script:testMode -eq 'tag') {
        if ($FilePath -eq 'git') {
            return "$script:testTagObject`trefs/tags/v1.2.3`n$script:testPeeledCommit`trefs/tags/v1.2.3^{}"
        }
        return $script:testPeeledCommit
    }
    if ($script:testMode -eq 'release-repository') {
        if ($Arguments[0] -eq 'repo') {
            if ($Arguments[2] -ne 'github.com/owner/repository') {
                throw 'Release-Repository wurde nicht explizit an github.com gebunden.'
            }
            return '{"nameWithOwner":"owner/repository","defaultBranchRef":{"name":"main"}}'
        }
        if ($Arguments -contains 'repos/owner/repository/immutable-releases') {
            return $script:testImmutableReleases
        }
        return $script:testPeeledCommit
    }

    switch ($Arguments[2]) {
        'branch' { return 'main' }
        'remote' { return 'https://github.com/einzigTimo/projectatlas-desktop.git' }
        'rev-parse' {
            switch ($Arguments[3]) {
                'HEAD' { return $script:testCommit }
                'origin/main' {
                    if (-not $script:testFetchedRemoteMain) {
                        throw 'origin/main wurde ohne expliziten Fetch-Ref aufgeloest.'
                    }
                    return $script:testCommit
                }
                default { throw "Unerwartetes rev-parse-Ziel: $($Arguments[3])" }
            }
        }
        'status' { return '' }
        default { throw "Unerwarteter Git-Stub-Aufruf: $($Arguments -join ' ')" }
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)

    if ($script:testMode -ne 'binding' -or $FilePath -ne 'git') {
        return
    }
    if ($Arguments[2] -ne 'fetch' -or
        $Arguments[3] -ne '--prune' -or
        $Arguments[4] -ne 'origin' -or
        $Arguments[5] -ne 'main:refs/remotes/origin/main') {
        throw "main wurde nicht explizit in refs/remotes/origin/main gefetcht: $($Arguments -join ' ')"
    }
    $script:testFetchedRemoteMain = $true
}

function Get-SourceFingerprint {
    param([string]$ResolvedSource)
    return 'test-source-tree'
}

$artifactPath = Join-Path $repositoryRoot '.github\scripts\Assert-ControllerPreflight.ps1'
$artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
$bindingArguments = @{
    RepositoryRoot          = $repositoryRoot
    ExpectedCommit         = $script:testCommit
    ExpectedArtifactPath   = $artifactPath
    ExpectedArtifactSha256 = $artifactHash
    SourcePath             = '.github/scripts/Assert-ControllerPreflight.ps1'
    ExpectedSourceTreeSha256 = 'test-source-tree'
    ExpectedCargoSha256    = $artifactHash
}
$expiredBlocked = $false
try {
    Assert-PublishBinding @bindingArguments `
        -ExpectedExpiresAtUtc ([DateTimeOffset]::UtcNow.AddSeconds(-1))
}
catch {
    $expiredBlocked = $_.Exception.Message -like '*abgelaufen*'
}
if (-not $expiredBlocked) {
    throw 'Eine abgelaufene Controller-Attestierung wurde nicht fail-closed blockiert.'
}
Assert-PublishBinding @bindingArguments `
    -ExpectedExpiresAtUtc ([DateTimeOffset]::UtcNow.AddMinutes(5))

$script:testMode = 'release-repository'
$repositoryBinding = Get-ReleaseRepositoryBinding `
    -GhPath 'gh-test' -ReleaseRepository 'owner/repository'
if ($repositoryBinding.TargetCommit -ne $script:testPeeledCommit) {
    throw 'Release-Repository wurde nicht an den erwarteten Default-Branch-Commit gebunden.'
}
$script:testImmutableReleases = 'false'
$mutableRepositoryBlocked = $false
try {
    Get-ReleaseRepositoryBinding `
        -GhPath 'gh-test' -ReleaseRepository 'owner/repository' | Out-Null
}
catch {
    $mutableRepositoryBlocked = $_.Exception.Message -like '*unveraenderliche Releases*'
}
if (-not $mutableRepositoryBlocked) {
    throw 'Ein Release-Repository ohne aktivierte unveraenderliche Releases wurde nicht blockiert.'
}

$script:testMode = 'tag'
$peeledCommit = Get-ReleaseTagCommit `
    -GhPath 'gh-test' -ReleaseRepository 'owner/repository' -ReleaseTag 'v1.2.3'
if ($peeledCommit -ne $script:testPeeledCommit) {
    throw 'Ein annotierter Release-Tag wurde nicht rekursiv bis zum Commit aufgeloest.'
}

$expectedAssets = @(
    [pscustomobject]@{ Name = 'setup.exe'; Length = 10; Sha256 = ('1' * 64) },
    [pscustomobject]@{ Name = 'setup.exe.sig'; Length = 2; Sha256 = ('2' * 64) }
)
$releaseState = [pscustomobject]@{
    databaseId     = 42
    tagName        = 'v1.2.3'
    targetCommitish = $script:testPeeledCommit
    isDraft        = $true
    publishedAt    = $null
    assets         = @(
        [pscustomobject]@{ name = 'setup.exe'; size = 10; digest = "sha256:$('1' * 64)" },
        [pscustomobject]@{ name = 'setup.exe.sig'; size = 2; digest = "sha256:$('2' * 64)" }
    )
}
Assert-GitHubReleaseState `
    -State $releaseState -ExpectedDatabaseId '42' -ExpectedTag 'v1.2.3' `
    -ExpectedTargetCommit $script:testPeeledCommit -ExpectedDraft $true `
    -ExpectedAssets $expectedAssets
$releaseState.assets[1].name = 'unexpected.bin'
$unexpectedAssetBlocked = $false
try {
    Assert-GitHubReleaseState `
        -State $releaseState -ExpectedDatabaseId '42' -ExpectedTag 'v1.2.3' `
        -ExpectedTargetCommit $script:testPeeledCommit -ExpectedDraft $true `
        -ExpectedAssets $expectedAssets
}
catch {
    $unexpectedAssetBlocked = $true
}
if (-not $unexpectedAssetBlocked) {
    throw 'Ein unerwartetes Release-Asset wurde nicht blockiert.'
}
$releaseState.assets[1].name = 'setup.exe.sig'
$releaseState.assets[0].PSObject.Properties.Remove('digest')
$missingDigestBlocked = $false
try {
    Assert-GitHubReleaseState `
        -State $releaseState -ExpectedDatabaseId '42' -ExpectedTag 'v1.2.3' `
        -ExpectedTargetCommit $script:testPeeledCommit -ExpectedDraft $true `
        -ExpectedAssets $expectedAssets
}
catch {
    $missingDigestBlocked = $true
}
if (-not $missingDigestBlocked) {
    throw 'Ein Release-Asset ohne GitHub-SHA-256-Digest wurde nicht blockiert.'
}
$releaseState.assets[0] | Add-Member -NotePropertyName digest -NotePropertyValue "sha256:$('1' * 64)"
$releaseState.isDraft = $false
$releaseState.publishedAt = [DateTimeOffset]::UtcNow.ToString('o')
$releaseState | Add-Member -NotePropertyName isImmutable -NotePropertyValue $false
$mutableReleaseBlocked = $false
try {
    Assert-GitHubReleaseState `
        -State $releaseState -ExpectedDatabaseId '42' -ExpectedTag 'v1.2.3' `
        -ExpectedTargetCommit $script:testPeeledCommit -ExpectedDraft $false `
        -ExpectedAssets $expectedAssets -RequireImmutable
}
catch {
    $mutableReleaseBlocked = $true
}
if (-not $mutableReleaseBlocked) {
    throw 'Ein veroeffentlichter, aber weiterhin veraenderbarer Release wurde nicht blockiert.'
}
$releaseState.isImmutable = $true
Assert-GitHubReleaseState `
    -State $releaseState -ExpectedDatabaseId '42' -ExpectedTag 'v1.2.3' `
    -ExpectedTargetCommit $script:testPeeledCommit -ExpectedDraft $false `
    -ExpectedAssets $expectedAssets -RequireImmutable

$verificationRoot = New-ReleaseVerificationRoot
try {
    $localStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'local'
    $installerPath = Join-Path $localStage 'ProjectAtlas Desktop_1.2.3_x64-setup.exe'
    $signaturePath = Join-Path $localStage 'ProjectAtlas Desktop_1.2.3_x64-setup.exe.sig'
    [byte[]]$installerBytes = 1, 2, 3, 4, 5
    [byte[]]$signatureBytes = 7, 8, 9
    [IO.File]::WriteAllBytes($installerPath, $installerBytes)
    [IO.File]::WriteAllBytes($signaturePath, $signatureBytes)

    $frozenAssets = @(New-FrozenAssetInventory -Paths @($installerPath, $signaturePath))
    if ($frozenAssets.Count -ne 2 -or
        @($frozenAssets | Where-Object { $_.Name -match ' ' }).Count -ne 0) {
        throw 'Lokale Release-Assets wurden nicht eindeutig mit sicheren Remote-Namen eingefroren.'
    }

    $uploadStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'upload'
    $uploadCopies = @(Copy-FrozenAssetsForUpload `
            -FrozenAssets $frozenAssets -DestinationDirectory $uploadStage)
    if ($uploadCopies.Count -ne 2) {
        throw 'Das Upload-Staging enthaelt nicht exakt die eingefrorenen Assets.'
    }

    $dirtyUploadStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'upload-dirty'
    [IO.File]::WriteAllText((Join-Path $dirtyUploadStage 'vorhanden.txt'), 'nicht ueberschreiben')
    $overwriteBlocked = $false
    try {
        Copy-FrozenAssetsForUpload `
            -FrozenAssets $frozenAssets -DestinationDirectory $dirtyUploadStage | Out-Null
    }
    catch {
        $overwriteBlocked = $_.Exception.Message -like '*nicht leer*'
    }
    if (-not $overwriteBlocked) {
        throw 'Ein nicht leeres Upload-Staging wurde nicht fail-closed blockiert.'
    }

    [IO.File]::WriteAllBytes($installerPath, [byte[]](5, 4, 3, 2, 1))
    $changedUploadStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'upload-changed'
    $localSwapBlocked = $false
    try {
        Copy-FrozenAssetsForUpload `
            -FrozenAssets $frozenAssets -DestinationDirectory $changedUploadStage | Out-Null
    }
    catch {
        $localSwapBlocked = $_.Exception.Message -like '*nach der lokalen Kryptopruefung veraendert*'
    }
    if (-not $localSwapBlocked) {
        throw 'Ein lokaler Asset-Austausch nach dem Hash-Freeze wurde nicht blockiert.'
    }
    [IO.File]::WriteAllBytes($installerPath, $installerBytes)

    $remoteValidStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'remote-valid'
    foreach ($asset in $frozenAssets) {
        Copy-Item -LiteralPath $asset.SourcePath -Destination (Join-Path $remoteValidStage $asset.Name)
    }
    $remoteVerified = @(Assert-DownloadedReleaseAssets `
            -DownloadDirectory $remoteValidStage -ExpectedAssets $frozenAssets)
    if ($remoteVerified.Count -ne 2 -or
        @($remoteVerified | Where-Object { -not $_.RemoteVerified }).Count -ne 0) {
        throw 'Exakte Remote-Bytes wurden nicht als remote-verifiziert markiert.'
    }

    $remoteChangedStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'remote-changed'
    foreach ($asset in $frozenAssets) {
        Copy-Item -LiteralPath $asset.SourcePath -Destination (Join-Path $remoteChangedStage $asset.Name)
    }
    [IO.File]::WriteAllBytes(
        (Join-Path $remoteChangedStage $frozenAssets[0].Name),
        [byte[]](9, 9, 9, 9, 9)
    )
    $remoteHashBlocked = $false
    try {
        Assert-DownloadedReleaseAssets `
            -DownloadDirectory $remoteChangedStage -ExpectedAssets $frozenAssets | Out-Null
    }
    catch {
        $remoteHashBlocked = $_.Exception.Message -like '*weichen vom lokal eingefrorenen SHA-256 ab*'
    }
    if (-not $remoteHashBlocked) {
        throw 'Eine Remote-Hashabweichung wurde nicht fail-closed blockiert.'
    }

    $remoteMissingStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'remote-missing'
    Copy-Item -LiteralPath $frozenAssets[0].SourcePath -Destination (
        Join-Path $remoteMissingStage $frozenAssets[0].Name
    )
    $remoteMissingBlocked = $false
    try {
        Assert-DownloadedReleaseAssets `
            -DownloadDirectory $remoteMissingStage -ExpectedAssets $frozenAssets | Out-Null
    }
    catch {
        $remoteMissingBlocked = $_.Exception.Message -like '*nicht exakt das erwartete*'
    }
    if (-not $remoteMissingBlocked) {
        throw 'Ein fehlendes Remote-Asset wurde nicht fail-closed blockiert.'
    }

    $remoteExtraStage = New-ReleaseVerificationStage -VerificationRoot $verificationRoot -Name 'remote-extra'
    foreach ($asset in $frozenAssets) {
        Copy-Item -LiteralPath $asset.SourcePath -Destination (Join-Path $remoteExtraStage $asset.Name)
    }
    [IO.File]::WriteAllText((Join-Path $remoteExtraStage 'unexpected.bin'), 'extra')
    $remoteExtraBlocked = $false
    try {
        Assert-DownloadedReleaseAssets `
            -DownloadDirectory $remoteExtraStage -ExpectedAssets $frozenAssets | Out-Null
    }
    catch {
        $remoteExtraBlocked = $_.Exception.Message -like '*nicht exakt das erwartete*'
    }
    if (-not $remoteExtraBlocked) {
        throw 'Ein zusaetzliches Remote-Asset wurde nicht fail-closed blockiert.'
    }

    $manifestPath = Join-Path $localStage 'latest.json'
    [IO.File]::WriteAllText($manifestPath, '{"version":"1.2.3"}')
    $frozenManifest = @(New-FrozenAssetInventory -Paths @($manifestPath))
    $provenanceSourceStage = New-ReleaseVerificationStage `
        -VerificationRoot $verificationRoot -Name 'remote-provenance-source'
    $expectedForProvenance = @($frozenAssets) + @($frozenManifest)
    foreach ($asset in $expectedForProvenance) {
        Copy-Item -LiteralPath $asset.SourcePath -Destination (
            Join-Path $provenanceSourceStage $asset.Name
        )
    }
    $verifiedForProvenance = @(Assert-DownloadedReleaseAssets `
            -DownloadDirectory $provenanceSourceStage -ExpectedAssets $expectedForProvenance)
    $verifiedInstaller = Get-VerifiedAsset -Assets $verifiedForProvenance -Name $frozenAssets[0].Name
    $verifiedSignature = Get-VerifiedAsset -Assets $verifiedForProvenance -Name $frozenAssets[1].Name
    $verifiedManifest = Get-VerifiedAsset -Assets $verifiedForProvenance -Name 'latest.json'
    $provenancePath = Join-Path $localStage 'projectatlas-desktop-v1.2.3.provenance.json'
    New-ReleaseProvenance `
        -Destination $provenancePath -Version '1.2.3' -ReleaseTag 'v1.2.3' `
        -SourceCommit ('a' * 40) -ReleaseRepositoryCommit ('b' * 40) `
        -InstallerAsset $verifiedInstaller -SignatureAsset $verifiedSignature `
        -LatestManifestAsset $verifiedManifest `
        -AuthenticodeCertificateThumbprint ('C' * 40)
    $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
    if ([string]$provenance.installer.sha256 -ne [string]$verifiedInstaller.Sha256 -or
        [string]$provenance.signature.sha256 -ne [string]$verifiedSignature.Sha256 -or
        [string]$provenance.latest_manifest.sha256 -ne [string]$verifiedManifest.Sha256 -or
        (Get-Content -LiteralPath $provenancePath -Raw).Contains($verificationRoot)) {
        throw 'Provenienz wurde nicht ausschliesslich aus remote-verifizierten Namen und Hashes erzeugt.'
    }
}
finally {
    Remove-ReleaseVerificationRoot -VerificationRoot $verificationRoot
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/')
$tempRoot = Join-Path $tempBase "projectatlas-release-gate-$([Guid]::NewGuid().ToString('N'))"
try {
    $targetDir = Join-Path $tempRoot 'target\release'
    $desktopRoot = Join-Path $tempRoot 'desktop'
    [void](New-Item -ItemType Directory -Path $targetDir, $desktopRoot -Force)
    [IO.File]::WriteAllBytes((Join-Path $targetDir 'projectatlas.exe'), [byte[]](1, 2, 3))
    $sidecarBinaryName = 'projectatlas-cli-x86_64-pc-windows-msvc.exe'
    function Write-Step { param([string]$Message) }
    function Invoke-Native {
        param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
        'simulierte Cargo-Ausgabe 1'
        'simulierte Cargo-Ausgabe 2'
    }
    $sidecarResult = @(Build-Sidecar `
            -RepositoryRoot $tempRoot -CargoPath 'cargo-test' -DesktopCrateRoot $desktopRoot)
    if ($sidecarResult.Count -ne 1 -or $sidecarResult[0] -isnot [string] -or
        -not (Test-Path -LiteralPath $sidecarResult[0] -PathType Leaf)) {
        throw 'Build-Sidecar gibt neben dem eindeutigen Zielpfad weitere Pipeline-Ausgabe zurueck.'
    }
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $expectedPrefix = $tempBase + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTempRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedTempRoot) -notlike 'projectatlas-release-gate-*') {
        throw "Unsicheres temporaeres Cleanup-Ziel: $resolvedTempRoot"
    }
    if (Test-Path -LiteralPath $resolvedTempRoot) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# Zweiphasiger Release: Draft-State, Promotion, Sandbox-Ergebnis und Hilfsbausteine
# ---------------------------------------------------------------------------
function Copy-GateObject {
    param([Parameter(Mandatory = $true)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12 -DateKind String)
}

function Assert-GateProblem {
    param(
        [AllowEmptyCollection()][string[]]$Problems,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Scenario
    )
    if (@($Problems | Where-Object { $_ -like "*$Expected*" }).Count -eq 0) {
        throw "$Scenario wurde nicht fail-closed abgewiesen. Gemeldet: $($Problems -join '; ')"
    }
}

function Assert-GateNoProblem {
    param([AllowEmptyCollection()][string[]]$Problems, [string]$Scenario)
    if (@($Problems).Count -ne 0) {
        throw "$Scenario wurde faelschlich abgewiesen: $($Problems -join '; ')"
    }
}

$gateNow = [DateTimeOffset]::UtcNow
$gateRunId = 'd' * 32
$gateDraftStateSha = 'e' * 64
$gateInstallerName = 'ProjectAtlas.Desktop_1.2.3_x64-setup.exe'
$gateDraftState = Copy-GateObject ([ordered]@{
        schema_version                      = 'projectatlas.desktop.release-draft-state.v1'
        run_id                              = $gateRunId
        created_at_utc                      = $gateNow.AddMinutes(-20).ToString('o')
        preflight_verified_at_utc           = $gateNow.AddMinutes(-30).ToString('o')
        run_deadline_utc                    = $gateNow.AddMinutes(150).ToString('o')
        expires_at_utc                      = $gateNow.AddMinutes(100).ToString('o')
        version                             = '1.2.3'
        release_tag                         = 'v1.2.3'
        release_repository                  = 'einzigTimo/projectatlas-desktop-releases'
        release_id                          = '4242'
        release_repository_commit           = 'b' * 40
        source_repository                   = 'einzigTimo/projectatlas-desktop'
        source_commit                       = 'a' * 40
        source_path                         = 'crates/projectatlas-desktop/Cargo.toml'
        source_tree_sha256                  = '3' * 64
        cargo_sha256                        = '4' * 64
        tauri_config_sha256                 = '5' * 64
        preflight_artifact_path             = 'C:\nicht-verwendet\preflight.json'
        preflight_artifact_sha256           = '6' * 64
        authenticode_certificate_thumbprint = 'A' * 40
        updater_installer_name              = $gateInstallerName
        updater_signature_name              = "$gateInstallerName.sig"
        signature_verifier_path             = 'C:\nicht-verwendet\verify_updater_signature.exe'
        signature_verifier_sha256           = '7' * 64
        assets                              = @(
            [ordered]@{ name = $gateInstallerName; size = 10; sha256 = '1' * 64; asset_id = '101'; require_authenticode = $true },
            [ordered]@{ name = "$gateInstallerName.sig"; size = 2; sha256 = '2' * 64; asset_id = '102'; require_authenticode = $false },
            [ordered]@{ name = 'latest.json'; size = 3; sha256 = '8' * 64; asset_id = '103'; require_authenticode = $false },
            [ordered]@{ name = 'projectatlas-desktop-v1.2.3.provenance.json'; size = 4; sha256 = '9' * 64; asset_id = '104'; require_authenticode = $false }
        )
    })
$gateAttestation = Copy-GateObject ([ordered]@{
        schema_version                      = 'projectatlas.desktop.clean-windows-attestation.v1'
        result                              = 'pass'
        run_id                              = $gateRunId
        draft_state_sha256                  = $gateDraftStateSha
        release_id                          = '4242'
        release_tag                         = 'v1.2.3'
        release_repository                  = 'einzigTimo/projectatlas-desktop-releases'
        release_repository_commit           = 'b' * 40
        source_commit                       = 'a' * 40
        version                             = '1.2.3'
        authenticode_certificate_thumbprint = 'A' * 40
        assets                              = @($gateDraftState.assets | ForEach-Object {
                [ordered]@{ name = $_.name; size = $_.size; sha256 = $_.sha256; asset_id = $_.asset_id }
            })
        attested_at_utc                     = $gateNow.AddMinutes(-5).ToString('o')
        expires_at_utc                      = $gateNow.AddMinutes(25).ToString('o')
    })

# Draft-State
Assert-GateNoProblem -Scenario 'Gueltiger Draft-State' -Problems @(
    Test-ReleaseDraftStateDocument -State $gateDraftState -RunId $gateRunId -NowUtc $gateNow)
$case = Copy-GateObject $gateDraftState
$case.expires_at_utc = $gateNow.AddMinutes(-1).ToString('o')
Assert-GateProblem -Expected 'Draft-State ist abgelaufen' -Scenario 'Abgelaufener Draft-State' -Problems @(
    Test-ReleaseDraftStateDocument -State $case -RunId $gateRunId -NowUtc $gateNow)
Assert-GateNoProblem -Scenario 'Promotion nach Ablauf des Attestierungsfensters' -Problems @(
    Test-ReleaseDraftStateDocument -State $case -RunId $gateRunId -NowUtc $gateNow -ForPromotion)
$case = Copy-GateObject $gateDraftState
$case.run_deadline_utc = $gateNow.AddMinutes(-1).ToString('o')
$case.expires_at_utc = $gateNow.AddMinutes(-2).ToString('o')
Assert-GateProblem -Expected 'Laufbindung ist abgelaufen' -Scenario 'Abgelaufene Laufbindung trotz Promotion' -Problems @(
    Test-ReleaseDraftStateDocument -State $case -RunId $gateRunId -NowUtc $gateNow -ForPromotion)
$case = Copy-GateObject $gateDraftState
$case.run_deadline_utc = $gateNow.AddMinutes(600).ToString('o')
Assert-GateProblem -Expected 'Gesamtbudget' -Scenario 'Ueberlange Laufbindung' -Problems @(
    Test-ReleaseDraftStateDocument -State $case -RunId $gateRunId -NowUtc $gateNow)
$case = Copy-GateObject $gateDraftState
$case.assets = @($case.assets | Where-Object { $_.name -ne 'latest.json' })
Assert-GateProblem -Expected 'Pflicht-Asset fehlt' -Scenario 'Draft-State ohne latest.json' -Problems @(
    Test-ReleaseDraftStateDocument -State $case -RunId $gateRunId -NowUtc $gateNow)
Assert-GateProblem -Expected 'anderen Release-Lauf' -Scenario 'Draft-State eines anderen Laufs' -Problems @(
    Test-ReleaseDraftStateDocument -State $gateDraftState -RunId ('0' * 32) -NowUtc $gateNow)

# Promotion
Assert-GateNoProblem -Scenario 'Gueltige Attestierung' -Problems @(
    Test-ReleasePromotionAuthorization -DraftState $gateDraftState -DraftStateSha256 $gateDraftStateSha `
        -Attestation $gateAttestation -RunId $gateRunId -NowUtc $gateNow)
Assert-GateProblem -Expected 'Attestierung fehlt' -Scenario 'Promotion ohne Attestierung' -Problems @(
    Test-ReleasePromotionAuthorization -DraftState $gateDraftState -DraftStateSha256 $gateDraftStateSha `
        -Attestation $null -RunId $gateRunId -NowUtc $gateNow)
$promotionCases = @(
    @{ Name = 'abgelaufene Attestierung'; Expected = 'Attestierung ist abgelaufen'; Mutate = { param($a) $a.attested_at_utc = $gateNow.AddMinutes(-19).ToString('o'); $a.expires_at_utc = $gateNow.AddMinutes(-1).ToString('o') } },
    @{ Name = 'ueberlange Attestierung'; Expected = 'zulaessige Frist'; Mutate = { param($a) $a.expires_at_utc = $gateNow.AddMinutes(90).ToString('o') } },
    @{ Name = 'falsche Draft-ID'; Expected = 'release_id'; Mutate = { param($a) $a.release_id = '4243' } },
    @{ Name = 'falscher Quell-Commit'; Expected = 'source_commit'; Mutate = { param($a) $a.source_commit = 'f' * 40 } },
    @{ Name = 'falscher Release-Repo-Commit'; Expected = 'release_repository_commit'; Mutate = { param($a) $a.release_repository_commit = 'f' * 40 } },
    @{ Name = 'falscher Asset-Hash'; Expected = 'Attestierte Assets'; Mutate = { param($a) $a.assets[0].sha256 = 'f' * 64 } },
    @{ Name = 'falsche Asset-ID'; Expected = 'Attestierte Assets'; Mutate = { param($a) $a.assets[1].asset_id = '999' } },
    @{ Name = 'falscher Thumbprint'; Expected = 'authenticode_certificate_thumbprint'; Mutate = { param($a) $a.authenticode_certificate_thumbprint = 'B' * 40 } },
    @{ Name = 'falscher Draft-State-Hash'; Expected = 'Hash'; Mutate = { param($a) $a.draft_state_sha256 = 'f' * 64 } },
    @{ Name = 'roter Befund'; Expected = 'nicht gruen'; Mutate = { param($a) $a.result = 'fail' } },
    @{ Name = 'fremder Lauf'; Expected = 'anderen Release-Lauf'; Mutate = { param($a) $a.run_id = '0' * 32 } },
    @{ Name = 'fremdes Schema'; Expected = 'Attestierungsschema'; Mutate = { param($a) $a.schema_version = 'projectatlas.desktop.clean-windows-attestation.v0' } }
)
foreach ($promotionCase in $promotionCases) {
    $case = Copy-GateObject $gateAttestation
    & $promotionCase.Mutate $case
    Assert-GateProblem -Expected $promotionCase.Expected -Scenario "Promotion mit $($promotionCase.Name)" -Problems @(
        Test-ReleasePromotionAuthorization -DraftState $gateDraftState -DraftStateSha256 $gateDraftStateSha `
            -Attestation $case -RunId $gateRunId -NowUtc $gateNow)
}
$lateDraft = Copy-GateObject $gateDraftState
$lateDraft.expires_at_utc = $gateNow.AddMinutes(-6).ToString('o')
Assert-GateProblem -Expected 'Draft-State-Frist' -Scenario 'Attestierung nach Draft-State-Ablauf' -Problems @(
    Test-ReleasePromotionAuthorization -DraftState $lateDraft -DraftStateSha256 $gateDraftStateSha `
        -Attestation $gateAttestation -RunId $gateRunId -NowUtc $gateNow)
Assert-GateProblem -Expected 'Attestierung ist nicht an diesen Draft-State gebunden' -Scenario 'Anderer gebundener Draft-State-Hash' -Problems @(
    Test-ReleasePromotionAuthorization -DraftState $gateDraftState -DraftStateSha256 ('c' * 64) `
        -Attestation $gateAttestation -RunId $gateRunId -NowUtc $gateNow)
$problemGateBlocked = $false
try {
    Assert-ReleasePhaseProblemsEmpty -Context 'Test' -Problems @('Beispielproblem')
}
catch {
    $problemGateBlocked = $_.Exception.Message -like 'Produktiver Release blockiert*Beispielproblem*'
}
if (-not $problemGateBlocked) {
    throw 'Assert-ReleasePhaseProblemsEmpty blockiert gemeldete Probleme nicht.'
}

# Sandbox-Ergebnis
$gateExpectation = [pscustomobject]@{
    nonce                               = 'f' * 64
    version                             = '1.2.3'
    installer_name                      = $gateInstallerName
    installer_sha256                    = '1' * 64
    authenticode_certificate_thumbprint = 'A' * 40
}
$gateBinary = [ordered]@{ signature_status = 'Valid'; signer_thumbprint = 'A' * 40; timestamp_present = $true; product_version = '1.2.3' }
$gateSandboxResult = Copy-GateObject ([ordered]@{
        schema_version           = 'projectatlas.desktop.sandbox-result.v1'
        nonce                    = 'f' * 64
        completed                = $true
        fatal_error              = $null
        installer                = [ordered]@{ name = $gateInstallerName; sha256 = '1' * 64; signature_status = 'Valid'; signer_thumbprint = 'A' * 40; timestamp_present = $true; product_version = '1.2.3' }
        installer_exit_code      = 0
        webview2_before_install  = [ordered]@{ present = $true; version = '130.0.0.0' }
        webview2                 = [ordered]@{ present = $true; version = '130.0.0.0' }
        registry_display_version = '1.2.3'
        main_executable          = $gateBinary
        sidecar                  = [ordered]@{ signature_status = 'Valid'; signer_thumbprint = 'A' * 40; timestamp_present = $true; product_version = '0.0.0' }
        first_run                = [ordered]@{ passed = $true; detail = 'ok' }
        gui                      = [ordered]@{ main_window = $true; responding = $true; title = 'ProjectAtlas Desktop' }
    })
Assert-GateNoProblem -Scenario 'Gueltiges Sandbox-Ergebnis' -Problems @(
    Test-SandboxAttestationResult -Result $gateSandboxResult -Expectation $gateExpectation)
Assert-GateProblem -Expected 'Sandbox-Ergebnis fehlt' -Scenario 'Fehlendes Sandbox-Ergebnis' -Problems @(
    Test-SandboxAttestationResult -Result $null -Expectation $gateExpectation)
$sandboxCases = @(
    @{ Name = 'Haupt-EXE nicht Valid'; Expected = 'Installierte Haupt-EXE: Authenticode-Status ist nicht Valid'; Mutate = { param($r) $r.main_executable.signature_status = 'NotSigned' } },
    @{ Name = 'Sidecar nicht Valid'; Expected = 'Installierter Sidecar: Authenticode-Status'; Mutate = { param($r) $r.sidecar.signature_status = 'HashMismatch' } },
    @{ Name = 'Installer nicht Valid'; Expected = 'Installer: Authenticode-Status'; Mutate = { param($r) $r.installer.signature_status = 'UnknownError' } },
    @{ Name = 'falscher Thumbprint Haupt-EXE'; Expected = 'Installierte Haupt-EXE: Herausgeber-Thumbprint'; Mutate = { param($r) $r.main_executable.signer_thumbprint = 'B' * 40 } },
    @{ Name = 'falscher Thumbprint Sidecar'; Expected = 'Installierter Sidecar: Herausgeber-Thumbprint'; Mutate = { param($r) $r.sidecar.signer_thumbprint = 'B' * 40 } },
    @{ Name = 'fehlender Zeitstempel'; Expected = 'Installierte Haupt-EXE: RFC-3161-Zeitstempel fehlt'; Mutate = { param($r) $r.main_executable.timestamp_present = $false } },
    @{ Name = 'fehlender Sidecar-Zeitstempel'; Expected = 'Installierter Sidecar: RFC-3161-Zeitstempel fehlt'; Mutate = { param($r) $r.sidecar.timestamp_present = $false } },
    @{ Name = 'falsche Version'; Expected = 'Programmversion weicht ab'; Mutate = { param($r) $r.main_executable.product_version = '1.2.4' } },
    @{ Name = 'falsche Registry-Version'; Expected = 'Installationsregistrierung'; Mutate = { param($r) $r.registry_display_version = '1.2.2' } },
    @{ Name = 'fehlendes Hauptfenster'; Expected = 'Hauptfenster'; Mutate = { param($r) $r.gui.main_window = $false } },
    @{ Name = 'nicht antwortendes Fenster'; Expected = 'Hauptfenster'; Mutate = { param($r) $r.gui.responding = $false } },
    @{ Name = 'fehlende WebView2'; Expected = 'WebView2'; Mutate = { param($r) $r.webview2.present = $false } },
    @{ Name = 'roter Ersteinrichtungs-Smoke'; Expected = 'Ersteinrichtungs-Smoke'; Mutate = { param($r) $r.first_run.passed = $false } },
    @{ Name = 'NSIS-Fehlercode'; Expected = 'Exitcode 0'; Mutate = { param($r) $r.installer_exit_code = 2 } },
    @{ Name = 'anderer Installer'; Expected = 'nicht exakt der attestierte Installer'; Mutate = { param($r) $r.installer.sha256 = '0' * 64 } },
    @{ Name = 'fremde Nonce'; Expected = 'Nonce'; Mutate = { param($r) $r.nonce = '0' * 64 } },
    @{ Name = 'Abbruch in der Sandbox'; Expected = 'Sandbox meldet Fehler'; Mutate = { param($r) $r.completed = $false; $r.fatal_error = 'Testabbruch' } },
    @{ Name = 'fremdes Ergebnisschema'; Expected = 'Sandbox-Ergebnisschema'; Mutate = { param($r) $r.schema_version = 'unbekannt' } }
)
foreach ($sandboxCase in $sandboxCases) {
    $case = Copy-GateObject $gateSandboxResult
    & $sandboxCase.Mutate $case
    Assert-GateProblem -Expected $sandboxCase.Expected -Scenario "Sandbox-Ergebnis mit $($sandboxCase.Name)" -Problems @(
        Test-SandboxAttestationResult -Result $case -Expectation $gateExpectation)
}
$case = Copy-GateObject $gateSandboxResult
$case.PSObject.Properties.Remove('main_executable')
Assert-GateProblem -Expected 'Installierte Haupt-EXE: kein Nachweis' -Scenario 'Sandbox-Ergebnis ohne Haupt-EXE' -Problems @(
    Test-SandboxAttestationResult -Result $case -Expectation $gateExpectation)

# GitHub-Asset-Identitaet, Download-Adresse und Release-Liste
$idState = [pscustomobject]@{
    databaseId = '4242'; tagName = 'v1.2.3'; targetCommitish = 'b' * 40; isDraft = $true; publishedAt = ''
    assets     = @([pscustomobject]@{ id = '101'; name = 'setup.exe'; size = 10; digest = "sha256:$('1' * 64)"; url = '' })
}
$idExpected = @([pscustomobject]@{ Name = 'setup.exe'; Length = 10; Sha256 = '1' * 64; AssetId = '101' })
Assert-GitHubReleaseState -State $idState -ExpectedDatabaseId '4242' -ExpectedTag 'v1.2.3' `
    -ExpectedTargetCommit ('b' * 40) -ExpectedDraft $true -ExpectedAssets $idExpected
$idState.assets[0].id = '999'
$assetIdBlocked = $false
try {
    Assert-GitHubReleaseState -State $idState -ExpectedDatabaseId '4242' -ExpectedTag 'v1.2.3' `
        -ExpectedTargetCommit ('b' * 40) -ExpectedDraft $true -ExpectedAssets $idExpected
}
catch {
    $assetIdBlocked = $_.Exception.Message -like '*gebundene GitHub-Asset-ID*'
}
if (-not $assetIdBlocked) {
    throw 'Ein ausgetauschtes Draft-Asset mit neuer Asset-ID wurde nicht blockiert.'
}
$apiState = ConvertFrom-GitHubReleaseApi -Json '{"id":4242,"tag_name":"v1.2.3","target_commitish":"bbbb","draft":true,"immutable":false,"published_at":null,"assets":[{"id":101,"name":"setup.exe","size":10,"digest":"sha256:abc","browser_download_url":"https://github.com/o/r/releases/download/untagged-1/setup.exe"}]}'
if ($apiState.databaseId -ne '4242' -or -not $apiState.isDraft -or $apiState.assets[0].id -ne '101' -or $apiState.assets[0].size -ne 10) {
    throw 'Die REST-Antwort eines Drafts wird nicht korrekt auf die Release-Bindung abgebildet.'
}
if ((Get-ReleaseDownloadUrl -ReleaseRepository 'einzigTimo/projectatlas-desktop-releases' -ReleaseTag 'v1.2.3' -AssetName $gateInstallerName) -cne
    "https://github.com/einzigTimo/projectatlas-desktop-releases/releases/download/v1.2.3/$gateInstallerName") {
    throw 'Die oeffentliche Installer-Adresse fuer latest.json wird nicht deterministisch gebildet.'
}
$badUrlBlocked = $false
try { [void](Get-ReleaseDownloadUrl -ReleaseRepository 'o/r' -ReleaseTag 'untagged-1' -AssetName 'setup.exe') }
catch { $badUrlBlocked = $true }
if (-not $badUrlBlocked) {
    throw 'Eine untagged-Draft-Adresse wurde als oeffentliche Manifest-Adresse akzeptiert.'
}
& {
    function Invoke-NativeCapture {
        param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
        return "11`tv1.2.3`ttrue`n12`tv1.2.2`tfalse`n13`tv1.2.3`tfalse"
    }
    $tagMatches = @(Get-GitHubReleaseIdsByTag -GhPath 'gh-test' -ReleaseRepository 'o/r' -ReleaseTag 'v1.2.3')
    if ($tagMatches.Count -ne 2 -or $tagMatches[0].Id -ne '11' -or -not $tagMatches[0].IsDraft -or $tagMatches[1].IsDraft) {
        throw 'Drafts und Releases desselben Tags werden nicht vollstaendig erkannt.'
    }
}

# Phasendokumente sind unveraenderlich und hashgebunden
$documentRoot = New-ReleaseVerificationRoot
try {
    $documentPath = Join-Path $documentRoot 'draft-state.json'
    $documentSha = Write-ReleasePhaseDocument -Path $documentPath -Document ([ordered]@{ run_id = $gateRunId })
    if ((Read-BoundReleasePhaseDocument -Path $documentPath -ExpectedSha256 $documentSha -Label 'Test').run_id -cne $gateRunId) {
        throw 'Ein hashgebundenes Phasendokument wird nicht gelesen.'
    }
    $overwriteDocumentBlocked = $false
    try { [void](Write-ReleasePhaseDocument -Path $documentPath -Document ([ordered]@{ run_id = 'x' })) }
    catch { $overwriteDocumentBlocked = $true }
    if (-not $overwriteDocumentBlocked) {
        throw 'Ein vorhandenes Phasendokument wurde ueberschrieben.'
    }
    [IO.File]::WriteAllText($documentPath, '{"run_id":"manipuliert"}')
    $tamperBlocked = $false
    try { [void](Read-BoundReleasePhaseDocument -Path $documentPath -ExpectedSha256 $documentSha -Label 'Test') }
    catch { $tamperBlocked = $_.Exception.Message -like '*veraendert oder ausgetauscht*' }
    if (-not $tamperBlocked) {
        throw 'Ein manipuliertes Phasendokument wurde akzeptiert.'
    }

    # Windows-Sandbox-Konfiguration: Eingabe read-only, nur Ergebnis schreibbar
    $wsbInput = Join-Path $documentRoot 'input'
    $wsbResult = Join-Path $documentRoot 'result'
    [xml]$wsb = New-CleanWindowsSandboxConfiguration -InputDirectory $wsbInput -ResultDirectory $wsbResult -Networking 'Enable'
    $folders = @($wsb.Configuration.MappedFolders.MappedFolder)
    if ($folders.Count -ne 2 -or
        $folders[0].HostFolder -cne $wsbInput -or $folders[0].ReadOnly -cne 'true' -or $folders[0].SandboxFolder -cne 'C:\AtlasAttestation\input' -or
        $folders[1].HostFolder -cne $wsbResult -or $folders[1].ReadOnly -cne 'false' -or $folders[1].SandboxFolder -cne 'C:\AtlasAttestation\result' -or
        $wsb.Configuration.ClipboardRedirection -cne 'Disable' -or $wsb.Configuration.Networking -cne 'Enable' -or
        -not ([string]$wsb.Configuration.LogonCommand.Command).Contains('C:\AtlasAttestation\input\sandbox-probe.ps1', [StringComparison]::Ordinal)) {
        throw 'Die Windows-Sandbox-Konfiguration mappt Eingabe/Ergebnis oder den LogonCommand nicht sicher.'
    }
    $relativeWsbBlocked = $false
    try { [void](New-CleanWindowsSandboxConfiguration -InputDirectory 'input' -ResultDirectory $wsbResult -Networking 'Disable') }
    catch { $relativeWsbBlocked = $true }
    if (-not $relativeWsbBlocked) {
        throw 'Ein relativer Sandbox-Hostordner wurde akzeptiert.'
    }
}
finally {
    Remove-ReleaseVerificationRoot -VerificationRoot $documentRoot
}

Write-Host 'ProjectAtlas-Desktop-Release-Gates: PASS' -ForegroundColor Green
exit 0
