# Registers a made-up app the way installers do (an Uninstall entry in HKCU),
# with an install folder and a leftover folder in a throwaway AppData. Checks
# that medic apps lists it, that the review shows the app's own uninstaller and
# what it left behind, and that without a console nothing runs or moves.
# Writes to HKCU of the machine it runs on and removes it again: meant for CI.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Join-Path ([IO.Path]::GetTempPath()) ('medic-uninstall-' + [guid]::NewGuid().ToString('N'))
$medic = Join-Path $root 'medic.exe'
Push-Location (Join-Path $PSScriptRoot '..')
try { go build -o $medic ./cmd/medic } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'FAIL: go build' }

$installDir = Join-Path $root 'Programs\MedicTestApp'
$roaming = Join-Path $root 'Roaming'
$leftover = Join-Path $roaming 'MedicTestApp'
foreach ($d in $installDir, $leftover) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $d 'data.bin'), (New-Object byte[] 1MB))
}
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MedicTestApp'
New-Item -Path $key -Force | Out-Null
$values = @{
    DisplayName = 'MedicTestApp'; DisplayVersion = '1.2.3'; Publisher = 'Medic Tests'
    InstallLocation = $installDir; UninstallString = "cmd /c rd /s /q `"$installDir`""
}
foreach ($v in $values.Keys) { New-ItemProperty -Path $key -Name $v -Value $values[$v] -Force | Out-Null }
New-ItemProperty -Path $key -Name EstimatedSize -Value 1024 -PropertyType DWord -Force | Out-Null

function Invoke-MedicProcess([string[]]$Arguments) {
    $saved = $env:APPDATA
    $ErrorActionPreference = 'Continue'
    try {
        $env:APPDATA = $roaming
        $out = '' | & $medic @Arguments --no-color 2>$null
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
    } finally { $env:APPDATA = $saved }
}

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }

try {
    $list = (Invoke-MedicProcess @('apps', '--json')).Out | ConvertFrom-Json
    $app = @($list.apps | Where-Object { $_.name -eq 'MedicTestApp' })
    Assert-True ($app.Count -eq 1) 'medic apps does not list the test app'
    Assert-True ($app[0].version -eq '1.2.3' -and $app[0].bytes -eq 1MB) "medic apps lists it wrong: $($app[0] | ConvertTo-Json -Compress)"

    $r = Invoke-MedicProcess @('uninstall', 'medictestapp', '--dry-run')
    Assert-True ($r.Code -eq 0) "uninstall --dry-run exited with $($r.Code): $($r.Out)"
    # Paths inside the profile are shown starting with ~, so look for their ends.
    foreach ($want in "rd /s /q", 'Programs\MedicTestApp', 'Roaming\MedicTestApp', 'install folder', 'same name', 'Dry run') {
        Assert-True ($r.Out.Contains($want)) "the review does not show '$want':`n$($r.Out)"
    }

    Assert-True ((Invoke-MedicProcess @('uninstall')).Code -eq 2) 'uninstall without a name did not exit with 2'
    Assert-True ((Invoke-MedicProcess @('uninstall', 'MedicTestApp', '-Yes')).Code -eq 2) 'uninstall -Yes did not exit with 2'
    Assert-True ((Invoke-MedicProcess @('uninstall', 'NoSuchApp')).Code -eq 1) 'an unknown app did not exit with 1'
    Assert-True ((Invoke-MedicProcess @('uninstall', 'MedicTestApp')).Code -eq 1) 'uninstall without a console did not fail'
    Assert-True ((Test-Path $installDir) -and (Test-Path $leftover)) 'something was removed without a review'
} finally {
    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
    cmd /c rd /s /q "$root" 2>$null
}

"OK ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)): lists the app, reviews its uninstaller and leftovers, changes nothing without a console"
