#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReleaseScript = (Join-Path $PSScriptRoot '..\.github\scripts\invoke-desktop-release.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseScriptPath = (Resolve-Path -LiteralPath $ReleaseScript).Path
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $releaseScriptPath) '..\..'))
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

foreach ($functionName in @(
        'Build-Sidecar',
        'ConvertTo-GitHubRepositorySlug',
        'Get-ReleaseRepositoryBinding',
        'Assert-PublishBinding',
        'Get-ReleaseTagCommit',
        'Assert-GitHubReleaseState')) {
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
$sourceRepository = 'einzigTimo/projectatlas-desktop'

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
        'rev-parse' { return $script:testCommit }
        'status' { return '' }
        default { throw "Unerwarteter Git-Stub-Aufruf: $($Arguments -join ' ')" }
    }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
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
