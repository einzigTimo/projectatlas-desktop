#Requires -Version 7.5
# Gemeinsame Funktionen fuer die ausschliesslich lokale, zentral beauftragte Installation.
Set-StrictMode -Version Latest

function Get-AtlasLocalStateDirectory { Join-Path $env:LOCALAPPDATA 'deployment-controller/projectatlas-local' }

function Get-AtlasLocalPackageDirectory {
    param([Parameter(Mandatory)][Alias('ExpectedCommit')][string]$Commit)
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Lokales Paket benoetigt einen exakten Quellcommit.' }
    Join-Path (Get-AtlasLocalStateDirectory) "packages/$Commit"
}

function Get-AtlasLocalInstallDirectory { Join-Path $env:LOCALAPPDATA 'ProjectAtlas Desktop' }
function Get-AtlasLocalRegistryPath { Join-Path $env:LOCALAPPDATA 'ProjectAtlasDesktop/registry.json' }
function Test-AtlasSamePath([string]$Actual, [string]$Expected) {
    if (-not [IO.Path]::IsPathFullyQualified($Actual)) { return $false }
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Actual)).Equals(
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Expected)), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AtlasRegularPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissing)
    $guards = Open-AtlasPathGuards -Path $Path -AllowMissing:$AllowMissing
    try { return [IO.Path]::GetFullPath($Path) }
    finally { foreach ($guard in $guards) { $guard.Dispose() } }
}

function Initialize-AtlasPathGuard {
    if ('ProjectAtlas.SourceFingerprintPathGuard' -as [type]) { return }
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../.github/scripts/Assert-ControllerPreflight.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Zentraler Pfadpruefer besitzt Syntaxfehler.' }
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Add-Type' }, $true))
    $source = @($definitions.CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value.Contains('sealed class SourceFingerprintPathGuard') })
    if ($source.Count -ne 1) { throw 'Native Pfadsicherung ist nicht eindeutig vorhanden.' }
    Add-Type -TypeDefinition $source[0].Value
}

function Open-AtlasPathGuards {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissing, [switch]$AllowMicrosoftRuntimeHardLink)
    Initialize-AtlasPathGuard
    $full = [IO.Path]::GetFullPath($Path)
    $current = [IO.Path]::GetPathRoot($full)
    $guards = [Collections.Generic.List[IDisposable]]::new()
    try {
        $segments = @('') + @([IO.Path]::GetRelativePath($current, $full).Split([char[]]@('\','/'), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ -ne '.' })
        foreach ($segment in $segments) {
            if ($segment) { $current = Join-Path $current $segment }
            if (-not (Test-Path -LiteralPath $current)) {
                if ($AllowMissing) { continue }
                throw 'Erforderlicher lokaler Pfad fehlt.'
            }
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            $guard = [ProjectAtlas.SourceFingerprintPathGuard]::Open($item.FullName, $item.PSIsContainer)
            $guards.Add($guard)
            # Microsoft verteilt WebView2 selbst mit Hardlinks. Nur das separat
            # signaturgepruefte Runtime-Binary darf diese Ausnahme nutzen; keine
            # Paket-/Installationsdatei und keine umgeleitete Pfadkomponente.
            $runtimeHardLink = $AllowMicrosoftRuntimeHardLink -and
                (Test-AtlasSamePath $item.FullName $full) -and -not $item.PSIsContainer -and
                $full -match '(?i)[\\/]Microsoft[\\/]EdgeWebView[\\/]Application[\\/]\d+\.\d+\.\d+\.\d+[\\/]msedgewebview2\.exe$' -and
                $item.LinkType -ceq 'HardLink' -and $guard.ReparseTag -eq 0 -and
                ($guard.FileAttributes -band [uint32]0x400) -eq 0
            if ((($guard.FileAttributes -band [uint32]0x400) -ne 0 -and $guard.ReparseTag -eq 0) -or
                ($guard.ReparseTag -band [uint32]0x20000000) -ne 0 -or
                (-not $runtimeHardLink -and ($item.LinkType -or $item.LinkTarget)) -or $item.ResolveLinkTarget($false)) {
                throw 'Lokale Installation akzeptiert keine Pfadumleitung oder unbekannten Reparse-Tags.'
            }
        }
        return ,$guards
    } catch { foreach ($guard in $guards) { $guard.Dispose() }; throw }
}

function Get-AtlasFileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }

function Remove-AtlasSigningEnvironment($StartInfo) {
    foreach ($name in @('TAURI_SIGNING_PRIVATE_KEY','TAURI_SIGNING_PRIVATE_KEY_PATH','TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) { [void]$StartInfo.Environment.Remove($name) }
}

function Write-AtlasLocalJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    [void](Assert-AtlasRegularPath -Path $Path -AllowMissing)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 40))
        $stream.Write($bytes); $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Assert-AtlasLocalSource {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ExpectedCommit)
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Exakter Quellcommit fehlt.' }
    $full = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).ProviderPath
    $head = @(& git -C $full rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($head -join '').Trim() -cne $ExpectedCommit) { throw 'Quellcommit hat sich geaendert.' }
    $branch = @(& git -C $full branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($branch -join '').Trim() -cne 'main') { throw 'Lokale Installation verlangt den geprueften main-Checkout.' }
    $remote = @(& git -C $full remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($remote -join '').Trim() -cnotmatch '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)einzigTimo/projectatlas-desktop(?:\.git)?/?$') {
        throw 'Atlas-Quelle hat ein anderes Repository.'
    }
    $remoteHead = @(& git -C $full rev-parse refs/remotes/origin/main 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($remoteHead -join '').Trim() -cne $ExpectedCommit) { throw 'Lokaler main entspricht nicht dem geprueften origin/main.' }
    $live = @(& git -c credential.interactive=never -C $full ls-remote --exit-code origin refs/heads/main 2>$null)
    if ($LASTEXITCODE -ne 0 -or $live.Count -ne 1 -or ($live[0] -split '\s+')[0] -cne $ExpectedCommit) { throw 'Live-origin/main entspricht nicht dem attestierten Quellcommit.' }
    $state = @(& git -C $full status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $state.Count) { throw 'Quellarbeitsbaum ist nicht sauber.' }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($full))
}

