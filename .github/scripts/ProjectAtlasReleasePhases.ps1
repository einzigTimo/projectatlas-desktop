#Requires -Version 7
<#
.SYNOPSIS
    Gemeinsame Bausteine des zweiphasigen ProjectAtlas-Desktop-Releases.

.DESCRIPTION
    Wird von .github/scripts/invoke-desktop-release.ps1 und
    scripts/Invoke-ProjectAtlasDesktopCleanWindowsAttestation.ps1 dot-gesourct.

    Ablauf eines produktiven Releases (jede Phase in einem eigenen pwsh-Prozess):
      1. Draft   - baut, laedt in einen PRIVATEN GitHub-Draft ohne Git-Tag hoch und
                   schreibt ein Draft-State-JSON ausserhalb des Repositories.
      2. Attest  - laedt die Assets per Asset-ID aus dem privaten Draft, installiert sie in
                   einer frischen Windows Sandbox und schreibt eine Attestierung, die an den
                   SHA-256 des Draft-State gebunden ist.
      3. Promote - veroeffentlicht nur mit frischer, exakt passender Attestierung und nach
                   erneuter vollstaendiger Remote-Verifikation desselben Drafts.

    Zeitbindung: Das Zentrale-Preflight (max. 12 Minuten) wird ausschliesslich beim Start
    der Draft-Phase geprueft. Danach gilt eine daraus abgeleitete, strikt begrenzte
    Laufbindung (Run-Deadline), deren Gueltigkeit jede Folgephase erneut prueft. Commit-,
    Quell-, Arbeitsbaum- und Artefaktdrift blockieren weiterhin in jeder Phase.

    Diese Datei enthaelt keine Seiteneffekte beim Dot-Sourcing.
#>

function Get-ReleasePhasePolicy {
    return [pscustomobject]@{
        DraftStateSchema            = 'projectatlas.desktop.release-draft-state.v1'
        AttestationSchema           = 'projectatlas.desktop.clean-windows-attestation.v1'
        SandboxExpectationSchema    = 'projectatlas.desktop.sandbox-expectation.v1'
        SandboxResultSchema         = 'projectatlas.desktop.sandbox-result.v1'
        CanonicalReleaseRepository  = 'einzigTimo/projectatlas-desktop-releases'
        CanonicalSourceRepository   = 'einzigTimo/projectatlas-desktop'
        # Gesamtbudget ab Preflight-Pruefung bis zum Beginn der Promotion.
        RunBudgetMinutes            = 180
        # Frist, innerhalb derer ein Draft attestiert werden muss.
        DraftStateValidityMinutes   = 120
        # Frist, innerhalb derer eine Attestierung zur Promotion fuehren muss.
        AttestationValidityMinutes  = 30
        ClockSkewMinutes            = 2
    }
}

function New-NativeProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $false)]
        [switch]$RedirectOutput
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        $start.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    if ($RedirectOutput) {
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
    }

    # Normale Build-, Test-, Git- und GitHub-Prozesse duerfen den privaten
    # Tauri-Updater-Schluessel auch dann nicht erben, wenn er im aufrufenden
    # Controller-Prozess vorhanden ist. Nur Invoke-TauriBundle setzt ihn in der
    # isolierten Umgebung genau eines Paketierungsprozesses wieder ein.
    foreach ($secretName in @(
            'TAURI_SIGNING_PRIVATE_KEY',
            'TAURI_SIGNING_PRIVATE_KEY_PATH',
            'TAURI_SIGNING_PRIVATE_KEY_PASSWORD')) {
        [void]$start.Environment.Remove($secretName)
    }
    return $start
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory
    )

    $startArguments = @{
        FilePath  = $FilePath
        Arguments = $Arguments
    }
    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        $startArguments.WorkingDirectory = $WorkingDirectory
    }
    $start = New-NativeProcessStartInfo @startArguments
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Prozess konnte nicht gestartet werden: $FilePath"
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        throw "Aufruf fehlgeschlagen (Exitcode $exitCode): $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory
    )

    $startArguments = @{
        FilePath       = $FilePath
        Arguments      = $Arguments
        RedirectOutput = $true
    }
    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        $startArguments.WorkingDirectory = $WorkingDirectory
    }
    $start = New-NativeProcessStartInfo @startArguments
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Prozess konnte nicht gestartet werden: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        # stderr wird absichtlich nur geleert, aber nie mit dem Rueckgabestrom
        # vermischt. JSON-, Hash- und --jq-Aufrufer erhalten dadurch auch bei
        # erfolgreichen Warnungen oder Progressmeldungen ausschliesslich stdout.
        [void]$stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        throw "Aufruf fehlgeschlagen (Exitcode $exitCode): $FilePath $($Arguments -join ' ')"
    }
    return $stdout.Trim()
}

