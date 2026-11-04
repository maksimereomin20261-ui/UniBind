# Uses the official tools supplied by the operator; does not download or run installers.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ahk2Exe,
    [string]$AutoHotkey = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
    [string]$OutputDirectory = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'dist'),
    [switch]$ScanWithDefender
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Ahk2Exe = (Resolve-Path -LiteralPath $Ahk2Exe).Path
$AutoHotkey = (Resolve-Path -LiteralPath $AutoHotkey).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $OutputDirectory -eq $Root) {
    throw 'The output directory must be outside the source folder.'
}
$Stage = Join-Path $OutputDirectory ('UniBind-2027.10-beta.1-hf2-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$App = Join-Path $Stage 'UniBind'
New-Item -ItemType Directory -Path $App -Force | Out-Null
$Icon = Join-Path (Split-Path $Root -Parent) 'installer/UniBind.ico'
& (Join-Path $PSScriptRoot 'Build-Payload.ps1') -Ahk2Exe $Ahk2Exe -AutoHotkey $AutoHotkey -OutputDirectory $App -Icon $Icon
foreach ($Name in @('UniBind.ahk','tools','docs','README.md','BUILD_EXE.md','CHANGELOG.md','KNOWN_LIMITATIONS.md','RELEASE_CHECKLIST.md','START_HERE_RU.md')) {
    Copy-Item -LiteralPath (Join-Path $Root $Name) -Destination $App -Recurse
}
# The package deliberately excludes config, backups, logs, caches and local test results.
$Exe = Join-Path $App 'UniBind.exe'
& (Join-Path $App 'tools\Test-Windows.ps1') -AutoHotkey $AutoHotkey -IncludeExe -ResultsDirectory (Join-Path $Stage 'native-test-results')
if ($ScanWithDefender) {
    if (-not (Get-Command Start-MpScan -ErrorAction SilentlyContinue)) { throw 'Microsoft Defender cmdlet is unavailable. Do not treat this as a passed scan.' }
    Start-MpScan -ScanType CustomScan -ScanPath $App
    Write-Warning 'Review Protection History for detections. Completion of Start-MpScan is not a safety certificate.'
}
$Signature = Get-AuthenticodeSignature -LiteralPath $Exe
Write-Host ('EXE signature status: ' + $Signature.Status)
if ($Signature.Status -ne 'Valid') { Write-Warning 'No trusted code signature was established. A checksum is not a signature.' }
$Prefix = $App.TrimEnd('\') + '\'
$Manifest = Get-ChildItem -LiteralPath $App -File -Recurse | Sort-Object FullName | ForEach-Object {
    $Relative = $_.FullName.Substring($Prefix.Length).Replace('\','/')
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $Relative
}
[IO.File]::WriteAllLines((Join-Path $App 'SHA256SUMS.txt'), [string[]]$Manifest, [Text.UTF8Encoding]::new($false))
$Zip = $Stage + '.zip'
Compress-Archive -LiteralPath $App -DestinationPath $Zip
$ZipHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($Zip + '.sha256'), ($ZipHash + '  ' + [IO.Path]::GetFileName($Zip) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Host "Created $Zip"
Write-Warning 'Do not publish until manual GTA, clean-machine, download and security checks are complete.'
