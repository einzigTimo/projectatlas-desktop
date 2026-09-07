#Requires -Version 7
# Reiner NSIS-Compile-Hook: kein Installations- oder Veroeffentlichungseinstieg.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath
)
$ErrorActionPreference = 'Stop'
$source = Get-Item -LiteralPath $SourcePath
if ($source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Der zu paketierende Hauptprozess muss eine regulaere Datei sein.'
}
$inputStream = [IO.File]::Open($source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $outputStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) }
    finally { $outputStream.Dispose() }
}
finally { $inputStream.Dispose() }
