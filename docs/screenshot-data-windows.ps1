# Runs the real Windows report with made-up data, for the README screenshot.
# Only the functions and cmdlets that read the system are replaced here; everything
# that formats and prints is storage-doctor's own code. Used by make-screenshots.py.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Replacing the cmdlets that read the system is the point of this file.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The fakes accept the same parameters as the cmdlets they replace.')]
param()

$ProgressPreference = 'SilentlyContinue'
[Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'

$env:COMPUTERNAME = 'DESKTOP-7K2M4QX'
$env:USERPROFILE = 'C:\Users\alex'
$env:LOCALAPPDATA = 'C:\Users\alex\AppData\Local'
$env:APPDATA = 'C:\Users\alex\AppData\Roaming'
$env:windir = 'C:\WINDOWS'
$env:ProgramData = 'C:\ProgramData'
$env:SystemDrive = 'C:'

. ([IO.Path]::Combine($PSScriptRoot, '..', 'windows', 'storage-doctor.ps1')) -Quick

$L = $env:LOCALAPPDATA
$Downloads = 'C:\Users\alex\Downloads'
$Ubuntu = "$L\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState\ext4.vhdx"

$Sizes = @{
    $Ubuntu                                       = 41.2GB
    "$L\Google\Chrome\User Data\Default\Cache"      = 7.9GB
    "$L\Google\Chrome\User Data\Default\Code Cache" = 1.6GB
    "$L\Microsoft\Edge\User Data\Default\Cache"     = 3.1GB
    "$L\Temp"                                     = 8.4GB
    "$L\Docker\wsl"                               = 6.9GB
    $Downloads                                    = 3.8GB
    "$L\npm-cache"                                = 2.2GB
}

$Wildcards = @{
    "$L\Google\Chrome\User Data\*\Cache"      = "$L\Google\Chrome\User Data\Default\Cache"
    "$L\Google\Chrome\User Data\*\Code Cache" = "$L\Google\Chrome\User Data\Default\Code Cache"
    "$L\Microsoft\Edge\User Data\*\Cache"     = "$L\Microsoft\Edge\User Data\Default\Cache"
    "$L\Packages\*\LocalState\ext4.vhdx"      = $Ubuntu
}

$Installers = @(
    @('Docker Desktop Installer.exe', 520MB), @('virtio-win-0.1.271.iso', 753MB),
    @('PowerToysUserSetup-0.94.0-x64.exe', 260MB), @('VSCodeUserSetup-x64-1.104.0.exe', 105MB),
    @('ZoomInstallerFull.exe', 90MB), @('node-v22.20.0-x64.msi', 31MB), @('ChromeSetup.exe', 10MB),
    @('OfficeSetup.exe', 7MB), @('SteamSetup.exe', 3MB)
) | ForEach-Object {
    [pscustomobject]@{ Name = $_[0]; FullName = "$Downloads\$($_[0])"; Extension = [IO.Path]::GetExtension($_[0]); Length = [long]$_[1] }
}

$Processes = foreach ($app in @(
        @('chrome', 31, 2.7GB), @('Code', 11, 1.3GB), @('svchost', 94, 1.1GB), @('ms-teams', 4, 986MB),
        @('explorer', 1, 604MB), @('Discord', 6, 433MB), @('OneDrive', 1, 388MB), @('MsMpEng', 1, 312MB),
        @('SearchHost', 1, 141MB), @('dwm', 1, 96MB))) {
    for ($i = 0; $i -lt $app[1]; $i++) {
        [pscustomobject]@{ Id = 1000 + $i; ProcessName = $app[0]; WorkingSet64 = [long]($app[2] / $app[1]) }
    }
}

function Get-PathSize([string]$Path) { if ($Sizes.ContainsKey($Path)) { return [long]$Sizes[$Path] } return [long]0 }
function Resolve-Pattern([string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if (-not $p.Contains('*')) { $p } elseif ($Wildcards.ContainsKey($p)) { $Wildcards[$p] }
    }
}
# Join-Path cannot build C:\ paths on a non-Windows machine.
function Join-Path([string]$Path, [string]$ChildPath) { "$Path\$ChildPath" }
function Get-UserSid { 'S-1-5-21-1004336348-1177238915-682003330-1001' }
function Test-Admin { $false }
function Test-Command([string]$Name) { $Name -in 'npm', 'docker' }
function Get-KnownFolder { $Downloads }
function Get-SystemFile {
    [pscustomobject]@{ Name = 'pagefile.sys'; FullName = 'C:\pagefile.sys'; Length = 18.9GB }
    [pscustomobject]@{ Name = 'hiberfil.sys'; FullName = 'C:\hiberfil.sys'; Length = 6.4GB }
}

function Test-Path {
    param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [string]$PathType)
    $p = $Path
    if ($LiteralPath) { $p = $LiteralPath }
    return $p -eq $Downloads
}

function Get-ChildItem {
    param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [switch]$File, [switch]$Directory,
        [switch]$Recurse, [int]$Depth, [switch]$Force)
    $p = $Path
    if ($LiteralPath) { $p = $LiteralPath }
    if ($p -eq $Downloads) { return $Installers }
    if ($Sizes.ContainsKey($p)) { return [pscustomobject]@{ Name = 'data'; FullName = "$p\data" } }
}

function Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    switch ($ClassName) {
        'Win32_LogicalDisk' {
            $c = [pscustomobject]@{ DeviceID = 'C:'; VolumeName = ''; Size = [uint64]475.8GB; FreeSpace = [uint64]63.5GB }
            $d = [pscustomobject]@{ DeviceID = 'D:'; VolumeName = 'Data'; Size = [uint64]931.5GB; FreeSpace = [uint64]643.4GB }
            if ($Filter -like 'DeviceID=*') { return $c }
            return $c, $d
        }
        'Win32_OperatingSystem' {
            return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; Version = '10.0.26100'; TotalVisibleMemorySize = [uint64](16GB / 1KB) }
        }
        'Win32_PerfFormattedData_PerfOS_Memory' {
            return [pscustomobject]@{
                AvailableBytes                  = [uint64]5.1GB
                StandbyCacheCoreBytes           = [uint64]0.2GB
                StandbyCacheNormalPriorityBytes = [uint64]3.4GB
                StandbyCacheReserveBytes        = [uint64]0.3GB
                ModifiedPageListBytes           = [uint64]0.3GB
                CommittedBytes                  = [uint64]14.6GB
                CommitLimit                     = [uint64]34.9GB
            }
        }
        'Win32_PageFileUsage' {
            return [pscustomobject]@{ Name = 'C:\pagefile.sys'; CurrentUsage = 1126; AllocatedBaseSize = 19354 }
        }
    }
}

function Get-Process {
    param([string]$Name)
    if ($Name -eq 'Memory Compression') { return [pscustomobject]@{ Id = 2000; ProcessName = $Name; WorkingSet64 = [long]1.4GB } }
    return $Processes
}

Invoke-StorageDoctor
