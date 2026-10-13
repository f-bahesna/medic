<#
.SYNOPSIS
    Installs medic for Windows as a command you can run from any folder.

.DESCRIPTION
    Installs for the current user only, no administrator rights needed:
    medic.exe goes into %LOCALAPPDATA%\Programs\medic\bin, which is added to
    your user PATH. An install of medic before 0.5 (a script and a medic.cmd
    launcher) is replaced.

.EXAMPLE
    irm https://github.com/f-bahesna/medic/releases/latest/download/install.ps1 | iex
    Install the latest release.

.EXAMPLE
    & ([scriptblock]::Create((irm https://github.com/f-bahesna/medic/releases/latest/download/install.ps1))) -Uninstall
    Pass options when installing straight from the web, here to remove medic.

.LINK
    https://github.com/f-bahesna/medic
#>
[CmdletBinding()]
param(
    # Install this release (for example v0.5.0) instead of the latest.
    [string]$Version = '',
    # Install into this folder instead of %LOCALAPPDATA%\Programs\medic.
    [string]$InstallDir = '',
    # Download the release files from this URL or folder instead of GitHub (mirrors, tests).
    [string]$From = '',
    # Do not add the bin folder to your user PATH.
    [switch]$NoModifyPath,
    # Remove medic.
    [switch]$Uninstall
)

# Everything runs inside functions, so "irm ... | iex" leaves no settings or
# variables behind in your PowerShell session, and errors never close it.

function Get-ReleaseFile([string]$Name, [string]$Destination, [string]$Source, [string]$Tag) {
    if ($Source -and (Test-Path -LiteralPath $Source -PathType Container)) {
        Copy-Item -LiteralPath (Join-Path $Source $Name) -Destination $Destination
        return
    }
    if ($Source) { $base = $Source.TrimEnd('/') }
    elseif ($Tag) { $base = "https://github.com/f-bahesna/medic/releases/download/$Tag" }
    else { $base = 'https://github.com/f-bahesna/medic/releases/latest/download' }
    # Windows PowerShell 5.1 may still default to TLS 1.0, which GitHub refuses.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads very slow
    Invoke-WebRequest -Uri "$base/$Name" -OutFile $Destination -UseBasicParsing
}

function Test-Checksum([string]$Path, [string]$SumsPath) {
    $name = Split-Path -Leaf $Path
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $SumsPath) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$' -and $Matches[2] -eq $name) { $expected = $Matches[1] }
    }
    if (-not $expected) { throw "SHA256SUMS has no entry for $name" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "checksum mismatch for $name, refusing to install it" }
}

function Get-UserPathEntry {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        # DoNotExpandEnvironmentNames keeps entries like %USERPROFILE%\bin as they are.
        return @(([string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')).Split(';') | Where-Object { $_ })
    } finally { $key.Close() }
}

function Set-UserPathEntry([string[]]$Entries) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try { $key.SetValue('Path', ($Entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
    # Setting any user variable through .NET tells Explorer and new terminals that PATH changed.
    [Environment]::SetEnvironmentVariable('MEDIC_INSTALL', '1', 'User')
    [Environment]::SetEnvironmentVariable('MEDIC_INSTALL', $null, 'User')
}

function Add-UserPath([string]$Dir) {
    $entries = Get-UserPathEntry
    if ($entries -notcontains $Dir) {
        Set-UserPathEntry ($entries + $Dir)
        Write-Host "Added $Dir to your user PATH."
    }
    if (($env:Path.Split(';')) -notcontains $Dir) { $env:Path = "$env:Path;$Dir" }
}

function Remove-UserPath([string]$Dir) {
    $entries = Get-UserPathEntry
    if ($entries -contains $Dir) {
        Set-UserPathEntry @($entries | Where-Object { $_ -ne $Dir })
        Write-Host "Removed $Dir from your user PATH."
    }
}

# Is the file medic: the binary, or a file medic before 0.5 installed?
function Test-MedicFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return [bool](Select-String -LiteralPath $Path -Pattern 'github.com/f-bahesna/medic', 'medic for Windows', 'medic launcher' -SimpleMatch -Quiet)
}

# The build for this PC. ARM PCs get the ARM build even when this runs in an
# emulated x64 PowerShell.
function Get-MedicArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -eq 'ARM64') { return 'arm64' }
    return 'amd64'
}

# medic before 0.5 was a script with a medic.cmd launcher; the binary replaces both.
function Remove-OldMedic([string]$Dir) {
    foreach ($file in (Join-Path $Dir 'medic.ps1'), (Join-Path $Dir 'bin\medic.cmd')) {
        if (Test-MedicFile $file) { Remove-Item -LiteralPath $file -Force }
    }
}

function Install-Medic([string]$Dir, [string]$Source, [string]$Tag, [bool]$ModifyPath) {
    $binDir = Join-Path $Dir 'bin'
    $target = Join-Path $binDir 'medic.exe'
    if ((Test-Path -LiteralPath $target) -and -not (Test-MedicFile $target)) {
        throw "$target already exists and is not medic, leaving it alone"
    }

    $archive = "medic_windows_$(Get-MedicArch).zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('medic-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        foreach ($name in 'SHA256SUMS', $archive) {
            Get-ReleaseFile -Name $name -Destination (Join-Path $tmp $name) -Source $Source -Tag $Tag
        }
        Test-Checksum (Join-Path $tmp $archive) (Join-Path $tmp 'SHA256SUMS')
        Expand-Archive -LiteralPath (Join-Path $tmp $archive) -DestinationPath (Join-Path $tmp 'unpacked')
        $exe = Join-Path $tmp 'unpacked\medic.exe'
        $null = & $exe --version
        if ($LASTEXITCODE -ne 0) { throw 'the downloaded medic.exe does not run on this PC, refusing to install it' }

        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Copy-Item -LiteralPath $exe -Destination $target -Force
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-OldMedic $Dir

    $installed = & $target --version
    Write-Host "Installed $installed to $target."
    if ($ModifyPath) {
        Add-UserPath $binDir
        Write-Host 'Open a new terminal window if medic is not found there yet.'
    } else {
        Write-Host "Add $binDir to your PATH to run medic from any folder."
    }
    $found = Get-Command medic -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found -and $found.Source -ne $target) {
        Write-Host "Note: $($found.Source) comes earlier on your PATH and runs instead of this medic."
    }
    Write-Host ''
    Write-Host 'Run: medic'
}