function Assert-AtlasLocalSignature {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Thumbprint)
    if ($Thumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') { throw 'Herausgeberbindung fehlt.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ine $Thumbprint -or -not $signature.TimeStamperCertificate) {
        throw 'Datei besitzt keine gueltige, gepinnte Windows-Signatur mit Zeitstempel.'
    }
    $eku = @($signature.SignerCertificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages.Value })
    $timestampEku = @($signature.TimeStamperCertificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages.Value })
    if ('1.3.6.1.5.5.7.3.3' -notin $eku -or '1.3.6.1.5.5.7.3.8' -notin $timestampEku) {
        throw 'Signatur- oder Zeitstempelzertifikat besitzt nicht den erforderlichen Verwendungszweck.'
    }
}

function Assert-AtlasManifestCms {
    param([Parameter(Mandatory)][byte[]]$ManifestBytes, [Parameter(Mandatory)][byte[]]$SignatureBytes, [Parameter(Mandatory)][string]$ExpectedThumbprint)
    if ($ExpectedThumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') { throw 'Unabhaengig gebundener Herausgeber fuer das Paketmanifest fehlt.' }
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($ManifestBytes), $true)
    $cms.Decode($SignatureBytes)
    if ($cms.SignerInfos.Count -ne 1 -or -not $cms.SignerInfos[0].Certificate -or
        $cms.SignerInfos[0].Certificate.Thumbprint -ine $ExpectedThumbprint -or
        $cms.SignerInfos[0].DigestAlgorithm.Value -cne '2.16.840.1.101.3.4.2.1') { throw 'Paketmanifest besitzt keine eindeutige SHA-256-Herausgebersignatur.' }
    $cms.CheckSignature($true)
    Assert-AtlasManifestTrust $cms
    $eku = @($cms.SignerInfos[0].Certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages.Value })
    if ('1.3.6.1.5.5.7.3.3' -notin $eku) { throw 'Paketmanifest wurde nicht mit einem Code-Signing-Zertifikat signiert.' }
}

function Assert-AtlasManifestTrust($Cms) { $Cms.CheckSignature($false) }