function Save-NativeBinaryOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        throw "Binaeres Downloadziel existiert bereits und wird nie ueberschrieben: $Destination"
    }
    $start = New-NativeProcessStartInfo -FilePath $FilePath -Arguments $Arguments -RedirectOutput
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $exitCode = -1
    try {
        if (-not $process.Start()) {
            throw "Prozess konnte nicht gestartet werden: $FilePath"
        }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.FileStream]::new($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $process.StandardOutput.BaseStream.CopyTo($stream)
        }
        finally {
            $stream.Dispose()
        }
        $process.WaitForExit()
        [void]$stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force
        }
        throw "Binaerer Download fehlgeschlagen (Exitcode $exitCode): $FilePath"
    }
}

function Get-ReleaseTagCommit {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag
    )

    $directRef = "refs/tags/$ReleaseTag"
    $peeledRef = "$directRef^{}"
    $remoteUrl = "https://github.com/$ReleaseRepository.git"
    $rawRefs = Invoke-NativeCapture -FilePath 'git' -Arguments @(
        'ls-remote', '--tags', $remoteUrl, $directRef, $peeledRef
    )
    if ([string]::IsNullOrWhiteSpace($rawRefs)) {
        return $null
    }

    $refs = @($rawRefs -split "`r?`n" | ForEach-Object {
            if ($_ -notmatch '^(?<sha>[0-9a-f]{40})\s+(?<ref>refs/tags/.+)$') {
                throw "Unerwartete Tag-Antwort des Release-Repositories: $_"
            }
            [pscustomobject]@{ Sha = $Matches.sha; Ref = $Matches.ref }
        })
    $directMatches = @($refs | Where-Object { $_.Ref -ceq $directRef })
    $peeledMatches = @($refs | Where-Object { $_.Ref -ceq $peeledRef })
    if ($directMatches.Count -ne 1 -or $peeledMatches.Count -gt 1 -or
        $refs.Count -ne ($directMatches.Count + $peeledMatches.Count)) {
        throw "Release-Tag $ReleaseTag konnte nicht eindeutig aufgeloest werden."
    }

    # ^{} wird von Git rekursiv bis zum Nicht-Tag-Objekt aufgeloest. Der API-Aufruf
    # stellt danach sicher, dass dieses Objekt tatsaechlich ein Commit ist.
    $candidateCommit = if ($peeledMatches.Count -eq 1) {
        [string]$peeledMatches[0].Sha
    }
    else {
        [string]$directMatches[0].Sha
    }
    $confirmedCommit = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com',
        "repos/$ReleaseRepository/git/commits/$candidateCommit",
        '--jq', '.sha'
    )
    if ($confirmedCommit -ne $candidateCommit) {
        throw "Release-Tag $ReleaseTag zeigt nicht eindeutig auf einen Commit."
    }
    return $confirmedCommit
}

function ConvertFrom-GitHubReleaseApi {
    param(
        [Parameter(Mandatory = $true)][string]$Json
    )

    $raw = $Json | ConvertFrom-Json -Depth 20
    $assets = [Collections.Generic.List[object]]::new()
    foreach ($asset in @($raw.assets)) {
        if ($null -eq $asset) { continue }
        $digestProperty = $asset.PSObject.Properties['digest']
        $assets.Add([pscustomobject]@{
                id     = [string]$asset.id
                name   = [string]$asset.name
                size   = [Int64]$asset.size
                digest = if ($null -ne $digestProperty) { [string]$digestProperty.Value } else { '' }
                url    = [string]$asset.browser_download_url
            })
    }
    $immutableProperty = $raw.PSObject.Properties['immutable']
    return [pscustomobject]@{
        databaseId      = [string]$raw.id
        tagName         = [string]$raw.tag_name
        targetCommitish = [string]$raw.target_commitish
        isDraft         = [bool]$raw.draft
        isImmutable     = if ($null -ne $immutableProperty) { [bool]$immutableProperty.Value } else { $false }
        publishedAt     = [string]$raw.published_at
        assets          = $assets.ToArray()
    }
}

