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

$promotionGuard = 'Produktiver Release blockiert: Die verpflichtende zweiphasige Clean-Windows-Attestierung'
$legacyPublishFlag = '$legacySingleInvocationPublishEnabled = $false'
$legacyPublishBinding = '$executeLegacySingleInvocationPublish = $Publish -and $legacySingleInvocationPublishEnabled'
$legacyPublishGuard = 'if ($Publish -and -not $executeLegacySingleInvocationPublish)'
$legacyImplementationGuard = 'if ($executeLegacySingleInvocationPublish)'
$legacyPublishFlagPosition = $releaseScriptText.IndexOf($legacyPublishFlag, [StringComparison]::Ordinal)
$legacyPublishBindingPosition = $releaseScriptText.IndexOf($legacyPublishBinding, [StringComparison]::Ordinal)
$legacyPublishGuardPosition = $releaseScriptText.IndexOf($legacyPublishGuard, [StringComparison]::Ordinal)
$legacyImplementationPosition = $releaseScriptText.IndexOf($legacyImplementationGuard, [StringComparison]::Ordinal)
$promotionGuardPosition = $releaseScriptText.IndexOf($promotionGuard, [StringComparison]::Ordinal)
$draftCreatePosition = $releaseScriptText.IndexOf("`$releaseArguments.Add('create')", [StringComparison]::Ordinal)
$draftPublishPosition = $releaseScriptText.IndexOf("'--verify-tag', '--draft=false'", [StringComparison]::Ordinal)
if ($legacyPublishFlagPosition -lt 0 -or
    $legacyPublishBindingPosition -le $legacyPublishFlagPosition -or
    $legacyPublishGuardPosition -le $legacyPublishBindingPosition -or
    $promotionGuardPosition -le $legacyPublishGuardPosition -or
    $legacyImplementationPosition -le $promotionGuardPosition -or
    $draftCreatePosition -lt 0 -or $draftPublishPosition -lt 0 -or
    $promotionGuardPosition -gt $draftCreatePosition -or $promotionGuardPosition -gt $draftPublishPosition) {
    throw 'Der gesperrte Einphasen-Publish-Pfad ist nicht explizit und vor jeder Draft-Erzeugung und -Promotion fail-closed gegated.'
}
$legacyImplementationText = $releaseScriptText.Substring($legacyImplementationPosition)
if ($legacyImplementationText -match '(?<![A-Za-z0-9_])\$Publish(?![A-Za-z0-9_])') {
    throw 'Der gesperrte Alt-Publish-Code darf nicht direkt vom externen -Publish-Schalter abhaengen.'
}

foreach ($functionName in @(
        'New-NativeProcessStartInfo',
        'Invoke-NativeCapture',
        'Invoke-TauriBundle',
        'Build-Sidecar',
        'ConvertTo-GitHubRepositorySlug',
        'Get-ReleaseRepositoryBinding',
        'Assert-PublishBinding',
        'Get-ReleaseTagCommit',
        'Assert-GitHubReleaseState',
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

Write-Host 'ProjectAtlas-Desktop-Release-Gates: PASS' -ForegroundColor Green
exit 0