function Invoke-AtlasUpdaterVerification {
    param([string]$Verifier, [string]$Installer, [string]$Signature, [string]$Config)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Verifier; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    Remove-AtlasSigningEnvironment $start
    foreach ($argument in @($Installer,$Signature,$Config)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Der verifizierte Updater-Pruefer konnte nicht starten.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); [void]$process.WaitForExit(10000); throw 'Updater-Pruefung ueberschritt das Zeitlimit.' }
        [void]$stdout.GetAwaiter().GetResult(); [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Tauri-Updater-Signatur passt nicht zum Installer und eingebetteten Schluessel.' }
    } finally { $process.Dispose() }
}

function Open-AtlasLocalPackage {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedThumbprint)
    $directory = Get-AtlasLocalPackageDirectory -Commit $ExpectedCommit
    [void](Assert-AtlasRegularPath $directory)
    $names = @('installer.exe', 'installer.exe.sig', 'projectatlas-desktop.exe', 'projectatlas-cli.exe', 'verify_updater_signature.exe')
    $handles = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($guard in (Open-AtlasPathGuards $directory)) { $handles.Add($guard) }
        $entries = @(Get-ChildItem -LiteralPath $directory -Force)
        $allowed = @('candidate.json','candidate.json.p7s','installed.json') + $names
        if (@($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $allowed }).Count) { throw 'Paketverzeichnis enthaelt fremde Dateien oder Verzeichnisse.' }
        foreach ($name in @('candidate.json','candidate.json.p7s') + $names) {
            $path = Join-Path $directory $name
            [void](Assert-AtlasRegularPath $path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Lokales Paket ist unvollstaendig.' }
            $handles.Add([IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
            foreach ($guard in (Open-AtlasPathGuards $path)) { $handles.Add($guard) }
            [void](Assert-AtlasRegularPath $path)
        }
        $manifestPath = Join-Path $directory 'candidate.json'
        if ((Get-Item -LiteralPath $manifestPath).Length -gt 65536) { throw 'Paketmanifest ist unplausibel gross.' }
        $cmsPath = Join-Path $directory 'candidate.json.p7s'
        if ((Get-Item -LiteralPath $cmsPath).Length -gt 65536) { throw 'Paketattestierung ist unplausibel gross.' }
        $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
        Assert-AtlasManifestCms -ManifestBytes $manifestBytes -SignatureBytes ([IO.File]::ReadAllBytes($cmsPath)) -ExpectedThumbprint $ExpectedThumbprint
        $manifest = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) | ConvertFrom-Json -AsHashtable -DateKind String
        if ($manifest.schema -cne 'projectatlas.desktop.local-package.v1' -or $manifest.scope -cne 'local-windows' -or
            -not (Test-AtlasSamePath $manifest.sourceRoot $Root) -or $manifest.sourceCommit -cne $ExpectedCommit -or
            $manifest.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
            $manifest.certificateThumbprint -ine $ExpectedThumbprint -or
            $manifest.machineName -cne [Environment]::MachineName -or
            $manifest.userSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Paketmanifest hat eine falsche Ziel-, Quell-, Versions-, Rechner-, Benutzer- oder Zertifikatsbindung.' }
        $created = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($manifest.createdAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$created) -or
            $created -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) { throw 'Paketmanifest hat keinen plausiblen Erstellungszeitpunkt.' }
        $artifacts = @($manifest.artifacts)
        if ($artifacts.Count -ne $names.Count -or @($artifacts.name | Sort-Object -Unique -CaseSensitive).Count -ne $names.Count) { throw 'Paketmanifest enthaelt keine eindeutige Fuenfer-Artefaktliste.' }
        foreach ($artifact in $artifacts) {
            if ($artifact.name -cnotin $names -or $artifact.sha256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
                ($artifact.length -isnot [long] -and $artifact.length -isnot [int]) -or $artifact.length -le 0) { throw 'Paketmanifest enthaelt ein unbekanntes oder ungueltiges Artefakt.' }
            $path = Join-Path $directory $artifact.name
            if ((Get-Item -LiteralPath $path).Length -ne $artifact.length -or (Get-AtlasFileHash $path) -ine $artifact.sha256) { throw 'Lokales Paket hat sich seit dem Einfrieren veraendert.' }
            if ($artifact.name -like '*.exe') { Assert-AtlasLocalSignature -Path $path -Thumbprint $manifest.certificateThumbprint }
        }
        $configPath = Join-Path $Root 'crates/projectatlas-desktop/tauri.conf.json'
        foreach ($guard in (Open-AtlasPathGuards $configPath)) { $handles.Add($guard) }
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($config.version -cne $manifest.version) { throw 'Paketversion weicht von der Quellversion ab.' }
        $verifier = Join-Path $directory 'verify_updater_signature.exe'
        if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'Gebauter kryptografischer Updater-Pruefer fehlt.' }
        Invoke-AtlasUpdaterVerification -Verifier $verifier -Installer (Join-Path $directory 'installer.exe') -Signature (Join-Path $directory 'installer.exe.sig') -Config $configPath
        return [pscustomobject]@{ Directory=$directory; Manifest=$manifest; ManifestHash=(Get-AtlasFileHash $manifestPath); Handles=$handles }
    } catch { foreach ($handle in $handles) { $handle.Dispose() }; throw }
}

