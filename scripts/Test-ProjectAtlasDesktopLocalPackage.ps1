#Requires -Version 7
# Schnelle Paketbau-Tests: keine echten Zertifikate, Schluessel, Downloads oder Installation.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Diese Tests pruefen den lokalen Windows-Paketbau und verlangen Windows.' }
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releasePath = Join-Path $repositoryRoot '.github/scripts/invoke-desktop-release.ps1'
$capturePath = Join-Path $repositoryRoot '.github/scripts/Capture-ProjectAtlasLocalPayload.ps1'
$helperPath = Join-Path $repositoryRoot '.github/scripts/ProjectAtlasLocalPackage.ps1'
$pwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$testCommit = 'a' * 40

function Assert-TestRejected {
    param([scriptblock]$Action, [string]$ExpectedMessage, [string]$Scenario)
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") { return }
        throw "${Scenario}: Unerwarteter Fehler: $($_.Exception.Message)"
    }
    throw "${Scenario}: Der unzulaessige Fall wurde akzeptiert."
}

function Get-TestDefinition {
    param($Ast, [string]$Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Testfunktion nicht eindeutig: $Name" }
    return $definitions[0].Extent.Text
}

function Invoke-TestChild {
    param([string]$FilePath, [string[]]$Arguments, [switch]$WithoutTools)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    if ($WithoutTools) { $start.Environment['PATH'] = '' }
    foreach ($name in @('TAURI_SIGNING_PRIVATE_KEY', 'TAURI_SIGNING_PRIVATE_KEY_PATH',
            'TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT',
            'PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL')) {
        [void]$start.Environment.Remove($name)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Test-Kindprozess konnte nicht gestartet werden.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'Test-Kindprozess hat das Zeitlimit ueberschritten.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

# Echte Einstiegspunkte mit leerem PATH: Fehler muessen vor Cargo, Git und SignTool entstehen.
foreach ($invalidSwitch in @('-Publish', '-SkipSidecar', '-AllowUnsignedUpdater', '-AllowUnsigned')) {
    $result = Invoke-TestChild -FilePath $pwshPath -WithoutTools -Arguments @(
        '-NoProfile', '-File', $releasePath, '-PrepareLocalPackage', '-ExpectedCommit', $testCommit, $invalidSwitch)
    if ($result.ExitCode -eq 0 -or $result.Output -notlike '*nicht mit*') {
        throw "Lokaler Paketbau blockiert $invalidSwitch nicht vor dem Werkzeugzugriff: $($result.Output)"
    }
}
$result = Invoke-TestChild -FilePath $pwshPath -WithoutTools -Arguments @(
    '-NoProfile', '-File', $releasePath, '-PrepareLocalPackage')
if ($result.ExitCode -eq 0 -or $result.Output -notlike '*verlangt einen exakten -ExpectedCommit*') {
    throw "Lokaler Paketbau akzeptiert fehlenden Quellcommit oder greift vorher auf Werkzeuge zu: $($result.Output)"
}
$result = Invoke-TestChild -FilePath $pwshPath -WithoutTools -Arguments @(
    '-NoProfile', '-File', $releasePath, '-Publish', '-NotesFile', (Join-Path $repositoryRoot 'RELEASE_NOTES.md'))
if ($result.ExitCode -eq 0 -or $result.Output -notlike '*verpflichtende zweiphasige Clean-Windows-Attestierung*') {
    throw "Die oeffentliche Publish-Sperre wurde veraendert: $($result.Output)"
}

$tokens = $null
$errors = $null
$releaseAst = [Management.Automation.Language.Parser]::ParseFile($releasePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Der Release-Wrapper kann fuer den Pakettest nicht geparst werden.' }

# Mehrere Anwendungen mit gleichem Namen muessen genau den ersten PATH-Treffer
# ergeben. Die synthetischen Treffer veraendern weder PATH noch echte Programme.
& {
    . ([scriptblock]::Create((Get-TestDefinition -Ast $releaseAst -Name 'Assert-Tool')))
    & {
        $script:toolMatches = @()
        function Get-Command {
            [CmdletBinding()]
            param([string]$Name, [Management.Automation.CommandTypes]$CommandType)
            if ($Name -cne 'pwsh-test' -or $CommandType -ne [Management.Automation.CommandTypes]::Application) {
                throw 'Die Werkzeugaufloesung muss ausschliesslich die angeforderte Anwendung suchen.'
            }
            $script:toolMatches
        }
        Assert-TestRejected -Action { Assert-Tool -Name 'pwsh-test' -Hint 'Testhinweis' } `
            -ExpectedMessage 'Benoetigtes Werkzeug fehlt im PATH: pwsh-test. Testhinweis' -Scenario 'Kein Anwendungstreffer'
        $firstPath = 'C:\synthetische-tools\erster\pwsh.exe'
        $secondPath = 'C:\synthetische-tools\zweiter\pwsh.exe'
        foreach ($count in @(1, 2)) {
            $script:toolMatches = @([pscustomobject]@{ Source = $firstPath })
            if ($count -eq 2) { $script:toolMatches += [pscustomobject]@{ Source = $secondPath } }
            $resolved = Assert-Tool -Name 'pwsh-test' -Hint 'Testhinweis'
            if ($resolved -isnot [string] -or $resolved -cne $firstPath) {
                throw "Die Werkzeugaufloesung liefert bei $count Treffern nicht genau den ersten Anwendungspfad als String."
            }
        }
    }
    $resolvedPwsh = Assert-Tool -Name 'pwsh' -Hint 'PowerShell ist fuer den lokalen Test erforderlich.'
    if ($resolvedPwsh -isnot [string] -or $resolvedPwsh -cne $pwshPath) {
        throw 'Die echte lokale PowerShell-Aufloesung liefert nicht genau den ersten Anwendungspfad als String.'
    }
}

# Nur die Betriebssystemgrenze der Zertifikatskette wird ersetzt. Die komplette
# Auswahl-, URL- und Vertrauenslogik der echten Funktion bleibt Bestandteil des Tests.
& {
    . ([scriptblock]::Create((Get-TestDefinition -Ast $releaseAst -Name 'Get-NormalizedCertificateThumbprint')))
    $resolveText = Get-TestDefinition -Ast $releaseAst -Name 'Resolve-AuthenticodeConfiguration'
    $chainConstructor = '[Security.Cryptography.X509Certificates.X509Chain]::new()'
    if ([regex]::Matches($resolveText, [regex]::Escape($chainConstructor)).Count -ne 1) {
        throw 'Die Zertifikatsketten-Grenze des Tests muss nach der Produktionsaenderung neu geprueft werden.'
    }
    . ([scriptblock]::Create($resolveText.Replace($chainConstructor, '(New-TestCertificateChain)')))
    $script:localChainTrusted = $true
    $script:chainChecks = 0
    $script:certificateReads = 0
    $script:fakeCertificate = [pscustomobject]@{
        HasPrivateKey = $true; NotBefore = [DateTime]::UtcNow.AddDays(-1)
        NotAfter = [DateTime]::UtcNow.AddDays(1); Subject = 'CN=synthetischer Test'; Issuer = 'CN=synthetischer Test'
    }
    function Get-Item {
        [CmdletBinding()]
        param([string]$LiteralPath)
        if ($LiteralPath -cne "Cert:\CurrentUser\My\$('A' * 40)") { throw 'Unerwarteter Zertifikatszugriff im Test.' }
        $script:certificateReads++
        return $script:fakeCertificate
    }
    function Test-CodeSigningCertificateUsage { param($Certificate) return $true }
    function Resolve-WindowsSignTool { return 'synthetisches-signtool.exe' }
    function New-TestCertificateChain {
        $chain = [pscustomobject]@{}
        $chain | Add-Member -MemberType ScriptMethod -Name Build -Value {
            param($Certificate)
            $script:chainChecks++
            return $script:localChainTrusted
        }
        $chain | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $chain
    }
    $environmentNames = @('PROJECTATLAS_AUTHENTICODE_CERTIFICATE_THUMBPRINT',
        'PROJECTATLAS_AUTHENTICODE_TIMESTAMP_URL', 'TAURI_WINDOWS_SIGNTOOL_PATH')
    $savedEnvironment = @{}
    foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable($environmentNames[0], ('A' * 40), 'Process')
        [Environment]::SetEnvironmentVariable($environmentNames[1], 'https://timestamp.example.test/', 'Process')
        Assert-TestRejected -Action { Resolve-AuthenticodeConfiguration -Required } -ExpectedMessage 'selbstsigniertes' -Scenario 'Selbstsignierter oeffentlicher Herausgeber'
        $configuration = Resolve-AuthenticodeConfiguration -Required -LocalTrustOnly
        if ($configuration.Thumbprint -cne ('A' * 40) -or $script:chainChecks -ne 1) {
            throw 'Der lokale Herausgeber wurde nicht ueber die vorhandene Vertrauenskette geprueft.'
        }
        $script:localChainTrusted = $false
        Assert-TestRejected -Action { Resolve-AuthenticodeConfiguration -Required -LocalTrustOnly } -ExpectedMessage 'nicht bereits vertrauenswuerdig' -Scenario 'Lokal nicht vertrauenswuerdiger Herausgeber'
        $script:localChainTrusted = $true
        [Environment]::SetEnvironmentVariable($environmentNames[1], 'http://timestamp.digicert.com/', 'Process')
        $configuration = Resolve-AuthenticodeConfiguration -Required -LocalTrustOnly
        if ($configuration.TimestampUrl -cne 'http://timestamp.digicert.com/') { throw 'Der erlaubte lokale Zeitstempel-Endpunkt wurde nicht beibehalten.' }
        Assert-TestRejected -Action { Resolve-AuthenticodeConfiguration -Required } -ExpectedMessage 'Zeitstempeladresse nicht zugelassen' -Scenario 'HTTP-Zeitstempel im oeffentlichen Modus'
        foreach ($url in @('http://timestamp.digicert.com.evil.test/', 'http://evil.test/',
                'http://timestamp.digicert.com:8080/', 'http://timestamp.digicert.com/other',
                'http://timestamp.digicert.com/?next=1', 'http://timestamp.digicert.com/#other',
                'http://user@timestamp.digicert.com/', 'ftp://timestamp.digicert.com/')) {
            [Environment]::SetEnvironmentVariable($environmentNames[1], $url, 'Process')
            $readsBefore = $script:certificateReads
            Assert-TestRejected -Action { Resolve-AuthenticodeConfiguration -Required -LocalTrustOnly } -ExpectedMessage 'Zeitstempeladresse' -Scenario "Unzulaessiger lokaler Endpunkt $url"
            if ($script:certificateReads -ne $readsBefore) { throw 'Ein unzulaessiger Endpunkt wurde erst nach Zertifikatszugriff blockiert.' }
        }
    }
    finally {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    }
}

# Git wird vollstaendig simuliert; keine Netzwerkabfrage oder Aenderung eines Checkouts.
& {
    . $helperPath
    $script:gitScenario = 'valid'
    $script:gitCalls = [Collections.Generic.List[string]]::new()
    function Invoke-AtlasLocalBuildGit {
        param([string]$Root, [string[]]$Arguments)
        $command = $Arguments -join ' '
        $script:gitCalls.Add($command)
        switch ($command) {
            'rev-parse HEAD' { if ($script:gitScenario -eq 'head') { return ('b' * 40) }; return $testCommit }
            'status --porcelain --untracked-files=all' { if ($script:gitScenario -eq 'dirty') { return '?? fremde-arbeit.txt' }; return }
            'branch --show-current' { if ($script:gitScenario -eq 'branch') { return 'feature/test' }; return 'main' }
            'fetch origin main:refs/remotes/origin/main --no-tags' { if ($script:gitScenario -eq 'fetch') { throw 'Git-Pruefung fuer das lokale Paket ist fehlgeschlagen.' }; return }
            'rev-parse refs/remotes/origin/main' { if ($script:gitScenario -eq 'remote-head') { return ('b' * 40) }; return $testCommit }
            'remote get-url origin' { if ($script:gitScenario -eq 'remote') { return 'https://github.com/other/projectatlas-desktop' }; return 'https://github.com/einzigTimo/projectatlas-desktop.git' }
            default { throw "Unerwarteter Git-Aufruf im Test: $command" }
        }
    }
    Assert-AtlasLocalBuildSource -Root 'synthetischer-root' -ExpectedCommit $testCommit
    if (-not $script:gitCalls.Contains('fetch origin main:refs/remotes/origin/main --no-tags')) { throw 'origin/main wurde nicht aktuell und explizit abgefragt.' }
    foreach ($case in @(
            @{ Mode = 'head'; Message = 'Quellcommit' }, @{ Mode = 'dirty'; Message = 'sauberen Quellstand' },
            @{ Mode = 'branch'; Message = 'aus main' }, @{ Mode = 'fetch'; Message = 'Git-Pruefung' },
            @{ Mode = 'remote-head'; Message = 'origin/main-Commit' }, @{ Mode = 'remote'; Message = 'Quellrepository' })) {
        $script:gitScenario = $case.Mode
        Assert-TestRejected -Action { Assert-AtlasLocalBuildSource -Root 'synthetischer-root' -ExpectedCommit $testCommit } -ExpectedMessage $case.Message -Scenario "Quellbindung $($case.Mode)"
    }
    $script:gitCalls.Clear()
    Assert-TestRejected -Action { Complete-AtlasLocalPackageBuild -ExpectedCommit 'ungueltig' } -ExpectedMessage 'Ungueltiger Paket-Quellcommit' -Scenario 'Paketabschluss ohne Quellbindung'
    if ($script:gitCalls.Count -ne 0) { throw 'Ein ungueltiger Paketabschluss fuehrt bereits Git aus.' }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('atlas-local-package-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$savedLocalAppData = $env:LOCALAPPDATA
$nsisCandidates = @((Join-Path $savedLocalAppData 'tauri/NSIS/makensis.exe'))
$nsisCommand = Get-Command makensis -CommandType Application -ErrorAction SilentlyContinue
if ($null -ne $nsisCommand) { $nsisCandidates += $nsisCommand.Source }
try {
    $source = Join-Path $testRoot 'synthetische-quelle.bin'
    $destination = Join-Path $testRoot 'synthetische-kopie.bin'
    [byte[]]$payload = 0, 1, 2, 13, 10, 127, 128, 255
    [IO.File]::WriteAllBytes($source, $payload)
    & $capturePath -SourcePath $source -DestinationPath $destination
    if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) { throw 'Der Compile-Hook kopiert Payloadbytes nicht exakt.' }
    [IO.File]::WriteAllBytes($source, [byte[]]@(99, 100))
    Assert-TestRejected -Action { & $capturePath -SourcePath $source -DestinationPath $destination } -ExpectedMessage 'already exists' -Scenario 'Compile-Hook darf vorhandenes Ziel nicht ersetzen'
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -cne [Convert]::ToBase64String($payload)) { throw 'Der Compile-Hook hat ein vorhandenes Ziel veraendert.' }

    & {
        . $helperPath
        $env:LOCALAPPDATA = Join-Path $testRoot 'local-app-data'
        $fakeRoot = Join-Path $testRoot 'synthetischer-checkout'
        $binaryDirectory = Join-Path $fakeRoot 'target/release'
        [void][IO.Directory]::CreateDirectory($binaryDirectory)
        [IO.File]::WriteAllBytes((Join-Path $binaryDirectory 'projectatlas-desktop.exe'), $payload)
        $build = New-AtlasLocalPackageBuild -Root $fakeRoot -ExpectedCommit $testCommit
        if (-not (Test-Path -LiteralPath $build.HookPath -PathType Leaf) -or (Test-Path -LiteralPath $build.FinalDirectory)) {
            throw 'Der Paketbau erzeugt keinen Hook oder legt vorzeitig ein fertiges Paket an.'
        }
        $nsis = @($nsisCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
        if ($nsis.Count -eq 1) {
            $probePath = Join-Path $testRoot 'compile-probe.nsi'
            $outputPath = Join-Path $testRoot 'niemals-ausfuehren.exe'
            $probe = @(('!include "{0}"' -f $build.HookPath), 'Name "Paket-Hook-Test"',
                ('OutFile "{0}"' -f $outputPath), 'Section', 'SectionEnd') -join "`r`n"
            Write-AtlasLocalNewText -Path $probePath -Text $probe
            $result = Invoke-TestChild -FilePath $nsis[0] -Arguments @('/V2', $probePath)
            if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $build.MainPath -PathType Leaf)) {
                throw "NSIS kann den echten Capture-Hook nicht kompilieren: $($result.Output)"
            }
            if ((Get-FileHash -LiteralPath $build.MainPath).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) { throw 'Der NSIS-Hook erfasst andere Payloadbytes.' }
        }
        else { Write-Host 'NSIS-Compile-Probe: SKIP (kein lokaler Compiler; kein Download).' }
        [void][IO.Directory]::CreateDirectory($build.FinalDirectory)
        Assert-TestRejected -Action { New-AtlasLocalPackageBuild -Root $fakeRoot -ExpectedCommit $testCommit } -ExpectedMessage 'existiert bereits ein Paket' -Scenario 'Vorhandenes Paket nicht ersetzen'
    }
}
finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($fullTestRoot) -cne $tempParent -or
        [IO.Path]::GetFileName($fullTestRoot) -notmatch '^atlas-local-package-test-[a-f0-9]{32}$') {
        throw 'Unsicheres Cleanup-Ziel des Pakettests wurde blockiert.'
    }
    Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
}
Write-Host 'ProjectAtlas-Desktop-Local-Package: PASS' -ForegroundColor Green
