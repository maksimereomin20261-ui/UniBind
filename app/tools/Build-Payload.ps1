# Shared compiler and application payload builder. No user data is included.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ahk2Exe,
    [Parameter(Mandatory = $true)][string]$AutoHotkey,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Icon,
    [string]$LicenseFile,
    [string]$LogDirectory
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Compiler = (Resolve-Path -LiteralPath $Ahk2Exe).Path
$Base = (Resolve-Path -LiteralPath $AutoHotkey).Path
$Source = (Resolve-Path -LiteralPath (Join-Path $Root 'UniBind.ahk')).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$Exe = Join-Path $OutputDirectory 'UniBind.exe'
$Arguments = @('/in', ('"{0}"' -f $Source), '/out', ('"{0}"' -f $Exe), '/base', ('"{0}"' -f $Base))
if ($Icon) { $Arguments += @('/icon', ('"{0}"' -f (Resolve-Path -LiteralPath $Icon).Path)) }
$Arguments += @('/silent', 'verbose')
if ($LogDirectory) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $out = Join-Path $LogDirectory 'compile-out.txt'
    $err = Join-Path $LogDirectory 'compile-err.txt'
    $CompilerProcess = Start-Process -FilePath $Compiler -ArgumentList $Arguments -WorkingDirectory $Root -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (Test-Path $out) { Get-Content $out }
    if (Test-Path $err) { Get-Content $err }
} else {
    $CompilerProcess = Start-Process -FilePath $Compiler -ArgumentList $Arguments -WorkingDirectory $Root -Wait -PassThru
}
if ($CompilerProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw 'Ahk2Exe failed or produced no EXE.' }
foreach ($Name in @('ui', 'lib', 'THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $Root $Name) -Destination $OutputDirectory -Recurse -Force
}
if ($LicenseFile) { Copy-Item -LiteralPath $LicenseFile -Destination (Join-Path $OutputDirectory 'LICENSE-AutoHotkey.txt') }