function Close-AtlasLocalPackage($Package) { if ($Package) { foreach ($handle in $Package.Handles) { $handle.Dispose() } } }

function Assert-AtlasLocalPackage {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ExpectedCommit, [Parameter(Mandatory)][string]$ExpectedThumbprint)
    $package = $null
    try {
        $package = Open-AtlasLocalPackage -Root $Root -ExpectedCommit $ExpectedCommit -ExpectedThumbprint $ExpectedThumbprint
        return [pscustomobject]@{ Directory=$package.Directory; Manifest=$package.Manifest; ManifestHash=$package.ManifestHash }
    } finally { Close-AtlasLocalPackage $package }
}

function Get-AtlasProcessIdentity([Diagnostics.Process]$Process) {
    @{ pid=$Process.Id; startTimeUtcTicks=$Process.StartTime.ToUniversalTime().Ticks; path=[IO.Path]::GetFullPath($Process.Path) }
}

function Test-AtlasProcessIdentity($Identity) {
    $process = Get-Process -Id ([int]$Identity.pid) -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    $process.StartTime.ToUniversalTime().Ticks -eq [long]$Identity.startTimeUtcTicks -and (Test-AtlasSamePath $process.Path $Identity.path)
}

function Stop-AtlasExactGui {
    param($Identity, [switch]$AllowForce)
    if (-not $Identity) { return }
    if (-not (Test-AtlasProcessIdentity $Identity)) {
        if (Get-Process -Id ([int]$Identity.pid) -ErrorAction SilentlyContinue) { throw 'Eine andere Prozessidentitaet belegt die alte PID.' }
        return
    }
    $process = Get-Process -Id ([int]$Identity.pid)
    [void]$process.CloseMainWindow()
    if (-not $process.WaitForExit(10000)) {
        if (-not $AllowForce -or -not (Test-AtlasProcessIdentity $Identity)) { throw 'Atlas beendet sich nicht regulär; Installation bleibt gesperrt.' }
        Stop-Process -Id ([int]$Identity.pid) -Force
        if (-not $process.WaitForExit(10000)) { throw 'Der exakt gebundene Atlas-Prozess laeuft weiter.' }
    }
}

function Get-AtlasRunningGui {
    $path = Join-Path (Get-AtlasLocalInstallDirectory) 'projectatlas-desktop.exe'
    $processes = @(Get-Process -Name projectatlas-desktop -ErrorAction SilentlyContinue | Where-Object { Test-AtlasSamePath $_.Path $path })
    if ($processes.Count -gt 1) { throw 'Mehrere installierte Atlas-Fenster sind aktiv.' }
    if ($processes.Count -eq 1) { return Get-AtlasProcessIdentity $processes[0] }
    return $null
}

function Assert-AtlasNoInstalledSidecar {
    $path = Join-Path (Get-AtlasLocalInstallDirectory) 'projectatlas-cli.exe'
    if (@(Get-Process -Name projectatlas-cli -ErrorAction SilentlyContinue | Where-Object { Test-AtlasSamePath $_.Path $path }).Count) {
        throw 'Ein installierter Atlas-Sidecar/MCP-Prozess ist aktiv. Er wird nicht beendet; Update wartet auf sein Ende.'
    }
}

