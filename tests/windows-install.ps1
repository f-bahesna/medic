# Installs medic from release files built by tools/dist.sh (the folder is the
# first argument), the way the README's option form runs it, over an install of
# the script medic was before 0.5. Then checks that a new PowerShell and cmd
# find "medic" from any folder, that the old script and launcher are gone, that
# a tampered download is refused, and that -Uninstall removes the files and the
# PATH entry.
# Changes the user PATH of the machine it runs on: meant for CI.
param([Parameter(Mandatory)][string]$Dist)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$installer = Join-Path $PSScriptRoot '..\install.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) ('medic-test-' + [guid]::NewGuid().ToString('N'))
$binDir = Join-Path $dir 'bin'

function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { return @(([string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')).Split(';')) } finally { $key.Close() }
}

# The PATH a new terminal window gets, without anything from this session.
function Get-FreshPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    return "$machine;$([Environment]::GetEnvironmentVariable('Path', 'User'))"
}

# An install from before 0.5: the script and its launcher.
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
Set-Content -Path (Join-Path $dir 'medic.ps1') -Value '<#', '.SYNOPSIS', '    medic for Windows - old script', '#>'
Set-Content -Path (Join-Path $binDir 'medic.cmd') -Value '@echo off', 'rem medic launcher, written by the medic installer.'

& ([scriptblock]::Create((Get-Content -Raw $installer))) -From $Dist -InstallDir $dir
if (Test-Path (Join-Path $dir 'medic.ps1')) { throw 'FAIL: the old medic.ps1 was left behind' }
if (Test-Path (Join-Path $binDir 'medic.cmd')) { throw 'FAIL: the old medic.cmd launcher was left behind' }
if ((Get-UserPath) -notcontains $binDir) { throw "FAIL: $binDir not added to the user PATH" }

$savedPath = $env:Path
try {
    $env:Path = Get-FreshPath
    Push-Location ([IO.Path]::GetTempPath())
    $fromPowerShell = & powershell.exe -NoProfile -Command 'medic -Version'
    $fromCmd = & cmd.exe /d /c 'medic -Version'
    Pop-Location
} finally { $env:Path = $savedPath }
if ($fromPowerShell -notmatch '^medic \S+$') { throw "FAIL: 'medic -Version' in a new PowerShell printed '$fromPowerShell'" }
if ($fromCmd -ne $fromPowerShell) { throw "FAIL: 'medic -Version' in cmd printed '$fromCmd'" }

& $installer -From $Dist -InstallDir $dir | Out-Null
if (@(Get-UserPath | Where-Object { $_ -eq $binDir }).Count -ne 1) { throw 'FAIL: PATH entry added twice' }

$tampered = Join-Path $dir '..\medic-tampered'
Copy-Item -LiteralPath $Dist -Destination $tampered -Recurse
Get-ChildItem -LiteralPath $tampered -Filter 'medic_windows_*.zip' | ForEach-Object { Add-Content -LiteralPath $_.FullName -Value 'pwned' }
$other = Join-Path $dir '..\medic-other'
$refused = $false
try { & $installer -From $tampered -InstallDir $other -NoModifyPath } catch { $refused = $_.Exception.Message -match 'checksum mismatch' }
if (-not $refused) { throw 'FAIL: a tampered download was not refused' }
if (Test-Path (Join-Path $other 'bin\medic.exe')) { throw 'FAIL: a tampered download was written' }

& $installer -InstallDir $dir -Uninstall | Out-Null
if ((Get-UserPath) -contains $binDir) { throw 'FAIL: PATH entry left behind after -Uninstall' }
if (Test-Path -LiteralPath $dir) { throw 'FAIL: install folder left behind after -Uninstall' }
Remove-Item -LiteralPath $tampered -Recurse -Force

'OK: installed over an old install, runs from any folder in PowerShell and cmd, refuses tampered files, uninstalls'