function Get-GitHubReleaseById {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{1,20}$')][string]$ReleaseId
    )

    $json = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com',
        "repos/$ReleaseRepository/releases/$ReleaseId"
    )
    $state = ConvertFrom-GitHubReleaseApi -Json $json
    if ($state.databaseId -ne $ReleaseId) {
        throw "GitHub lieferte fuer Release-ID $ReleaseId eine andere Identitaet."
    }
    return $state
}

function Get-GitHubReleaseIdsByTag {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag
    )

    # Drafts besitzen vor der Veroeffentlichung keinen Git-Tag und sind ueber
    # releases/tags/<tag> nicht auffindbar. Deshalb wird die vollstaendige Liste
    # (inklusive privater Drafts) gelesen und exakt nach tag_name gefiltert.
    $lines = Invoke-NativeCapture -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com', '--paginate',
        "repos/$ReleaseRepository/releases?per_page=100",
        '--jq', '.[] | [(.id|tostring), .tag_name, (.draft|tostring)] | @tsv'
    )
    $result = [Collections.Generic.List[object]]::new()
    foreach ($line in @($lines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split("`t")
        if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[0-9]{1,20}$' -or $parts[2] -notin @('true', 'false')) {
            throw "Unerwartete Release-Liste des Release-Repositories: $line"
        }
        if ($parts[1] -ceq $ReleaseTag) {
            $result.Add([pscustomobject]@{ Id = $parts[0]; IsDraft = ($parts[2] -eq 'true') })
        }
    }
    return $result.ToArray()
}

function Save-GitHubReleaseAssetById {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{1,20}$')][string]$AssetId,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Save-NativeBinaryOutput -FilePath $GhPath -Destination $Destination -Arguments @(
        'api', '--hostname', 'github.com',
        '-H', 'Accept: application/octet-stream',
        "repos/$ReleaseRepository/releases/assets/$AssetId"
    )
}

function Assert-GitHubReleaseState {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$ExpectedDatabaseId,
        [Parameter(Mandatory = $true)][string]$ExpectedTag,
        [Parameter(Mandatory = $true)][string]$ExpectedTargetCommit,
        [Parameter(Mandatory = $true)][bool]$ExpectedDraft,
        [Parameter(Mandatory = $true)][object[]]$ExpectedAssets,
        [switch]$RequireImmutable
    )

    if ([string]$State.databaseId -ne $ExpectedDatabaseId -or
        [string]$State.tagName -cne $ExpectedTag -or
        [string]$State.targetCommitish -ne $ExpectedTargetCommit -or
        [bool]$State.isDraft -ne $ExpectedDraft) {
        throw "Release $ExpectedTag hat seine gebundene Identitaet oder seinen erwarteten Draft-Status veraendert."
    }
    if (-not $ExpectedDraft -and [string]::IsNullOrWhiteSpace([string]$State.publishedAt)) {
        throw "Release $ExpectedTag besitzt trotz Veroeffentlichung keinen Live-Zeitpunkt."
    }
    if ($RequireImmutable -and -not [bool]$State.isImmutable) {
        throw "Release $ExpectedTag ist veroeffentlicht, aber GitHub schuetzt Tag und Assets nicht unveraenderlich."
    }

    $duplicateExpectations = @($ExpectedAssets | Group-Object -Property Name | Where-Object { $_.Count -ne 1 })
    $actualAssets = @($State.assets)
    if ($duplicateExpectations.Count -gt 0 -or $actualAssets.Count -ne $ExpectedAssets.Count) {
        throw "Release $ExpectedTag besitzt kein eindeutiges erwartetes Asset-Inventar."
    }
    foreach ($expectedAsset in $ExpectedAssets) {
        $assetMatches = @($actualAssets | Where-Object { [string]$_.name -ceq [string]$expectedAsset.Name })
        if ($assetMatches.Count -ne 1 -or [Int64]$assetMatches[0].size -ne [Int64]$expectedAsset.Length) {
            throw "Release-Asset $($expectedAsset.Name) fehlt, ist doppelt oder hat eine unerwartete Groesse."
        }
        $digestProperty = $assetMatches[0].PSObject.Properties['digest']
        $actualDigest = if ($null -ne $digestProperty) {
            [string]$digestProperty.Value
        }
        else {
            ''
        }
        $expectedDigest = "sha256:$([string]$expectedAsset.Sha256)".ToLowerInvariant()
        if ($actualDigest -notmatch '^sha256:[0-9a-fA-F]{64}$' -or
            $actualDigest.ToLowerInvariant() -ne $expectedDigest) {
            throw "GitHub-Digest fuer $($expectedAsset.Name) fehlt oder stimmt nicht mit dem lokal geprueften SHA-256 ueberein."
        }
        $expectedIdProperty = $expectedAsset.PSObject.Properties['AssetId']
        if ($null -ne $expectedIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$expectedIdProperty.Value)) {
            $actualIdProperty = $assetMatches[0].PSObject.Properties['id']
            if ($null -eq $actualIdProperty -or [string]$actualIdProperty.Value -ne [string]$expectedIdProperty.Value) {
                throw "Release-Asset $($expectedAsset.Name) besitzt nicht mehr die gebundene GitHub-Asset-ID."
            }
        }
    }
}