function Assert-AtlasWebViewRuntime {
    $candidates = @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft/EdgeWebView/Application'),
        (Join-Path $env:ProgramFiles 'Microsoft/EdgeWebView/Application'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft/EdgeWebView/Application')) | Sort-Object -Unique
    foreach ($directory in $candidates) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        [void](Assert-AtlasRegularPath $directory)
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory) {
            if ($child.Name -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            $path = Join-Path $child.FullName 'msedgewebview2.exe'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $guards = Open-AtlasPathGuards -Path $path -AllowMicrosoftRuntimeHardLink
            try {
                $signature = Get-AuthenticodeSignature -LiteralPath $path
                $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
                $fileVersion = '{0}.{1}.{2}.{3}' -f $version.FileMajorPart,$version.FileMinorPart,$version.FileBuildPart,$version.FilePrivatePart
                if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)' -and
                    $fileVersion -ceq $child.Name) { return }
            } finally { foreach ($guard in $guards) { $guard.Dispose() } }
        }
    }
    throw 'Eine vorhandene, gueltig signierte Microsoft-WebView2-Laufzeit konnte nicht bestaetigt werden. Das lokale Paket laedt keine Laufzeit nach.'
}

function Start-AtlasInstalledGui {
    $path = Join-Path (Get-AtlasLocalInstallDirectory) 'projectatlas-desktop.exe'
    if (Get-AtlasRunningGui) { throw 'Vor dem kontrollierten Atlas-Start existiert bereits ein Fenster.' }
    $process = Start-Process -FilePath $path -WorkingDirectory (Split-Path -Parent $path) -PassThru
    $identity = Get-AtlasProcessIdentity $process
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw 'Installierter Atlas-Prozess ist vor der Fensterabnahme beendet.' }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.Responding -and (Test-AtlasProcessIdentity $identity)) { return $identity }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Stop-AtlasExactGui -Identity $identity -AllowForce
    throw 'Installierter Atlas-Prozess hat kein antwortendes Fenster geoeffnet.'
}

function Get-AtlasInstallInventory {
    param([Parameter(Mandatory)][string]$Directory)
    [void](Assert-AtlasRegularPath $Directory)
    $result = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Directory)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            [void](Assert-AtlasRegularPath $item.FullName)
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = [IO.Path]::GetRelativePath($Directory, $item.FullName)
            $result.Add(@{ name=$relative; length=$item.Length; sha256=(Get-AtlasFileHash $item.FullName) })
            if ($result.Count -gt 10000) { throw 'Bestehende Installation enthaelt unerwartet viele Dateien.' }
        }
    }
    return @($result | Sort-Object { $_.name })
}

function Get-AtlasRegistryTree($Key) {
    $values = @(); $children = [ordered]@{}
    foreach ($name in @($Key.GetValueNames() | Sort-Object)) {
        $kind = $Key.GetValueKind($name)
        $value = $Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary -or $kind -eq [Microsoft.Win32.RegistryValueKind]::None) { $value = [Convert]::ToBase64String([byte[]]$value) }
        $values += [ordered]@{ name=$name; kind=$kind.ToString(); value=$value }
    }
    foreach ($name in @($Key.GetSubKeyNames() | Sort-Object)) {
        $child = $Key.OpenSubKey($name, $false)
        try { $children[$name] = Get-AtlasRegistryTree $child } finally { $child.Dispose() }
    }
    [ordered]@{ values=$values; children=$children }
}

function Get-AtlasInstallRegistrySnapshot {
    $snapshot = @()
    foreach ($view in @('Registry64','Registry32')) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::$view)
        try {
            foreach ($path in @('Software\Microsoft\Windows\CurrentVersion\Uninstall\ProjectAtlas Desktop', 'Software\einzigTimo\ProjectAtlas Desktop')) {
                $key = $base.OpenSubKey($path, $false)
                try { $snapshot += [ordered]@{ view=$view; path=$path; exists=($null -ne $key); tree=$(if ($key) { Get-AtlasRegistryTree $key } else { $null }) } }
                finally { if ($key) { $key.Dispose() } }
            }
        } finally { $base.Dispose() }
    }
    return $snapshot
}

