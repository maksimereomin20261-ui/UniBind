# Runs isolated native tests. Close all UniBind instances first.
[CmdletBinding()]
param(
    [string]$AutoHotkey = "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
    [switch]$IncludeExe,
    [string]$ResultsDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-test-results')
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $AutoHotkey -PathType Leaf)) { throw 'AutoHotkey v2 executable was not found. Supply -AutoHotkey.' }
if ($IncludeExe -and -not (Test-Path -LiteralPath (Join-Path $Root 'UniBind.exe') -PathType Leaf)) { throw 'UniBind.exe does not exist. Build it first.' }
$Scratch = Join-Path ([IO.Path]::GetTempPath()) ('UniBind-native-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Scratch | Out-Null
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
$Summary = @()
try {
    foreach ($name in @('UniBind.ahk', 'ui', 'lib')) {
        Copy-Item -LiteralPath (Join-Path $Root $name) -Destination $Scratch -Recurse
    }
    if ($IncludeExe) { Copy-Item -LiteralPath (Join-Path $Root 'UniBind.exe') -Destination $Scratch }
    $Targets = @('AHK')
    if ($IncludeExe) { $Targets += 'EXE' }
    foreach ($Target in $Targets) {
        foreach ($Test in @(
            @{ Mode = '--self-test'; Report = 'overlay-self-test.txt' },
            @{ Mode = '--overlay-gui-test'; Report = 'overlay-gui-test.txt' },
            @{ Mode = '--data-self-test'; Report = 'data-self-test.txt' }
        )) {
            $Report = Join-Path $Scratch $Test.Report
            if (Test-Path -LiteralPath $Report) { Remove-Item -LiteralPath $Report }
            if ($Target -eq 'AHK') {
                $Program = $AutoHotkey
                $Arguments = @('/ErrorStdOut', ('"{0}"' -f (Join-Path $Scratch 'UniBind.ahk')), $Test.Mode)
            } else {
                $Program = Join-Path $Scratch 'UniBind.exe'
                $Arguments = @($Test.Mode)
            }
            Write-Host "Running $Target $($Test.Mode). A native report dialog may need OK."
            $Process = Start-Process -FilePath $Program -ArgumentList $Arguments -WorkingDirectory $Scratch -Wait -PassThru
            $Text = if (Test-Path -LiteralPath $Report) { Get-Content -LiteralPath $Report -Raw -Encoding UTF8 } else { '' }
            $Passed = $Process.ExitCode -eq 0 -and $Text -match '(?m)^Failures:\s*0\s*$'
            $Summary += [pscustomobject]@{ Target = $Target; Mode = $Test.Mode; ExitCode = $Process.ExitCode; Passed = $Passed }
            if ($Text) { [IO.File]::WriteAllText((Join-Path $ResultsDirectory ("$Target-" + $Test.Report)), $Text, [Text.UTF8Encoding]::new($false)) }
            if (-not $Passed) { throw "Native test failed: $Target $($Test.Mode). See $ResultsDirectory." }
        }
    }
} finally {
    $Summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.json') -Encoding UTF8
    if (Test-Path -LiteralPath $Scratch) { Remove-Item -LiteralPath $Scratch -Recurse -Force }
}
Write-Host "Native tests passed. GTA, clipboard delivery, DPI, another PC and Windows Security are NOT covered."
