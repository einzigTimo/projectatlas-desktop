#Requires -Version 7
# Hilfsfunktionen fuer den reinen Paketbau. Installieren darf nur der Zentrale-Wrapper.
Set-StrictMode -Version Latest

function Invoke-AtlasLocalBuildGit {
    param([string]$Root, [string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($name in @('TAURI_SIGNING_PRIVATE_KEY', 'TAURI_SIGNING_PRIVATE_KEY_PATH', 'TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) {
        [void]$start.Environment.Remove($name)
    }
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in @('-C', $Root) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Git-Pruefung konnte nicht gestartet werden.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw 'Git-Pruefung hat das Zeitlimit ueberschritten.' }
        if ($process.ExitCode -ne 0) { throw 'Git-Pruefung fuer das lokale Paket ist fehlgeschlagen.' }
        return $stdout.GetAwaiter().GetResult().Trim()
    }
    finally { $process.Dispose() }
}

function Assert-AtlasLocalBuildSource {
    param([string]$Root, [string]$ExpectedCommit)
    if ($ExpectedCommit -notmatch '^[0-9a-f]{40}$') { throw 'Ungueltiger Paket-Quellcommit.' }
    $head = Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('rev-parse', 'HEAD')
    if ($head -cne $ExpectedCommit) {
        throw 'Der Paketbau ist nicht mehr an den erwarteten Quellcommit gebunden.'
    }
    $status = Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('status', '--porcelain', '--untracked-files=all')
    if ($status) { throw 'Paketbau verlangt einen sauberen Quellstand.' }
    $branch = Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('branch', '--show-current')
    if ($branch -cne 'main') { throw 'Das lokale Updatepaket muss aus main gebaut werden.' }
    $remote = Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('remote', 'get-url', 'origin')
    if ($remote -cnotmatch '^(https://github\.com/|git@github\.com:)einzigTimo/projectatlas-desktop(\.git)?$') {
        throw 'Paketbau verlangt das registrierte ProjectAtlas-Quellrepository.'
    }
    [void](Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('fetch', 'origin', 'main:refs/remotes/origin/main', '--no-tags'))
    $main = Invoke-AtlasLocalBuildGit -Root $Root -Arguments @('rev-parse', 'refs/remotes/origin/main')
    if ($main -cne $ExpectedCommit) { throw 'Paketbau verlangt den aktuellen origin/main-Commit.' }
}

function Write-AtlasLocalNewText {
    param([string]$Path, [string]$Text)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function New-AtlasLocalPackageBuild {
    param([string]$Root, [string]$ExpectedCommit)
    $packageParent = Join-Path $env:LOCALAPPDATA 'deployment-controller/projectatlas-local/packages'
    [void][IO.Directory]::CreateDirectory($packageParent)
    # Kein Weiterleiten in fremde Verzeichnisse. Der Benutzerpfad ist lokal, kein OneDrive-Quellpfad.
    $pathItem = Get-Item -LiteralPath $packageParent
    while ($null -ne $pathItem) {
        if ($pathItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lokaler Paketpfad darf keine Verknuepfungen enthalten.' }
        $pathItem = $pathItem.Parent
    }
    $finalPath = Join-Path $packageParent $ExpectedCommit
    if (Test-Path -LiteralPath $finalPath) { throw 'Fuer diesen Commit existiert bereits ein Paket. Vor erneutem Bau das vorhandene Paket pruefen.' }
    $staging = Join-Path $packageParent ($ExpectedCommit + '.building-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $staging -AclObject $acl
    $pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $capture = Join-Path $PSScriptRoot 'Capture-ProjectAtlasLocalPayload.ps1'
    $source = Join-Path $Root 'target/release/projectatlas-desktop.exe'
    $mainPath = Join-Path $staging 'projectatlas-desktop.exe'
    # NSIS hat eine eigene Praeprozessor-Syntax. Keine Pfade mit Metazeichen in !system.
    foreach ($value in @($pwsh, $capture, $source, $mainPath)) {
        if ($value -match '[\x00-\x1f"''`$!]') { throw 'Paketpfad enthaelt unzulaessige NSIS-Metazeichen.' }
    }
    $hook = '!system ''"{0}" -NoProfile -File "{1}" -SourcePath "{2}" -DestinationPath "{3}"'' = 0' -f $pwsh, $capture, $source, $mainPath
    $hookPath = Join-Path $packageParent ($ExpectedCommit + '.capture-' + [guid]::NewGuid().ToString('N') + '.nsh')
    Write-AtlasLocalNewText -Path $hookPath -Text ($hook + "`n")
    [pscustomobject]@{ Directory = $staging; FinalDirectory = $finalPath; HookPath = $hookPath; MainPath = $mainPath }
}

function Complete-AtlasLocalPackageBuild {
    param($Build, [string]$Root, [string]$ExpectedCommit, [string]$Version, [string]$Thumbprint,
        [string]$InstallerPath, [string]$SidecarPath, $SigningConfiguration)
    Assert-AtlasLocalBuildSource -Root $Root -ExpectedCommit $ExpectedCommit
    $sources = [ordered]@{
        'installer.exe' = $InstallerPath
        'installer.exe.sig' = $InstallerPath + '.sig'
        'projectatlas-cli.exe' = $SidecarPath
        'verify_updater_signature.exe' = Join-Path $Root 'target/release/examples/verify_updater_signature.exe'
    }
    foreach ($name in $sources.Keys) {
        [IO.File]::Copy($sources[$name], (Join-Path $Build.Directory $name), $false)
    }
    $verifier = Join-Path $Build.Directory 'verify_updater_signature.exe'
    Invoke-Native -FilePath $SigningConfiguration.SignToolPath -WorkingDirectory $Root -Arguments @(
        'sign', '/sha1', $Thumbprint, '/fd', 'sha256', '/tr', $SigningConfiguration.TimestampUrl, '/td', 'sha256', $verifier)
    $inventory = @(foreach ($name in @('installer.exe', 'installer.exe.sig', 'projectatlas-desktop.exe', 'projectatlas-cli.exe', 'verify_updater_signature.exe')) {
        $file = Get-Item -LiteralPath (Join-Path $Build.Directory $name)
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -le 0) {
            throw 'Das lokale Paket enthaelt eine ungueltige Datei.'
        }
        [ordered]@{ name = $name; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); length = $file.Length }
    })
    foreach ($name in @('installer.exe', 'projectatlas-desktop.exe', 'projectatlas-cli.exe', 'verify_updater_signature.exe')) {
        Assert-AuthenticodeArtifact -Role "Lokales Paket $name" -Path (Join-Path $Build.Directory $name) `
            -ExpectedThumbprint $Thumbprint -Required -LocalTrustOnly
    }
    Invoke-Native -FilePath $verifier -WorkingDirectory $Root -Arguments @(
        (Join-Path $Build.Directory 'installer.exe'), (Join-Path $Build.Directory 'installer.exe.sig'),
        (Join-Path $Root 'crates/projectatlas-desktop/tauri.conf.json'))
    $manifest = [ordered]@{
        schema = 'projectatlas.desktop.local-package.v1'; scope = 'local-windows'
        sourceRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/'); sourceCommit = $ExpectedCommit
        version = $Version; certificateThumbprint = $Thumbprint; createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        machineName = [Environment]::MachineName; userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        artifacts = $inventory
    }
    $manifestPath = Join-Path $Build.Directory 'candidate.json'
    Write-AtlasLocalNewText -Path $manifestPath -Text ($manifest | ConvertTo-Json -Depth 8)
    # Der Preflight attestiert den Herausgeber unabhaengig vom Paket. Dessen
    # detached CMS bindet diese exakten Manifestbytes (Quelle UND alle Payloadhashes).
    $content = [Security.Cryptography.Pkcs.ContentInfo]::new([IO.File]::ReadAllBytes($manifestPath))
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new($content, $true)
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$Thumbprint"
    $signer = [Security.Cryptography.Pkcs.CmsSigner]::new($certificate)
    $signer.DigestAlgorithm = [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
    $cms.ComputeSignature($signer, $true)
    $signatureStream = [IO.File]::Open(($manifestPath + '.p7s'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $signatureStream.Write($cms.Encode()); $signatureStream.Flush($true) }
    finally { $signatureStream.Dispose() }
    $verifiedCms = [Security.Cryptography.Pkcs.SignedCms]::new(
        [Security.Cryptography.Pkcs.ContentInfo]::new([IO.File]::ReadAllBytes($manifestPath)), $true)
    $verifiedCms.Decode([IO.File]::ReadAllBytes($manifestPath + '.p7s'))
    $verifiedCms.CheckSignature($false)
    if ($verifiedCms.SignerInfos.Count -ne 1 -or $verifiedCms.SignerInfos[0].Certificate.Thumbprint -ine $Thumbprint) {
        throw 'Die geschriebene CMS-Paketbindung konnte nicht bestaetigt werden.'
    }
    # Exakte, neu angelegte Staging- und Zielpfade unter dem vorher geprueften Paketordner.
    $parent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'deployment-controller/projectatlas-local/packages')).TrimEnd('\')
    foreach ($path in @($Build.Directory, $Build.FinalDirectory)) {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -ne $parent) { throw 'Paketabschluss ausserhalb des Paketordners blockiert.' }
    }
    [IO.Directory]::Move($Build.Directory, $Build.FinalDirectory)
    Write-Host "Lokales Paket: $($Build.FinalDirectory)"
}