function Set-AtlasRegistryTree($Key, $Tree) {
    foreach ($entry in $Tree.values) {
        $kind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], $entry.kind))
        $value = switch ($entry.kind) {
            'Binary' { ,([Convert]::FromBase64String($entry.value)) }
            'None' { ,([Convert]::FromBase64String($entry.value)) }
            'DWord' { [int]$entry.value }
            'QWord' { [long]$entry.value }
            'MultiString' { ,([string[]]$entry.value) }
            default { [string]$entry.value }
        }
        $Key.SetValue($entry.name, $value, $kind)
    }
    foreach ($name in $Tree.children.Keys) {
        $child = $Key.CreateSubKey($name, $true)
        try { Set-AtlasRegistryTree $child $Tree.children[$name] } finally { $child.Dispose() }
    }
}

function Restore-AtlasInstallRegistry($Snapshot) {
    foreach ($entry in $Snapshot) {
        if ($entry.view -cnotin @('Registry64','Registry32') -or $entry.path -cnotin @('Software\Microsoft\Windows\CurrentVersion\Uninstall\ProjectAtlas Desktop','Software\einzigTimo\ProjectAtlas Desktop')) { throw 'Fremder Registry-Rueckkehrpfad wurde abgewiesen.' }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]([Enum]::Parse([Microsoft.Win32.RegistryView], $entry.view)))
        try {
            $base.DeleteSubKeyTree($entry.path, $false)
            if ($entry.exists) {
                $key = $base.CreateSubKey($entry.path, $true)
                try { Set-AtlasRegistryTree $key $entry.tree } finally { $key.Dispose() }
            }
        } finally { $base.Dispose() }
    }
}

function Get-AtlasPreservedFilePaths {
    @((Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'ProjectAtlas Desktop.lnk'),
      (Join-Path ([Environment]::GetFolderPath('Programs')) 'ProjectAtlas Desktop.lnk'),
      (Join-Path ([Environment]::GetFolderPath('Programs')) 'ProjectAtlas Desktop/ProjectAtlas Desktop.lnk'),
      (Get-AtlasLocalRegistryPath)) | Sort-Object -Unique
}

function New-AtlasInstallBackup {
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -cnotmatch '^[A-Za-z0-9_-]{1,100}$') { throw 'Zentrale Laufkennung ist ungueltig.' }
    $install = Get-AtlasLocalInstallDirectory
    foreach ($name in @('projectatlas-desktop.exe','projectatlas-cli.exe','uninstall.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $install $name) -PathType Leaf)) { throw 'Nur eine vollstaendige bestehende Atlas-Installation darf aktualisiert werden.' }
    }
    $backupRoot = Join-Path (Get-AtlasLocalStateDirectory) ('backups/' + $RunId + '-' + [Guid]::NewGuid().ToString('N'))
    [void](Assert-AtlasRegularPath -Path $backupRoot -AllowMissing)
    [void][IO.Directory]::CreateDirectory((Join-Path $backupRoot 'app'))
    $inventory = @(Get-AtlasInstallInventory $install)
    foreach ($entry in $inventory) {
        $destination = Join-Path $backupRoot ('app/' + $entry.name)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Join-Path $install $entry.name) -Destination $destination
        if ((Get-AtlasFileHash $destination) -cne $entry.sha256) { throw 'Installationssicherung hat eine abweichende Pruefsumme.' }
    }
    $currentInventory = @(Get-AtlasInstallInventory $install)
    if ($currentInventory.Count -ne $inventory.Count -or @($inventory | Where-Object {
        $entry = $_
        @($currentInventory | Where-Object { $_.name -ceq $entry.name -and $_.sha256 -ceq $entry.sha256 -and $_.length -eq $entry.length }).Count -ne 1
    }).Count) { throw 'Bestehende Installation hat sich waehrend ihrer Sicherung veraendert.' }
    $preserved = @()
    foreach ($path in Get-AtlasPreservedFilePaths) {
        [void](Assert-AtlasRegularPath -Path $path -AllowMissing)
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $destination = Join-Path $backupRoot ('preserved-' + $preserved.Count)
        if ($exists) {
            $guards = Open-AtlasPathGuards $path
            try { Copy-Item -LiteralPath $path -Destination $destination; if ((Get-AtlasFileHash $path) -cne (Get-AtlasFileHash $destination)) { throw 'Benutzereinstellung hat sich waehrend ihrer Sicherung veraendert.' } }
            finally { foreach ($guard in $guards) { $guard.Dispose() } }
        }
        $preserved += @{ path=$path; exists=$exists; backup=$(if ($exists) { $destination } else { $null }); sha256=$(if ($exists) { Get-AtlasFileHash $destination } else { $null }) }
    }
    $backup = @{ schema='projectatlas.desktop.local-backup.v1'; directory=$backupRoot; installPath=$install; files=$inventory; registry=@(Get-AtlasInstallRegistrySnapshot); preserved=$preserved }
    Write-AtlasLocalJson -Path (Join-Path $backupRoot 'backup.json') -Value $backup
    $backup.manifestSha256 = Get-AtlasFileHash (Join-Path $backupRoot 'backup.json')
    return $backup
}

