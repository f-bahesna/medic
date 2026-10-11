# Runs the Clear-Folder helper that storage-doctor prints, and checks that it empties
# a folder (read-only files included) without touching what junctions inside it point to.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\windows\storage-doctor.ps1')   # dot-sourcing only loads definitions
. ([scriptblock]::Create($ClearFolderHelper))   # defines Clear-Folder exactly as users paste it

$root = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path "$root\target", "$root\cache\sub" -Force | Out-Null
Set-Content -Path "$root\target\keep.txt" -Value keep
Set-Content -Path "$root\cache\top.txt" -Value x
Set-Content -Path "$root\cache\sub\deep.txt" -Value x
Set-ItemProperty -Path "$root\cache\sub\deep.txt" -Name IsReadOnly -Value $true
New-Item -ItemType Junction -Path "$root\cache\link" -Target "$root\target" | Out-Null
New-Item -ItemType Junction -Path "$root\cache\sub\deeplink" -Target "$root\target" | Out-Null

Clear-Folder "$root\cache"

$left = @(Get-ChildItem -LiteralPath "$root\cache" -Force -Recurse -ErrorAction SilentlyContinue)
if ($left.Count -ne 0) { throw "cache not emptied, left: $($left.FullName -join ', ')" }
if (-not (Test-Path -LiteralPath "$root\target\keep.txt")) { throw 'junction target was deleted' }
if (-not (Test-Path -LiteralPath "$root\cache")) { throw 'the folder itself was deleted' }
"OK ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)): folder emptied, junction targets kept"
