# Installs medic from release files built by tools/dist.sh (the folder is the
# first argument), the way the README's option form runs it, then checks that a
# new PowerShell and cmd find "medic" from any folder, that a tampered download
# is refused, and that -Uninstall removes the files and the PATH entry.
# Changes the user PATH of the machine it runs on: meant for CI.
param([Parameter(Mandatory)][string]$Dist)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$installer = Join-Path $PSScriptRoot '..\install.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) ('medic-test-' + [guid]::NewGuid().ToString('N'))
$binDir = Join-Path $dir 'bin'
$expected = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\windows\medic.ps1') -Version

function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { return @(([string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')).Split(';')) } finally { $key.Close() }
}

# The PATH a new terminal window gets, without anything from this session.
function Get-FreshPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    return "$machine;$([Environment]::GetEnvironmentVariable('Path', 'User'))"
}

& ([scriptblock]::Create((Get-Content -Raw $installer))) -From $Dist -InstallDir $dir
if ((Get-UserPath) -notcontains $binDir) { throw "FAIL: $binDir not added to the user PATH" }

$savedPath = $env:Path
try {
    $env:Path = Get-FreshPath
    Push-Location ([IO.Path]::GetTempPath())
    $fromPowerShell = & powershell.exe -NoProfile -Command 'medic -Version'
    $fromCmd = & cmd.exe /d /c 'medic -Version'
    Pop-Location
} finally { $env:Path = $savedPath }
if ($fromPowerShell -ne $expected) { throw "FAIL: 'medic -Version' in a new PowerShell printed '$fromPowerShell'" }
if ($fromCmd -ne $expected) { throw "FAIL: 'medic -Version' in cmd printed '$fromCmd'" }

& $installer -From $Dist -InstallDir $dir | Out-Null
if (@(Get-UserPath | Where-Object { $_ -eq $binDir }).Count -ne 1) { throw 'FAIL: PATH entry added twice' }

$tampered = Join-Path $dir '..\medic-tampered'
Copy-Item -LiteralPath $Dist -Destination $tampered -Recurse
Add-Content -LiteralPath (Join-Path $tampered 'medic.ps1') -Value "Write-Host 'pwned'"
$other = Join-Path $dir '..\medic-other'
$refused = $false
try { & $installer -From $tampered -InstallDir $other -NoModifyPath } catch { $refused = $_.Exception.Message -match 'checksum mismatch' }
if (-not $refused) { throw 'FAIL: a tampered medic.ps1 was not refused' }
if (Test-Path (Join-Path $other 'medic.ps1')) { throw 'FAIL: a tampered medic.ps1 was written' }

& $installer -InstallDir $dir -Uninstall | Out-Null
if ((Get-UserPath) -contains $binDir) { throw 'FAIL: PATH entry left behind after -Uninstall' }
if (Test-Path -LiteralPath $dir) { throw 'FAIL: install folder left behind after -Uninstall' }
Remove-Item -LiteralPath $tampered -Recurse -Force

'OK: installed, runs from any folder in PowerShell and cmd, refuses tampered files, uninstalls'