function Get-ReleaseDownloadUrl {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    if ($ReleaseRepository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or
        $ReleaseTag -notmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$' -or
        $AssetName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$') {
        throw 'Die oeffentliche Download-Adresse kann nicht sicher gebildet werden.'
    }
    # Drafts liefern "untagged-..."-Adressen. Das Manifest muss aber die spaetere
    # oeffentliche Adresse enthalten. Die Promotion vergleicht sie danach exakt mit
    # der von GitHub gemeldeten browser_download_url des veroeffentlichten Assets.
    return "https://github.com/$ReleaseRepository/releases/download/$ReleaseTag/$AssetName"
}

function Get-ReleaseRunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$RunId
    )

    if ($RunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Release-Lauf-ID ist ungueltig.'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA fehlt; der Release-Laufzustand kann nicht ausserhalb des Repositories abgelegt werden.'
    }
    $base = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ProjectAtlas\desktop-release-runs'))
    return (Join-Path $base $RunId)
}

function Write-ReleasePhaseDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Document
    )

    $json = $Document | ConvertTo-Json -Depth 12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-BoundReleasePhaseDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Label ist nicht an einen gueltigen SHA-256 gebunden."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label fehlt: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1MB) {
        throw "$Label ist kein regulaeres, begrenztes Dokument."
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Label wurde nach seiner Bindung veraendert oder ausgetauscht."
    }
    try {
        $document = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 20 -DateKind String
    }
    catch {
        throw "$Label ist kein gueltiges JSON."
    }
    return $document
}

