# Runs the medic commands with a throwaway user profile: JSON output parses, exit
# codes follow the contract, clean -Yes only touches what -Only picks, and purge
# only deletes dependency folders of inactive projects, never through a junction.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$medic = Join-Path $PSScriptRoot '..\windows\medic.ps1'
$exe = (Get-Process -Id $PID).Path   # the same PowerShell edition that runs this test
$root = Join-Path ([IO.Path]::GetTempPath()) ('medic-commands-' + [guid]::NewGuid().ToString('N'))
$home_ = Join-Path $root 'profile'
$local = Join-Path $home_ 'AppData\Local'
$roaming = Join-Path $home_ 'AppData\Roaming'

function New-Blob([string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] 2MB))
}

# Runs medic in a new process with the throwaway profile and no console input.
# Returns the exit code and stdout.
function Invoke-MedicProcess([string[]]$Arguments) {
    $saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA; APPDATA = $env:APPDATA }
    $ErrorActionPreference = 'Continue'
    try {
        $env:USERPROFILE = $home_
        $env:LOCALAPPDATA = $local
        $env:APPDATA = $roaming
        $out = '' | & $exe -NoProfile -ExecutionPolicy Bypass -File $medic @Arguments -NoColor 2>$null
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
    } finally {
        foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
    }
}

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }

New-Blob "$local\Temp\leftover.tmp"
New-Blob "$roaming\Code\Cache\blob"
New-Blob "$home_\dev\old-web\node_modules\pkg\index.js"
Set-Content -Path "$home_\dev\old-web\package.json" -Value '{}'
New-Blob "$home_\dev\new-web\node_modules\pkg\index.js"
Set-Content -Path "$home_\dev\new-web\package.json" -Value '{}'
New-Blob "$home_\dev\old-rust\target\debug\app.exe"
Set-Content -Path "$home_\dev\old-rust\Cargo.toml" -Value ''
New-Blob "$home_\dev\no-marker\node_modules\pkg\index.js"
New-Item -ItemType Directory -Path "$root\outside" -Force | Out-Null
Set-Content -Path "$root\outside\keep.txt" -Value keep
New-Item -ItemType Junction -Path "$home_\dev\old-web\node_modules\linked" -Target "$root\outside" | Out-Null
foreach ($f in "$home_\dev\old-web\package.json", "$home_\dev\old-rust\Cargo.toml") { (Get-Item $f).LastWriteTime = '2024-01-01' }

try {
    foreach ($cmd in @(@('report', '-Quick'), @('disk'), @('memory'), @('purge'), @('check', '-MinFree', '1M'))) {
        $r = Invoke-MedicProcess ($cmd + '-Json')
        Assert-True ($r.Code -eq 0) "medic $cmd -Json exited with $($r.Code)"
        try { $null = $r.Out | ConvertFrom-Json } catch { throw "FAIL: medic $cmd -Json did not print valid JSON: $($r.Out)" }
    }

    $kinds = @(((Invoke-MedicProcess @('purge', '-Json')).Out | ConvertFrom-Json).purge.folders | ForEach-Object { $_.kind } | Sort-Object) -join ', '
    Assert-True ($kinds -eq 'node_modules, Rust build') "purge -Json listed '$kinds' instead of the two inactive projects"

    Assert-True ((Invoke-MedicProcess @('check', '-MinFree', '1M')).Code -eq 0) 'check failed with a 1 MB minimum'
    Assert-True ((Invoke-MedicProcess @('check', '-MinFree', '100%')).Code -eq 1) 'check passed with a 100% minimum'
    foreach ($bad in @(@('bogus'), @('-Yes'), @('clean', '-Json'), @('check', '-MinFree', 'lots'), @('purge', '-Only', 'safe'))) {
        $code = (Invoke-MedicProcess $bad).Code
        Assert-True ($code -eq 2) "medic $bad exited with $code instead of 2"
    }
    Assert-True ((Invoke-MedicProcess @('clean')).Code -eq 1) 'clean without a console or -Yes did not fail'

    Invoke-MedicProcess @('clean', '-DryRun', '-Yes', '-Only', 'user_temp') | Out-Null
    Assert-True (Test-Path "$local\Temp\leftover.tmp") 'clean -DryRun deleted a file'
    Invoke-MedicProcess @('clean', '-Yes', '-Only', 'user_temp') | Out-Null
    Assert-True (-not (Test-Path "$local\Temp\leftover.tmp")) 'clean -Yes -Only user_temp did not clean the temp folder'
    Assert-True (Test-Path "$roaming\Code\Cache\blob") 'clean -Only user_temp also cleaned the app caches'

    $r = Invoke-MedicProcess @('purge', '-Yes')
    Assert-True (-not (Test-Path "$home_\dev\old-web\node_modules")) "purge kept node_modules of an inactive project:`n$($r.Out)"
    Assert-True (-not (Test-Path "$home_\dev\old-rust\target")) "purge kept target of an inactive Rust project:`n$($r.Out)"
    Assert-True (Test-Path "$home_\dev\new-web\node_modules") 'purge deleted node_modules of an active project'
    Assert-True (Test-Path "$home_\dev\no-marker\node_modules") 'purge deleted node_modules without a package.json'
    Assert-True (Test-Path "$root\outside\keep.txt") 'purge followed a junction'
    Assert-True (Test-Path "$home_\dev\old-web\package.json") 'purge deleted project files'

    Invoke-MedicProcess @('purge', '-Yes', '-OlderThan', '0') | Out-Null
    Assert-True (-not (Test-Path "$home_\dev\new-web\node_modules")) 'purge -OlderThan 0 kept node_modules of an active project'
} finally {
    cmd /c rd /s /q "$root" 2>$null
}

"OK ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)): JSON parses, exit codes match, clean and purge only touch what they should"