function Assert-AtlasUserRegistryUnchanged($Backup) {
    $entry = @($Backup.preserved | Where-Object { Test-AtlasSamePath $_.path (Get-AtlasLocalRegistryPath) })
    if ($entry.Count -ne 1) { throw 'Sicherung der persoenlichen Atlas-Registry fehlt.' }
    $exists = Test-Path -LiteralPath $entry[0].path -PathType Leaf
    if ($exists -ne $entry[0].exists -or ($exists -and (Get-AtlasFileHash $entry[0].path) -cne $entry[0].sha256)) { throw 'Das Update hat die persoenliche Atlas-Registry veraendert.' }
}

function Restore-AtlasInstallBackup($Backup) {
    $install = Get-AtlasLocalInstallDirectory
    if (-not (Test-AtlasSamePath $Backup.installPath $install)) { throw 'Sicherung gehoert nicht zum festen Atlas-Installationspfad.' }
    $backupPrefix = [IO.Path]::GetFullPath((Join-Path (Get-AtlasLocalStateDirectory) 'backups')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not ([IO.Path]::GetFullPath($Backup.directory)).StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-AtlasFileHash (Join-Path $Backup.directory 'backup.json')) -cne $Backup.manifestSha256) { throw 'Sicherungsmanifest ist nicht mehr unveraendert.' }
    [void](Assert-AtlasRegularPath -Path $install -AllowMissing)
    [void][IO.Directory]::CreateDirectory($install)
    foreach ($entry in $Backup.files) {
        $source = Join-Path $Backup.directory ('app/' + $entry.name)
        [void](Assert-AtlasRegularPath $source)
        if ((Get-AtlasFileHash $source) -cne $entry.sha256) { throw 'Sicherungsdatei ist nicht mehr unveraendert.' }
    }
    # Neue Dateien werden einzeln anhand der aktuellen, linkfreien Inventarliste entfernt.
    foreach ($entry in @(Get-AtlasInstallInventory $install)) {
        if ($entry.name -cnotin @($Backup.files.name)) { Remove-Item -LiteralPath (Join-Path $install $entry.name) -Force }
    }
    foreach ($entry in $Backup.files) {
        $destination = Join-Path $install $entry.name
        [void](Assert-AtlasRegularPath -Path $destination -AllowMissing)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Join-Path $Backup.directory ('app/' + $entry.name)) -Destination $destination -Force
    }
    Restore-AtlasInstallRegistry $Backup.registry
    $allowed = @(Get-AtlasPreservedFilePaths)
    foreach ($entry in $Backup.preserved) {
        if ($entry.path -notin $allowed) { throw 'Fremder Sicherungspfad wurde abgewiesen.' }
        [void](Assert-AtlasRegularPath -Path $entry.path -AllowMissing)
        if ($entry.exists) {
            if ((Get-AtlasFileHash $entry.backup) -cne $entry.sha256) { throw 'Sicherung einer Benutzereinstellung ist veraendert.' }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $entry.path))
            Copy-Item -LiteralPath $entry.backup -Destination $entry.path -Force
        } elseif (Test-Path -LiteralPath $entry.path -PathType Leaf) { Remove-Item -LiteralPath $entry.path -Force }
    }
    Assert-AtlasRestoredBackup $Backup
}

