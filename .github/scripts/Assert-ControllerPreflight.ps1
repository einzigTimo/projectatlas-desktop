#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactPath,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [Parameter(Mandatory = $true)][string]$ComponentId,
    [string]$Environment = 'prod',
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetResourceGroup,
    [Parameter(Mandatory = $true)][string]$TargetAppName,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

function Get-SourceFingerprint([string]$ResolvedSource) {
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

$allowedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'deployment-controller\reports')).TrimEnd([char]'\', [char]'/')
if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
    throw "Preflight-Artefakt fehlt: $ArtifactPath"
}
$artifactFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ArtifactPath).Path)
if (-not $artifactFull.StartsWith($allowedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Preflight-Artefakt liegt nicht im Reportpfad der Develop Zentrale.'
}
if ((Get-Item -LiteralPath $artifactFull).Length -gt 1MB) {
    throw 'Preflight-Artefakt ist unerwartet gross.'
}

$artifactHashBefore = (Get-FileHash -LiteralPath $artifactFull -Algorithm SHA256).Hash
$artifact = Get-Content -LiteralPath $artifactFull -Raw | ConvertFrom-Json -Depth 20 -DateKind String
$artifactHashAfter = (Get-FileHash -LiteralPath $artifactFull -Algorithm SHA256).Hash
if ($artifactHashBefore -ne $artifactHashAfter) {
    throw 'Preflight-Artefakt wurde waehrend der Pruefung veraendert.'
}
if ($artifact.schema_version -ne 'studiohamburg.deploy-preflight.v1' -or
    $artifact.producer -ne 'Deployment-Controller' -or $artifact.result -ne 'pass') {
    throw 'Preflight-Artefakt hat ein unbekanntes Schema, einen falschen Producer oder kein grünes Ergebnis.'
}
if ($artifact.project_id -ne $ProjectId -or $artifact.component_id -ne $ComponentId -or
    $artifact.environment -ne $Environment -or $artifact.target_resource_group -ne $TargetResourceGroup -or
    $artifact.target_app_name -ne $TargetAppName) {
    throw 'Preflight-Artefakt gehoert nicht zu diesem Produktivziel.'
}

$rootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char]'\', [char]'/')
$artifactRoot = [IO.Path]::GetFullPath([string]$artifact.canonical_root).TrimEnd([char]'\', [char]'/')
if (-not $artifactRoot.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Preflight-Artefakt gehoert zu einem anderen Projektroot.'
}
if ([string]$artifact.source_path -ne $SourcePath.Replace('\', '/')) {
    throw 'Preflight-Artefakt gehoert zu einem anderen Quellpfad.'
}

$generated = [DateTimeOffset]::Parse([string]$artifact.generated_at_utc).ToUniversalTime()
$expires = [DateTimeOffset]::Parse([string]$artifact.expires_at_utc).ToUniversalTime()
$now = [DateTimeOffset]::UtcNow
if ($generated -gt $now.AddMinutes(2) -or $generated -lt $now.AddMinutes(-10) -or
    $expires -le $now -or $expires -gt $generated.AddMinutes(12)) {
    throw 'Preflight-Artefakt ist abgelaufen oder zeitlich unplausibel.'
}

$headOutput = @(& git -C $rootFull rev-parse HEAD 2>$null)
$headExitCode = $LASTEXITCODE
$head = ($headOutput | Out-String).Trim()
if ($headExitCode -ne 0 -or $artifact.expected_commit -ne $head) {
    throw 'Preflight-Artefakt gilt nicht fuer den aktuellen Git-Commit.'
}
$statusOutput = @(& git -C $rootFull status --porcelain 2>$null)
$statusExitCode = $LASTEXITCODE
if ($statusExitCode -ne 0) {
    throw 'Git-Status fuer den zentral geprueften Projektroot konnte nicht ermittelt werden.'
}
if ($statusOutput.Count -gt 0) {
    throw 'Arbeitsbaum wurde nach der zentralen Vorpruefung veraendert.'
}
if (@($artifact.checks).Count -eq 0 -or @($artifact.checks | Where-Object { -not $_.passed }).Count -gt 0) {
    throw 'Preflight-Artefakt enthaelt fehlgeschlagene oder keine Vorpruefungen.'
}

$resolvedSource = [IO.Path]::GetFullPath((Join-Path $rootFull $SourcePath))
if (-not $resolvedSource.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    (-not (Test-Path -LiteralPath $resolvedSource))) {
    throw 'Preflight-Quellpfad fehlt oder liegt ausserhalb des Projektroots.'
}
$fingerprint = Get-SourceFingerprint -ResolvedSource $resolvedSource
if ($fingerprint -ne [string]$artifact.source_tree_sha256) {
    throw 'Quellstand wurde nach der zentralen Vorpruefung veraendert.'
}

Write-Host "[OK] Develop-Zentrale-Preflight fuer $ProjectId/$ComponentId ist frisch und unveraendert." -ForegroundColor Green

if ($PassThru) {
    [pscustomobject]@{
        ArtifactPath     = $artifactFull
        ArtifactSha256   = $artifactHashAfter
        ExpectedCommit  = [string]$artifact.expected_commit
        SourcePath       = [string]$artifact.source_path
        SourceTreeSha256 = [string]$artifact.source_tree_sha256
    }
}