function Uninstall-Medic([string]$Dir) {
    $binDir = Join-Path $Dir 'bin'
    $target = Join-Path $binDir 'medic.exe'
    if ((Test-Path -LiteralPath $target) -and -not (Test-MedicFile $target)) {
        throw "$target is not medic, leaving it alone"
    }
    Remove-UserPath $binDir
    # Only the files the installer wrote, then the folders if that left them empty.
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    Remove-OldMedic $Dir
    foreach ($folder in $binDir, $Dir) {
        if ((Test-Path -LiteralPath $folder) -and -not (Get-ChildItem -LiteralPath $folder -Force)) {
            Remove-Item -LiteralPath $folder -Force
        }
    }
    Write-Host "Removed medic from $Dir."
}

function Invoke-MedicInstaller([string]$Tag, [string]$Dir, [string]$Source, [bool]$ModifyPath, [bool]$Remove) {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        throw 'This installs the Windows version. On macOS, use install.sh instead.'
    }
    if (-not $Dir) { $Dir = Join-Path $env:LOCALAPPDATA 'Programs\medic' }
    $Dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir)
    if ($Source -and (Test-Path -LiteralPath $Source -PathType Container)) { $Source = (Resolve-Path -LiteralPath $Source).Path }

    if ($Remove) { Uninstall-Medic $Dir } else { Install-Medic -Dir $Dir -Source $Source -Tag $Tag -ModifyPath $ModifyPath }
}

Invoke-MedicInstaller -Tag $Version -Dir $InstallDir -Source $From -ModifyPath (-not $NoModifyPath) -Remove $Uninstall