function Assert-AtlasRestoredBackup($Backup) {
    $actual = @(Get-AtlasInstallInventory (Get-AtlasLocalInstallDirectory))
    if ($actual.Count -ne @($Backup.files).Count) { throw 'Wiederhergestellte Installation hat ein anderes Dateiinventar.' }
    foreach ($entry in $Backup.files) {
        $match = @($actual | Where-Object { $_.name -ceq $entry.name -and $_.sha256 -ceq $entry.sha256 -and $_.length -eq $entry.length })
        if ($match.Count -ne 1) { throw 'Wiederhergestellte Installation hat abweichende Dateien.' }
    }
    # Registry-Snapshots besitzen kanonisch sortierte Schluessel und Werte.
    if ((@(Get-AtlasInstallRegistrySnapshot) | ConvertTo-Json -Depth 40 -Compress) -cne ($Backup.registry | ConvertTo-Json -Depth 40 -Compress)) { throw 'Windows-Registry wurde nicht exakt wiederhergestellt.' }
    foreach ($entry in $Backup.preserved) {
        $exists = Test-Path -LiteralPath $entry.path -PathType Leaf
        if ($exists -ne $entry.exists -or ($exists -and (Get-AtlasFileHash $entry.path) -cne $entry.sha256)) { throw 'Verknuepfung oder Benutzereinstellung wurde nicht exakt wiederhergestellt.' }
    }
}

function Assert-AtlasInstalledPayload($Package) {
    $install = Get-AtlasLocalInstallDirectory
    $hashes = [ordered]@{}
    foreach ($name in @('projectatlas-desktop.exe','projectatlas-cli.exe')) {
        $path = Join-Path $install $name
        [void](Assert-AtlasRegularPath $path)
        $expected = @($Package.Manifest.artifacts | Where-Object { $_.name -ceq $name })[0]
        $hashes[$name] = Get-AtlasFileHash $path
        if ($hashes[$name] -ine $expected.sha256 -or (Get-Item -LiteralPath $path).Length -ne $expected.length) { throw 'Installierte Datei entspricht nicht exakt dem signierten Paketinhalt.' }
        Assert-AtlasLocalSignature -Path $path -Thumbprint $Package.Manifest.certificateThumbprint
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install 'projectatlas-desktop.exe'))
    if ($version.ProductMajorPart -ne [int]$Package.Manifest.version.Split('.')[0] -or
        $version.ProductMinorPart -ne [int]$Package.Manifest.version.Split('.')[1] -or
        $version.ProductBuildPart -ne [int]$Package.Manifest.version.Split('.')[2]) { throw 'Installierte Programmversion ist nicht die Paketversion.' }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\ProjectAtlas Desktop', $false)
        try {
            if (-not $key -or $key.GetValue('DisplayVersion') -cne $Package.Manifest.version -or
                -not (Test-AtlasSamePath ([string]$key.GetValue('InstallLocation')).Trim('"') $install)) { throw 'Windows-Installationsregistrierung bestaetigt Version und Zielpfad nicht.' }
        } finally { if ($key) { $key.Dispose() } }
    } finally { $base.Dispose() }
    return $hashes
}

function Invoke-AtlasLocalInstallTransaction($Operations) {
    $mutated = $false; $result = 'failed-before-install'; $failure = $null
    try {
        & $Operations.Revalidate
        $mutated = $true
        & $Operations.Install
        & $Operations.Verify
        $result = 'succeeded'
        & $Operations.WriteReceipt $result
    } catch {
        $failure = $_.Exception
        if ($mutated) {
            try { & $Operations.Restore; & $Operations.VerifyRestored; $result = 'failed-restored' }
            catch { $failure = [Exception]::new('Installation und Wiederherstellung sind fehlgeschlagen.', $_.Exception); $result = 'failed-unresolved' }
        }
        try { & $Operations.WriteReceipt $result }
        catch { $failure = [Exception]::new('Installationsabschluss konnte nicht verlaesslich gespeichert werden.', $_.Exception) }
    }
    if ($failure) { throw [Exception]::new("Lokale Atlas-Installation: $result", $failure) }
}
