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
    if ($null -eq ('ProjectAtlas.SourceFingerprintPathGuard' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ProjectAtlas
{
    public sealed class SourceFingerprintPathGuard : IDisposable
    {
        private SafeFileHandle handle;

        private SourceFingerprintPathGuard(SafeFileHandle handle, uint attributes, uint reparseTag)
        {
            this.handle = handle;
            FileAttributes = attributes;
            ReparseTag = reparseTag;
        }

        public uint FileAttributes { get; private set; }
        public uint ReparseTag { get; private set; }

        public void Dispose()
        {
            if (handle != null)
            {
                handle.Dispose();
                handle = null;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInfo
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int fileInformationClass,
            out FileAttributeTagInfo fileInformation,
            uint bufferSize);

        public static SourceFingerprintPathGuard Open(string path, bool isDirectory)
        {
            const uint GenericRead = 0x80000000;
            const uint FileShareRead = 0x00000001;
            const uint FileShareWrite = 0x00000002;
            const uint OpenExisting = 3;
            const uint FileFlagOpenReparsePoint = 0x00200000;
            const uint FileFlagBackupSemantics = 0x02000000;
            const int FileAttributeTagInfoClass = 9;
            uint shareMode = isDirectory ? FileShareRead | FileShareWrite : FileShareRead;

            SafeFileHandle handle = CreateFileW(
                path,
                GenericRead,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Pfad konnte nicht reparse-sicher geoeffnet werden.");
            }

            FileAttributeTagInfo information;
            if (!GetFileInformationByHandleEx(
                handle,
                FileAttributeTagInfoClass,
                out information,
                (uint)Marshal.SizeOf(typeof(FileAttributeTagInfo))))
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Reparse-Tag konnte nicht sicher gelesen werden.");
            }

            return new SourceFingerprintPathGuard(
                handle,
                information.FileAttributes,
                information.ReparseTag);
        }
    }
}
'@
    }

    $assertNoPathRedirection = {
        param([IO.FileSystemInfo]$Item)

        try {
            $pathGuard = [ProjectAtlas.SourceFingerprintPathGuard]::Open(
                $Item.FullName,
                $Item.PSIsContainer
            )
        }
        catch {
            throw 'Quell-Fingerprint blockiert: Ein symbolischer Link oder eine Junction konnte nativ nicht sicher ausgeschlossen werden.'
        }
        if ((($pathGuard.FileAttributes -band [uint32]0x00000400) -ne 0 -and
                $pathGuard.ReparseTag -eq 0) -or
            (($pathGuard.ReparseTag -band [uint32]0x20000000) -ne 0)) {
            $pathGuard.Dispose()
            throw 'Quell-Fingerprint blockiert: Der attestierte Pfad enthaelt einen symbolischen Link oder eine Junction.'
        }

        try {
            $resolvedLinkTarget = $Item.ResolveLinkTarget($false)
        }
        catch {
            $pathGuard.Dispose()
            throw 'Quell-Fingerprint blockiert: Ein symbolischer Link oder eine Junction konnte nicht sicher ausgeschlossen werden.'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Item.LinkType) -or
            -not [string]::IsNullOrWhiteSpace([string]$Item.LinkTarget) -or
            $null -ne $resolvedLinkTarget) {
            $pathGuard.Dispose()
            throw 'Quell-Fingerprint blockiert: Der attestierte Pfad enthaelt einen symbolischen Link oder eine Junction.'
        }
        return $pathGuard
    }

    $heldPathGuards = [Collections.Generic.List[IDisposable]]::new()
    $holdNoPathRedirection = {
        param([IO.FileSystemInfo]$Item)

        [void]$heldPathGuards.Add((& $assertNoPathRedirection $Item))
    }

    try {
    $sourceFullPath = [IO.Path]::GetFullPath($ResolvedSource)
    $pathRoot = [IO.Path]::GetPathRoot($sourceFullPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot) -or
        -not (Test-Path -LiteralPath $pathRoot)) {
        throw 'Quell-Fingerprint blockiert: Der Root des attestierten Pfads fehlt.'
    }
    $currentPath = $pathRoot
    $sourceItem = Get-Item -LiteralPath $currentPath -Force
    & $holdNoPathRedirection $sourceItem
    $relativeSourcePath = [IO.Path]::GetRelativePath($pathRoot, $sourceFullPath)
    if ($relativeSourcePath -ne '.') {
        $pathSegments = $relativeSourcePath.Split(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries
        )
        foreach ($pathSegment in $pathSegments) {
            $currentPath = [IO.Path]::GetFullPath((Join-Path $currentPath $pathSegment))
            if (-not (Test-Path -LiteralPath $currentPath)) {
                throw 'Quell-Fingerprint blockiert: Der attestierte Pfad fehlt.'
            }
            $sourceItem = Get-Item -LiteralPath $currentPath -Force
            & $holdNoPathRedirection $sourceItem
        }
    }

    $manifest = [Text.StringBuilder]::new()
    if (-not $sourceItem.PSIsContainer) {
        $hash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
        [void]$manifest.Append($sourceItem.Name).Append('|').Append($sourceItem.Length).Append('|').Append($hash).Append("`n")
    }
    else {
        $root = [IO.Path]::GetFullPath($sourceItem.FullName)
        $rootPrefix = if ($root.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $root
        }
        else {
            $root + [IO.Path]::DirectorySeparatorChar
        }
        $pendingDirectories = [Collections.Generic.Stack[string]]::new()
        $pendingDirectories.Push($root)
        $files = [Collections.Generic.List[object]]::new()

        while ($pendingDirectories.Count -gt 0) {
            $directoryPath = $pendingDirectories.Pop()
            $directoryItem = Get-Item -LiteralPath $directoryPath -Force
            & $holdNoPathRedirection $directoryItem
            $directoryFullPath = [IO.Path]::GetFullPath($directoryItem.FullName)
            if (-not $directoryFullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
                -not $directoryFullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Quell-Fingerprint blockiert: Verzeichnistraversierung verliess den attestierten Root.'
            }

            foreach ($entry in @(Get-ChildItem -LiteralPath $directoryFullPath -Force)) {
                $entryFullPath = [IO.Path]::GetFullPath($entry.FullName)
                if (-not $entryFullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Quell-Fingerprint blockiert: Ein Eintrag liegt ausserhalb des attestierten Roots.'
                }
                & $holdNoPathRedirection $entry
                if ($entry.PSIsContainer) {
                    $pendingDirectories.Push($entryFullPath)
                }
                else {
                    $files.Add([pscustomobject]@{
                            FullPath     = $entryFullPath
                            RelativePath = [IO.Path]::GetRelativePath($root, $entryFullPath).Replace('\', '/')
                        })
                }
            }
        }

        foreach ($file in @($files | Sort-Object -Property RelativePath -CaseSensitive)) {
            $item = Get-Item -LiteralPath $file.FullPath -Force
            & $holdNoPathRedirection $item
            if ($item.PSIsContainer) {
                throw 'Quell-Fingerprint blockiert: Ein Datei-Eintrag wurde waehrend der Pruefung zum Verzeichnis.'
            }
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
    finally {
        for ($index = $heldPathGuards.Count - 1; $index -ge 0; $index--) {
            $heldPathGuards[$index].Dispose()
        }
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
$authenticodeCertificateThumbprint = (
    [string]$artifact.authenticode_certificate_thumbprint -replace '\s', ''
).ToUpperInvariant()
if ($authenticodeCertificateThumbprint -notmatch '^[0-9A-F]{40}$') {
    throw 'Preflight-Artefakt enthaelt keinen freigegebenen Authenticode-Zertifikatsthumbprint.'
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
        ExpiresAtUtc     = $expires.ToString('o')
        AuthenticodeCertificateThumbprint = $authenticodeCertificateThumbprint
    }
}
