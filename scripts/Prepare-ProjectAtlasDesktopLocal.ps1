#Requires -Version 7
# Letzte Vorpruefung der Zentrale: bauen, bevor das kurzlebige Preflight ausgestellt wird.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit)
$ErrorActionPreference = 'Stop'
$actualRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
if (-not $actualRoot.Equals([IO.Path]::GetFullPath($Root).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Paketbau-Skript und registrierter Quellroot stimmen nicht ueberein.'
}
. (Join-Path $PSScriptRoot '../.github/scripts/ProjectAtlasLocalPackage.ps1')
Assert-AtlasLocalBuildSource -Root $actualRoot -ExpectedCommit $ExpectedCommit
. (Join-Path $PSScriptRoot 'ProjectAtlasLocalInstall.ps1')
Assert-AtlasWebViewRuntime
$packageDirectory = Get-AtlasLocalPackageDirectory -Commit $ExpectedCommit
if (Test-Path -LiteralPath (Join-Path $packageDirectory 'candidate.json')) {
    # Ein vorhandener Kandidat wird nicht blind wiederverwendet oder ueberschrieben.
    [void](Assert-AtlasLocalPackage -Root $actualRoot -ExpectedCommit $ExpectedCommit -ExpectedThumbprint $env:PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT)
    Write-Host 'Vorhandenes exaktes lokales Paket erneut geprueft.'
    exit 0
}
& (Join-Path $PSScriptRoot '../.github/scripts/invoke-desktop-release.ps1') -PrepareLocalPackage -ExpectedCommit $ExpectedCommit
[void](Assert-AtlasLocalPackage -Root $actualRoot -ExpectedCommit $ExpectedCommit -ExpectedThumbprint $env:PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT)