function ConvertTo-ReleasePhaseUtc {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Get-ReleasePhaseProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-ReleaseDraftStateDocument {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$State,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NowUtc,

        # Die Promotion darf nach dem Attestierungsfenster des Drafts laufen; ihre eigene
        # Frist bindet Test-ReleasePromotionAuthorization.
        [switch]$ForPromotion
    )

    $policy = Get-ReleasePhasePolicy
    $problems = [Collections.Generic.List[string]]::new()
    if ($null -eq $State) {
        $problems.Add('Draft-State fehlt')
        return $problems.ToArray()
    }
    $get = { param($name) Get-ReleasePhaseProperty -Object $State -Name $name }

    if ([string](& $get 'schema_version') -cne $policy.DraftStateSchema) { $problems.Add('unbekanntes Draft-State-Schema') }
    if ([string](& $get 'run_id') -cne $RunId) { $problems.Add('Draft-State gehoert zu einem anderen Release-Lauf') }
    $version = [string](& $get 'version')
    if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { $problems.Add('Version fehlt oder ist ungueltig') }
    if ([string](& $get 'release_tag') -cne "v$version") { $problems.Add('Release-Tag passt nicht zur Version') }
    if ([string](& $get 'release_repository') -cne $policy.CanonicalReleaseRepository) { $problems.Add('falsches Release-Repository') }
    if ([string](& $get 'source_repository') -cne $policy.CanonicalSourceRepository) { $problems.Add('falsches Quell-Repository') }
    if ([string](& $get 'release_id') -notmatch '^[0-9]{1,20}$') { $problems.Add('Draft-ID fehlt') }
    foreach ($commitField in @('release_repository_commit', 'source_commit')) {
        if ([string](& $get $commitField) -cnotmatch '^[0-9a-f]{40}$') { $problems.Add("$commitField ist keine vollstaendige Git-ID") }
    }
    foreach ($hashField in @('preflight_artifact_sha256', 'source_tree_sha256', 'cargo_sha256', 'signature_verifier_sha256', 'tauri_config_sha256')) {
        if ([string](& $get $hashField) -notmatch '^[0-9a-fA-F]{64}$') { $problems.Add("$hashField fehlt") }
    }
    if ([string](& $get 'authenticode_certificate_thumbprint') -cnotmatch '^[0-9A-F]{40}$') { $problems.Add('Authenticode-Thumbprint fehlt') }

    $assets = @(& $get 'assets')
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($assets.Count -eq 0 -or $null -eq $assets[0]) {
        $problems.Add('Asset-Inventar fehlt')
    }
    else {
        foreach ($asset in $assets) {
            $name = [string](Get-ReleasePhaseProperty -Object $asset -Name 'name')
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or -not $names.Add($name)) {
                $problems.Add("Assetname ungueltig oder doppelt: $name")
            }
            if ([string](Get-ReleasePhaseProperty -Object $asset -Name 'sha256') -cnotmatch '^[0-9a-f]{64}$') { $problems.Add("SHA-256 fehlt fuer $name") }
            if ([string](Get-ReleasePhaseProperty -Object $asset -Name 'asset_id') -notmatch '^[0-9]{1,20}$') { $problems.Add("Asset-ID fehlt fuer $name") }
            $size = Get-ReleasePhaseProperty -Object $asset -Name 'size'
            if ($null -eq $size -or [Int64]$size -le 0) { $problems.Add("Groesse fehlt fuer $name") }
        }
    }
    $installerName = [string](& $get 'updater_installer_name')
    $signatureName = [string](& $get 'updater_signature_name')
    foreach ($requiredName in @($installerName, $signatureName, 'latest.json', "projectatlas-desktop-v$version.provenance.json")) {
        if ([string]::IsNullOrWhiteSpace($requiredName) -or -not $names.Contains($requiredName)) {
            $problems.Add("Pflicht-Asset fehlt im Draft-State: $requiredName")
        }
    }
    if ($signatureName -cne "$installerName.sig") { $problems.Add('Updater-Signatur gehoert nicht zum Installer') }

    $created = ConvertTo-ReleasePhaseUtc (& $get 'created_at_utc')
    $preflightVerified = ConvertTo-ReleasePhaseUtc (& $get 'preflight_verified_at_utc')
    $runDeadline = ConvertTo-ReleasePhaseUtc (& $get 'run_deadline_utc')
    $expires = ConvertTo-ReleasePhaseUtc (& $get 'expires_at_utc')
    if ($null -eq $created -or $null -eq $preflightVerified -or $null -eq $runDeadline -or $null -eq $expires) {
        $problems.Add('Zeitbindung des Draft-State unvollstaendig')
    }
    else {
        $skew = [TimeSpan]::FromMinutes($policy.ClockSkewMinutes)
        if ($preflightVerified -gt $created -or $created -gt $NowUtc.Add($skew)) { $problems.Add('Zeitbindung des Draft-State ist unplausibel') }
        if ($runDeadline -gt $preflightVerified.AddMinutes($policy.RunBudgetMinutes)) { $problems.Add('Laufbindung ueberschreitet das zulaessige Gesamtbudget') }
        if ($expires -gt $created.AddMinutes($policy.DraftStateValidityMinutes) -or $expires -gt $runDeadline) { $problems.Add('Draft-State-Ablauf ueberschreitet die zulaessige Frist') }
        if (-not $ForPromotion -and $NowUtc -ge $expires) { $problems.Add('Draft-State ist abgelaufen') }
        if ($NowUtc -ge $runDeadline) { $problems.Add('Laufbindung ist abgelaufen') }
    }
    return $problems.ToArray()
}

function Get-ReleaseVersionCore {
    param([Parameter(Mandatory = $true)][string]$Version)

    if ($Version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)') {
        throw 'Version ist nicht SemVer-konform.'
    }
    return [pscustomobject]@{
        Major = [int]$Matches.major
        Minor = [int]$Matches.minor
        Patch = [int]$Matches.patch
        Text  = "$([int]$Matches.major).$([int]$Matches.minor).$([int]$Matches.patch)"
    }
}

