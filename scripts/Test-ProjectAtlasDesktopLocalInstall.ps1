#Requires -Version 7.5
<# Synthetische Installationspruefung: kein echter Installer, keine GUI, keine Truststore- oder Benutzerregistry-Aenderung. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ProjectAtlasLocalInstall.ps1"
$script:assertions = 0
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-Test $failed $Message
}

foreach ($name in @('ProjectAtlasLocalInstall.ps1','Install-ProjectAtlasDesktopLocal.ps1','Assert-ProjectAtlasDesktopInstalled.ps1')) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) "Syntaxfehler in $name."
}
$release = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/scripts/invoke-desktop-release.ps1') -Raw
Assert-Test ($release.Contains('$PrepareLocalPackage -and ($Publish -or $SkipSidecar -or $AllowUnsignedUpdater)')) 'Lokaler Paketmodus muss Publish, SkipSidecar und unsigned explizit ausschliessen.'
Assert-Test ($release.Contains('$legacySingleInvocationPublishEnabled = $false')) 'Oeffentliche Single-Invocation-Promotion darf durch den lokalen Weg nicht aktiviert werden.'
$installerScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-ProjectAtlasDesktopLocal.ps1') -Raw
Assert-Test ($installerScript.Contains('/S /UPDATE /NS /D=$install')) 'NSIS-Updateargumente muessen fest gebunden sein.'
Assert-Test (-not ($installerScript -match '(?i)gh\s+release|workflow\s+run|git\s+push|truststore|certutil')) 'Lokaler Installer darf keine Veroeffentlichung und keinen Truststore-Import ausloesen.'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$testRoot = Join-Path $tempBase ('atlas-local-install-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:testRoot = $testRoot
function Get-AtlasLocalStateDirectory { Join-Path $script:testRoot 'state' }
function Get-AtlasLocalInstallDirectory { Join-Path $script:testRoot 'installed' }
function Get-AtlasLocalRegistryPath { Join-Path $script:testRoot 'user/registry.json' }
function Get-AtlasPreservedFilePaths { @((Join-Path $script:testRoot 'Desktop/ProjectAtlas Desktop.lnk'), (Get-AtlasLocalRegistryPath)) }
$script:registryFixture = @([ordered]@{ view='Registry64'; path='test-only'; exists=$true; tree=[ordered]@{ values=@(); children=[ordered]@{} } })
function Get-AtlasInstallRegistrySnapshot { $script:registryFixture }
function Restore-AtlasInstallRegistry($Snapshot) { $script:registryFixture = $Snapshot }

$rsa = $null; $certificate = $null; $package = $null
try {
    $source = Join-Path $testRoot 'source'
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'crates/projectatlas-desktop'))
    [IO.File]::WriteAllText((Join-Path $source 'crates/projectatlas-desktop/tauri.conf.json'), '{"version":"0.2.3"}')
    $commit = 'a' * 40
    $packageDirectory = Get-AtlasLocalPackageDirectory -Commit $commit
    [void][IO.Directory]::CreateDirectory($packageDirectory)
    $names = @('installer.exe','installer.exe.sig','projectatlas-desktop.exe','projectatlas-cli.exe','verify_updater_signature.exe')
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $packageDirectory $name), "synthetic-$name") }
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Atlas local install test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids = [Security.Cryptography.OidCollection]::new(); [void]$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddHours(1))
    $manifest = [ordered]@{
        schema='projectatlas.desktop.local-package.v1'; scope='local-windows'; sourceRoot=$source; sourceCommit=$commit
        version='0.2.3'; certificateThumbprint=$certificate.Thumbprint; createdAtUtc=[DateTimeOffset]::UtcNow.ToString('O')
        machineName=[Environment]::MachineName; userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        artifacts=@(foreach ($name in $names) { [ordered]@{ name=$name; sha256=(Get-AtlasFileHash (Join-Path $packageDirectory $name)); length=(Get-Item -LiteralPath (Join-Path $packageDirectory $name)).Length } })
    }
    function Write-TestSignedManifest($Value) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20))
        $cms = [Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($bytes), $true)
        $signer = [Security.Cryptography.Pkcs.CmsSigner]::new($certificate)
        $signer.DigestAlgorithm = [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
        $cms.ComputeSignature($signer)
        [IO.File]::WriteAllBytes((Join-Path $packageDirectory 'candidate.json'), $bytes)
        [IO.File]::WriteAllBytes((Join-Path $packageDirectory 'candidate.json.p7s'), $cms.Encode())
    }
    Write-TestSignedManifest $manifest
    $bytes = [IO.File]::ReadAllBytes((Join-Path $packageDirectory 'candidate.json'))
    $signatureBytes = [IO.File]::ReadAllBytes((Join-Path $packageDirectory 'candidate.json.p7s'))
    Assert-Throws { Assert-AtlasManifestCms -ManifestBytes $bytes -SignatureBytes $signatureBytes -ExpectedThumbprint $certificate.Thumbprint } 'Ein nicht vertrautes Testzertifikat darf im produktiven CMS-Pruefer nicht akzeptiert werden.'
    Assert-Throws { Assert-AtlasManifestCms -ManifestBytes $bytes -SignatureBytes $signatureBytes -ExpectedThumbprint ('0' * 40) } 'Ein anderer zentraler Herausgeber muss blockieren.'
    # Ab hier wird ausschliesslich Windows-Vertrauen gemockt. Kryptografische CMS-Pruefung bleibt echt.
    function Assert-AtlasManifestTrust($Cms) { $Cms.CheckSignature($true) }
    function Assert-AtlasLocalSignature { param([string]$Path,[string]$Thumbprint); if ($Thumbprint -ine $certificate.Thumbprint) { throw 'Falscher Testsigner.' } }
    function Invoke-AtlasUpdaterVerification {
        param([string]$Verifier,[string]$Installer,[string]$Signature,[string]$Config)
        if (-not (Test-AtlasSamePath $Verifier (Join-Path $packageDirectory 'verify_updater_signature.exe'))) { throw 'Ungepruefter externer Verifier.' }
    }
    Assert-AtlasManifestCms -ManifestBytes $bytes -SignatureBytes $signatureBytes -ExpectedThumbprint $certificate.Thumbprint
    Assert-Test $true 'CMS-Fixture akzeptiert.'
    $changed = [byte[]]$bytes.Clone(); $changed[10] = $changed[10] -bxor 1
    Assert-Throws { Assert-AtlasManifestCms -ManifestBytes $changed -SignatureBytes $signatureBytes -ExpectedThumbprint $certificate.Thumbprint } 'Nachtraeglich manipuliertes Manifest muss kryptografisch scheitern.'
    $package = Open-AtlasLocalPackage -Root $source -ExpectedCommit $commit -ExpectedThumbprint $certificate.Thumbprint
    Assert-Test ($package.Manifest.version -ceq '0.2.3') 'Gueltiges synthetisches Paket wurde nicht gelesen.'
    Assert-Throws { [IO.File]::WriteAllText((Join-Path $packageDirectory 'projectatlas-desktop.exe'), 'changed') } 'Offene Paketdatei muss Schreibzugriff blockieren.'
    Assert-Throws { [IO.Directory]::Move($packageDirectory, "$packageDirectory-renamed") } 'Offene Paket-Ancestry muss Pfadtausch blockieren.'
    Close-AtlasLocalPackage $package; $package = $null
    $manifest.machineName = 'another-machine'
    Write-TestSignedManifest $manifest
    Assert-Throws { Open-AtlasLocalPackage -Root $source -ExpectedCommit $commit -ExpectedThumbprint $certificate.Thumbprint } 'Signiertes Paket fuer anderen Rechner muss blockieren.'
    $manifest.machineName = [Environment]::MachineName
    $manifest.artifacts[0].name = '../escape.exe'
    Write-TestSignedManifest $manifest
    Assert-Throws { Open-AtlasLocalPackage -Root $source -ExpectedCommit $commit -ExpectedThumbprint $certificate.Thumbprint } 'Signierte Pfadtraversierung muss blockieren.'
    $manifest.artifacts[0].name = 'installer.exe'
    Write-TestSignedManifest $manifest
    [IO.File]::WriteAllText((Join-Path $packageDirectory 'foreign.exe'), 'unexpected')
    Assert-Throws { Open-AtlasLocalPackage -Root $source -ExpectedCommit $commit -ExpectedThumbprint $certificate.Thumbprint } 'Unbekannte zusaetzliche Paketdatei muss blockieren.'
    Remove-Item -LiteralPath (Join-Path $packageDirectory 'foreign.exe')

    $linkTarget = Join-Path $testRoot 'link-target'; [void][IO.Directory]::CreateDirectory($linkTarget)
    $junction = Join-Path $testRoot 'junction'
    [void](New-Item -ItemType Junction -Path $junction -Target $linkTarget)
    try { Assert-Throws { Assert-AtlasRegularPath $junction } 'Junction muss vor Traversierung abgewiesen werden.' }
    finally { [IO.Directory]::Delete($junction) }
    $hardSource = Join-Path $testRoot 'hard-source.exe'; [IO.File]::WriteAllText($hardSource, 'not-a-Microsoft-runtime')
    $hardLink = Join-Path $testRoot 'hard-package.exe'
    [void](New-Item -ItemType HardLink -Path $hardLink -Target $hardSource)
    Assert-Throws { Assert-AtlasRegularPath $hardLink } 'Hardlinks fuer Paket- und Installationsdateien bleiben gesperrt.'
    Assert-Throws { Open-AtlasPathGuards -Path $hardLink -AllowMicrosoftRuntimeHardLink } 'Runtime-Ausnahme darf keine anderen Hardlink-Pfade freischalten.'
    $runtimeFixtureRoot = Join-Path $testRoot 'Microsoft/EdgeWebView/Application/1.2.3.4'
    [void][IO.Directory]::CreateDirectory($runtimeFixtureRoot)
    $runtimeHardLink = Join-Path $runtimeFixtureRoot 'msedgewebview2.exe'
    [void](New-Item -ItemType HardLink -Path $runtimeHardLink -Target $hardSource)
    Assert-Throws { Assert-AtlasRegularPath $runtimeHardLink } 'Runtime-Pfad alleine darf den normalen Pfadpruefer nicht lockern.'
    $runtimeGuards = Open-AtlasPathGuards -Path $runtimeHardLink -AllowMicrosoftRuntimeHardLink
    try { Assert-Test ($runtimeGuards.Count -gt 0) 'Explizite Runtime-Ausnahme muss native Handle-Sicherung behalten.' }
    finally { foreach ($guard in $runtimeGuards) { $guard.Dispose() } }

    $install = Get-AtlasLocalInstallDirectory; [void][IO.Directory]::CreateDirectory($install)
    foreach ($name in @('projectatlas-desktop.exe','projectatlas-cli.exe','uninstall.exe')) { [IO.File]::WriteAllText((Join-Path $install $name), "old-$name") }
    foreach ($path in Get-AtlasPreservedFilePaths) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path)); [IO.File]::WriteAllText($path, 'original-user-content') }
    $backup = New-AtlasInstallBackup -RunId 'test-run'
    Assert-AtlasRestoredBackup $backup
    Assert-Test $true 'Synthetische Sicherung ist vollstaendig.'
    [IO.File]::WriteAllText((Join-Path $install 'projectatlas-desktop.exe'), 'new-app')
    [IO.File]::WriteAllText((Join-Path $install 'extra.txt'), 'installer-extra')
    [IO.File]::WriteAllText((Get-AtlasLocalRegistryPath), 'modified-user-content')
    Restore-AtlasInstallBackup $backup
    Assert-AtlasRestoredBackup $backup
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $install 'extra.txt'))) 'Wiederherstellung muss neue Installerdateien entfernen.'
    Assert-Test (([IO.File]::ReadAllText((Get-AtlasLocalRegistryPath))) -ceq 'original-user-content') 'Wiederherstellung muss persoenliche Registry exakt bewahren.'

    foreach ($scenario in @('success','precheck','install','verify','receipt','restore')) {
        $events = [Collections.Generic.List[string]]::new()
        $ops = @{
            Revalidate={ $events.Add('precheck'); if ($scenario -eq 'precheck') { throw 'synthetic precheck' } }
            Install={ $events.Add('install'); if ($scenario -eq 'install') { throw 'synthetic install' } }
            Verify={ $events.Add('verify'); if ($scenario -in @('verify','restore')) { throw 'synthetic verify' } }
            Restore={ $events.Add('restore'); if ($scenario -eq 'restore') { throw 'synthetic restore' } }
            VerifyRestored={ $events.Add('restored') }
            WriteReceipt={ param($result); $events.Add("receipt:$result"); if ($scenario -eq 'receipt' -and $result -eq 'succeeded') { throw 'synthetic disk failure' } }
        }
        if ($scenario -eq 'success') {
            Invoke-AtlasLocalInstallTransaction $ops
            Assert-Test (($events -join ',') -ceq 'precheck,install,verify,receipt:succeeded') 'Erfolgsreihenfolge ist falsch.'
        } else {
            Assert-Throws { Invoke-AtlasLocalInstallTransaction $ops } "Szenario $scenario darf nicht erfolgreich sein."
            if ($scenario -eq 'precheck') { Assert-Test (-not $events.Contains('install') -and -not $events.Contains('restore')) 'Vorpruefungsfehler darf nicht mutieren.' }
            elseif ($scenario -eq 'restore') { Assert-Test ($events.Contains('receipt:failed-unresolved')) 'Fehlgeschlagener Rollback muss ungeklärt bleiben.' }
            else { Assert-Test ($events.Contains('restore') -and $events.Contains('restored') -and $events.Contains('receipt:failed-restored')) 'Jeder Installations-, Abnahme- oder Receiptfehler muss verifiziert zurueckkehren.' }
        }
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    foreach ($name in @('TAURI_SIGNING_PRIVATE_KEY','TAURI_SIGNING_PRIVATE_KEY_PATH','TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) { $start.Environment[$name] = 'test-only-secret' }
    Remove-AtlasSigningEnvironment $start
    Assert-Test (-not $start.Environment.ContainsKey('TAURI_SIGNING_PRIVATE_KEY') -and -not $start.Environment.ContainsKey('TAURI_SIGNING_PRIVATE_KEY_PATH') -and -not $start.Environment.ContainsKey('TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) 'Kindprozesse duerfen keine Tauri-Signiergeheimnisse erben.'
    Write-Host "ProjectAtlas-Desktop-Local-Install: PASS ($script:assertions Pruefungen; Signaturtrust, NSIS, GUI und Windows-Registry ausschliesslich synthetisch)."
} finally {
    Close-AtlasLocalPackage $package
    if ($certificate) { $certificate.Dispose() }
    if ($rsa) { $rsa.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'atlas-local-install-test-*') { throw 'Unsicherer Test-Cleanup-Pfad.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