function Test-SandboxBinaryEvidence {
    param(
        [AllowNull()][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$ExpectedThumbprint,
        [AllowEmptyString()][string]$ExpectedVersionCore,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[string]]$Problems
    )

    if ($null -eq $Evidence) {
        $Problems.Add("${Role}: kein Nachweis vorhanden")
        return
    }
    if ([string](Get-ReleasePhaseProperty -Object $Evidence -Name 'signature_status') -cne 'Valid') {
        $Problems.Add("${Role}: Authenticode-Status ist nicht Valid")
    }
    $thumbprint = ([string](Get-ReleasePhaseProperty -Object $Evidence -Name 'signer_thumbprint') -replace '\s', '').ToUpperInvariant()
    if ($thumbprint -cne $ExpectedThumbprint) {
        $problems.Add("${Role}: Herausgeber-Thumbprint weicht ab")
    }
    if (-not [bool](Get-ReleasePhaseProperty -Object $Evidence -Name 'timestamp_present')) {
        $Problems.Add("${Role}: RFC-3161-Zeitstempel fehlt")
    }
    if (-not [string]::IsNullOrEmpty($ExpectedVersionCore) -and
        [string](Get-ReleasePhaseProperty -Object $Evidence -Name 'product_version') -cne $ExpectedVersionCore) {
        $Problems.Add("${Role}: Programmversion weicht ab")
    }
}

function Test-SandboxAttestationResult {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Result,
        [Parameter(Mandatory = $true)][psobject]$Expectation
    )

    $policy = Get-ReleasePhasePolicy
    $problems = [Collections.Generic.List[string]]::new()
    if ($null -eq $Result) {
        $problems.Add('Sandbox-Ergebnis fehlt')
        return $problems.ToArray()
    }
    $get = { param($name) Get-ReleasePhaseProperty -Object $Result -Name $name }
    $expectedThumbprint = ([string]$Expectation.authenticode_certificate_thumbprint).ToUpperInvariant()
    $versionCore = (Get-ReleaseVersionCore -Version ([string]$Expectation.version)).Text

    if ([string](& $get 'schema_version') -cne $policy.SandboxResultSchema) { $problems.Add('unbekanntes Sandbox-Ergebnisschema') }
    if ([string](& $get 'nonce') -cne [string]$Expectation.nonce) { $problems.Add('Sandbox-Ergebnis gehoert nicht zu diesem Lauf (Nonce)') }
    if (-not [bool](& $get 'completed')) { $problems.Add('Sandbox-Pruefung wurde nicht vollstaendig abgeschlossen') }
    $fatal = [string](& $get 'fatal_error')
    if (-not [string]::IsNullOrWhiteSpace($fatal)) { $problems.Add("Sandbox meldet Fehler: $fatal") }

    $installer = & $get 'installer'
    if ([string](Get-ReleasePhaseProperty -Object $installer -Name 'name') -cne [string]$Expectation.installer_name -or
        [string](Get-ReleasePhaseProperty -Object $installer -Name 'sha256') -cne [string]$Expectation.installer_sha256) {
        $problems.Add('In der Sandbox wurde nicht exakt der attestierte Installer geprueft')
    }
    Test-SandboxBinaryEvidence -Evidence $installer -Role 'Installer' -ExpectedThumbprint $expectedThumbprint `
        -ExpectedVersionCore '' -Problems $problems
    $exitCode = & $get 'installer_exit_code'
    if ($null -eq $exitCode -or [int]$exitCode -ne 0) { $problems.Add('Stille NSIS-Installation endete nicht mit Exitcode 0') }

    $webView = & $get 'webview2'
    if (-not [bool](Get-ReleasePhaseProperty -Object $webView -Name 'present')) { $problems.Add('WebView2-Laufzeit in der Sandbox nicht nachgewiesen') }

    Test-SandboxBinaryEvidence -Evidence (& $get 'main_executable') -Role 'Installierte Haupt-EXE' `
        -ExpectedThumbprint $expectedThumbprint -ExpectedVersionCore $versionCore -Problems $problems
    Test-SandboxBinaryEvidence -Evidence (& $get 'sidecar') -Role 'Installierter Sidecar' `
        -ExpectedThumbprint $expectedThumbprint -ExpectedVersionCore '' -Problems $problems
    if ([string](& $get 'registry_display_version') -cne [string]$Expectation.version) {
        $problems.Add('Windows-Installationsregistrierung bestaetigt die Version nicht')
    }

    $firstRun = & $get 'first_run'
    if (-not [bool](Get-ReleasePhaseProperty -Object $firstRun -Name 'passed')) { $problems.Add('Ersteinrichtungs-Smoke in der Sandbox nicht bestanden') }

    $gui = & $get 'gui'
    if (-not [bool](Get-ReleasePhaseProperty -Object $gui -Name 'main_window') -or
        -not [bool](Get-ReleasePhaseProperty -Object $gui -Name 'responding')) {
        $problems.Add('Hauptfenster der installierten App wurde nicht nachgewiesen')
    }
    return $problems.ToArray()
}

function Test-ReleasePromotionAuthorization {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$DraftState,
        [Parameter(Mandatory = $true)][string]$DraftStateSha256,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Attestation,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NowUtc
    )

    $policy = Get-ReleasePhasePolicy
    $problems = [Collections.Generic.List[string]]::new()
    if ($null -eq $Attestation) {
        $problems.Add('Clean-Windows-Attestierung fehlt')
        return $problems.ToArray()
    }
    if ($null -eq $DraftState) {
        $problems.Add('Draft-State fehlt')
        return $problems.ToArray()
    }
    $att = { param($name) Get-ReleasePhaseProperty -Object $Attestation -Name $name }
    $draft = { param($name) Get-ReleasePhaseProperty -Object $DraftState -Name $name }

    if ([string](& $att 'schema_version') -cne $policy.AttestationSchema) { $problems.Add('unbekanntes Attestierungsschema') }
    if ([string](& $att 'run_id') -cne $RunId) { $problems.Add('Attestierung gehoert zu einem anderen Release-Lauf') }
    if ([string](& $att 'draft_state_sha256') -cne $DraftStateSha256.ToLowerInvariant()) { $problems.Add('Attestierung ist nicht an diesen Draft-State gebunden (Hash)') }
    if ([string](& $att 'result') -cne 'pass') { $problems.Add('Attestierung ist nicht gruen') }
    foreach ($field in @('release_id', 'release_tag', 'release_repository', 'release_repository_commit', 'source_commit', 'version', 'authenticode_certificate_thumbprint')) {
        $expected = [string](& $draft $field)
        if ([string]::IsNullOrWhiteSpace($expected) -or [string](& $att $field) -cne $expected) {
            $problems.Add("Attestierung weicht beim Feld $field vom Draft-State ab")
        }
    }

    $expectedAssets = @(& $draft 'assets' | Where-Object { $null -ne $_ } | ForEach-Object {
            '{0}|{1}|{2}|{3}' -f $_.name, $_.size, $_.sha256, $_.asset_id
        } | Sort-Object -CaseSensitive)
    $attestedAssets = @(& $att 'assets' | Where-Object { $null -ne $_ } | ForEach-Object {
            '{0}|{1}|{2}|{3}' -f $_.name, $_.size, $_.sha256, $_.asset_id
        } | Sort-Object -CaseSensitive)
    if ($expectedAssets.Count -eq 0 -or ($expectedAssets -join "`n") -cne ($attestedAssets -join "`n")) {
        $problems.Add('Attestierte Assets (Name, Groesse, SHA-256, Asset-ID) weichen vom Draft ab')
    }

    $attestedAt = ConvertTo-ReleasePhaseUtc (& $att 'attested_at_utc')
    $expires = ConvertTo-ReleasePhaseUtc (& $att 'expires_at_utc')
    $draftCreated = ConvertTo-ReleasePhaseUtc (& $draft 'created_at_utc')
    $runDeadline = ConvertTo-ReleasePhaseUtc (& $draft 'run_deadline_utc')
    $draftExpires = ConvertTo-ReleasePhaseUtc (& $draft 'expires_at_utc')
    if ($null -eq $attestedAt -or $null -eq $expires -or $null -eq $draftCreated -or $null -eq $runDeadline) {
        $problems.Add('Zeitbindung der Attestierung unvollstaendig')
    }
    else {
        $skew = [TimeSpan]::FromMinutes($policy.ClockSkewMinutes)
        if ($attestedAt -lt $draftCreated -or $attestedAt -gt $NowUtc.Add($skew)) { $problems.Add('Attestierungszeitpunkt ist unplausibel') }
        if ($null -eq $draftExpires -or $attestedAt -ge $draftExpires) { $problems.Add('Attestierung erfolgte nicht innerhalb der Draft-State-Frist') }
        if ($expires -gt $attestedAt.AddMinutes($policy.AttestationValidityMinutes) -or $expires -gt $runDeadline) { $problems.Add('Attestierungsablauf ueberschreitet die zulaessige Frist') }
        if ($NowUtc -ge $expires) { $problems.Add('Attestierung ist abgelaufen') }
        if ($NowUtc -ge $runDeadline) { $problems.Add('Laufbindung ist abgelaufen') }
    }
    return $problems.ToArray()
}

function Assert-ReleasePhaseProblemsEmpty {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Problems,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Problems.Count -gt 0) {
        throw "Produktiver Release blockiert ($Context): $($Problems -join '; ')."
    }
}

function Publish-GitHubDraftRelease {
    param(
        [Parameter(Mandatory = $true)][string]$GhPath,
        [Parameter(Mandatory = $true)][string]$ReleaseRepository,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9]{1,20}$')][string]$ReleaseId
    )

    # Die einzige Stelle, an der ein Draft oeffentlich wird. Sie ist ausschliesslich
    # ueber die Promote-Phase nach Test-ReleasePromotionAuthorization erreichbar und
    # adressiert den Draft ueber seine gebundene numerische ID, nie ueber den Tag.
    Invoke-Native -FilePath $GhPath -Arguments @(
        'api', '--hostname', 'github.com', '--method', 'PATCH',
        "repos/$ReleaseRepository/releases/$ReleaseId",
        '-F', 'draft=false',
        '--silent'
    )
}

function Resolve-WindowsSandboxExecutable {
    $candidates = [Collections.Generic.List[string]]::new()
    $command = Get-Command -Name 'WindowsSandbox.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $candidates.Add($command.Source) }
    if (-not [string]::IsNullOrWhiteSpace($env:windir)) {
        $candidates.Add((Join-Path $env:windir 'System32\WindowsSandbox.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw 'Produktiver Release blockiert: Windows Sandbox ist auf diesem Rechner nicht verfuegbar. Das optionale Windows-Feature "Windows-Sandbox" (Containers-DisposableClientVM) muss aktiviert sein; die Clean-Windows-Attestierung wird nie uebersprungen.'
}

function Get-WindowsSandboxProcess {
    return @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue)
}

function Assert-NoWindowsSandboxRunning {
    if (@(Get-WindowsSandboxProcess).Count -gt 0) {
        throw 'Produktiver Release blockiert: es laeuft bereits eine Windows Sandbox. Windows erlaubt nur eine Instanz; eine fremde Sandbox wird nie automatisch beendet.'
    }
}

function Stop-WindowsSandbox {
    foreach ($process in @(Get-WindowsSandboxProcess)) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Windows-Sandbox-Prozess $($process.Id) konnte nicht beendet werden: $($_.Exception.Message)"
        }
    }
}

function New-CleanWindowsSandboxConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$InputDirectory,
        [Parameter(Mandatory = $true)][string]$ResultDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('Enable', 'Disable')][string]$Networking
    )

    foreach ($directory in @($InputDirectory, $ResultDirectory)) {
        if (-not [IO.Path]::IsPathFullyQualified($directory)) {
            throw "Sandbox-Ordner muss absolut sein: $directory"
        }
    }
    $escape = { param([string]$Value) [Security.SecurityElement]::Escape($Value) }
    # Eingabe (Installer, Erwartung, Pruefskript) ist read-only, nur der Ergebnisordner ist
    # schreibbar. Zwischenablage, Drucker, Audio- und Videoeingang sind abgeschaltet.
    return @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>$(& $escape $Networking)</Networking>
  <MemoryInMB>4096</MemoryInMB>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(& $escape ([IO.Path]::GetFullPath($InputDirectory)))</HostFolder>
      <SandboxFolder>C:\AtlasAttestation\input</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(& $escape ([IO.Path]::GetFullPath($ResultDirectory)))</HostFolder>
      <SandboxFolder>C:\AtlasAttestation\result</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\AtlasAttestation\input\sandbox-probe.ps1</Command>
  </LogonCommand>
</Configuration>
"@
}