<#
.SYNOPSIS
    storage-doctor for Windows - see what is filling up your PC and what is safe to clean.

.DESCRIPTION
    Read-only by default: nothing is deleted unless you pass -Clean and confirm
    every single item. Only SAFE and CAUTION items can ever be cleaned. REVIEW
    items (your personal data) are reported, never touched.

    Runs on the Windows PowerShell 5.1 that ships with Windows 10 and 11, and on
    PowerShell 7. No dependencies. The macOS version lives in macos/storage-doctor.sh.

    Safety levels:
      SAFE      Regenerated automatically. No data loss.
      CAUTION   Regenerable, but you lose more than a cache (stopped containers,
                locally installed artifacts) or it costs a long rebuild.
      REVIEW    May contain personal data. Reported only, never deleted.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\storage-doctor.ps1
    Full read-only report.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\storage-doctor.ps1 -DryRun
    Walk through the cleanup and show what would happen, change nothing.

.LINK
    https://github.com/f-bahesna/storage-doctor
#>
[CmdletBinding()]
param(
    # Clean SAFE and CAUTION items, asking before each one.
    [switch]$Clean,
    # Like -Clean, but only shows what would be done.
    [switch]$DryRun,
    # Skip the slow scans (large files, dev projects, breakdowns).
    [switch]$Quick,
    # Report files bigger than this many megabytes.
    [ValidateRange(1, 10485760)]
    [int]$LargeMB = 500,
    # Extra folders to scan for node_modules and Python venvs.
    [string[]]$DevDir = @(),
    # Disable colored output (NO_COLOR is honored too).
    [switch]$NoColor,
    # Show the version and exit.
    [switch]$Version
)

Set-StrictMode -Version 2.0

$ScriptVersion = '0.2.0'
$DoClean = [bool]($Clean -or $DryRun)
$DryRunMode = [bool]$DryRun
$LargeBytes = [long]$LargeMB * 1MB
$ExtraDevDirs = @($DevDir)
$UseColor = -not $NoColor -and -not $env:NO_COLOR

# File attributes, as numbers so they work on every .NET version.
$ReparsePoint = 0x400        # junctions and symlinks: never followed, never deleted through
$CloudOnly = 0x441000        # Offline | RecallOnOpen | RecallOnDataAccess: OneDrive placeholders

$Items = New-Object System.Collections.Generic.List[object]
$Allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$AllowedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$InstallerFiles = @()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Text([string]$Text, [string]$Color, [switch]$NoNewline) {
    if ($UseColor -and $Color) {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    } else {
        Write-Host $Text -NoNewline:$NoNewline
    }
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Text $Title DarkCyan
    Write-Text ('-' * 60) DarkGray
}

function Write-Note([string]$Text) { Write-Text "  $Text" DarkGray }
function Write-Warn([string]$Text) { Write-Text "  ! $Text" DarkYellow }

# Windows Explorer counts 1 GB as 1024 MB, so this does too.
function Format-Size([double]$Bytes) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt 4) { $Bytes /= 1024; $i++ }
    if ($i -le 2) { return ('{0:N0} {1}' -f $Bytes, $units[$i]) }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function Format-Path([string]$Path) {
    if ($env:USERPROFILE -and $Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($env:USERPROFILE.Length)
    }
    return $Path
}

function Write-Bar([int]$Pct) {
    $filled = [int][math]::Floor($Pct * 30 / 100)
    $color = 'Green'
    if ($Pct -ge 90) { $color = 'Red' } elseif ($Pct -ge 75) { $color = 'DarkYellow' }
    Write-Text ('[' + ('#' * $filled) + ('.' * (30 - $filled)) + ']') $color -NoNewline
}

function Write-Badge([string]$Safety) {
    $color = @{ SAFE = 'Green'; CAUTION = 'DarkYellow'; REVIEW = 'Red' }[$Safety]
    Write-Text ('{0,-7}' -f $Safety) $color -NoNewline
}

function Write-Row([string]$Label, [string]$Value, [string]$Hint) {
    Write-Host ('  {0,-22} {1}' -f $Label, $Value) -NoNewline
    if ($Hint) { Write-Text " $Hint" DarkGray } else { Write-Host '' }
}

function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# File system walking. Junctions and symlinks are never followed (the user
# profile has legacy junctions that loop), and cloud-only OneDrive files are
# not counted because they take no space on this disk.
# ---------------------------------------------------------------------------

function Get-PathSize([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [long]0 }
    if (-not $item.PSIsContainer) { return [long]$item.Length }
    $total = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($item)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            $attr = [int]$e.Attributes
            if ($e -is [System.IO.DirectoryInfo]) {
                if (-not ($attr -band $ReparsePoint)) { $stack.Push($e) }
            } elseif (-not ($attr -band $CloudOnly)) {
                $total += $e.Length
            }
        }
    }
    return $total
}

# Folders named node_modules, or Python virtualenvs, below the given roots.
function Find-DependencyFolder([string[]]$Roots) {
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    foreach ($r in $Roots) { $stack.Push((New-Object System.IO.DirectoryInfo $r)) }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $subs = $dir.GetDirectories() } catch { continue }
        foreach ($s in $subs) {
            if ([int]$s.Attributes -band $ReparsePoint) { continue }
            if ($s.Name -eq 'node_modules') { $s.FullName; continue }
            if ($s.Name -eq '.venv' -or $s.Name -eq 'venv') {
                if (Test-Path -LiteralPath (Join-Path $s.FullName 'pyvenv.cfg')) { $s.FullName; continue }
            }
            if ($s.Name -eq '.git') { continue }
            $stack.Push($s)
        }
    }
}

function Find-LargeFile([string]$Root, [long]$MinBytes) {
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo $Root))
    $appData = Join-Path $Root 'AppData'
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            $attr = [int]$e.Attributes
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($attr -band $ReparsePoint) { continue }
                if ($e.Name -eq 'node_modules' -or $e.Name -eq '.git' -or $e.FullName -eq $appData) { continue }
                $stack.Push($e)
            } elseif ($e.Length -ge $MinBytes -and -not ($attr -band $CloudOnly)) {
                [pscustomobject]@{ Bytes = $e.Length; Modified = $e.LastWriteTime; Path = $e.FullName }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Disk overview
# ---------------------------------------------------------------------------

function Show-Disk {
    Write-Section 'Disk'
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID
    foreach ($d in $disks) {
        if (-not $d.Size) { continue }
        $used = $d.Size - $d.FreeSpace
        $pct = [int][math]::Floor($used * 100 / $d.Size)
        $name = $d.DeviceID
        if ($d.DeviceID -eq $env:SystemDrive) { $name += ' (Windows)' }
        if ($d.VolumeName) { $name += " $($d.VolumeName)" }
        Write-Text "  $name"
        Write-Row '  Capacity' (Format-Size $d.Size)
        Write-Host ('  {0,-22} {1,-10} ' -f '  Used', (Format-Size $used)) -NoNewline
        Write-Bar $pct
        Write-Host " $pct%"
        Write-Row '  Free' (Format-Size $d.FreeSpace)
        if ($d.DeviceID -eq $env:SystemDrive -and $pct -ge 90) {
            Write-Warn 'The Windows drive is almost full. Updates fail and Windows slows down below ~10% free.'
        }
    }
}

# ---------------------------------------------------------------------------
# Memory (RAM) overview
# ---------------------------------------------------------------------------

function Show-Memory {
    $os = Get-CimInstance Win32_OperatingSystem
    $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $total = [double]$os.TotalVisibleMemorySize * 1024
    $available = [double]$perf.AvailableBytes
    $used = $total - $available
    $cached = [double]$perf.StandbyCacheCoreBytes + $perf.StandbyCacheNormalPriorityBytes +
        $perf.StandbyCacheReserveBytes + $perf.ModifiedPageListBytes
    $pct = [int][math]::Floor($used * 100 / $total)
    $commitPct = [int][math]::Floor($perf.CommittedBytes * 100 / $perf.CommitLimit)
    $availPct = [int][math]::Floor($available * 100 / $total)

    $compressed = 0
    $mc = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
    if ($mc) { $compressed = $mc.WorkingSet64 }
    $pageUsed = 0
    $pageSize = 0
    foreach ($p in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
        $pageUsed += [double]$p.CurrentUsage * 1MB
        $pageSize += [double]$p.AllocatedBaseSize * 1MB
    }

    Write-Section 'Memory (RAM)'
    Write-Row 'Physical memory' (Format-Size $total)
    Write-Host ('  {0,-22} {1,-10} ' -f 'In use', (Format-Size $used)) -NoNewline
    Write-Bar $pct
    Write-Host " $pct%"
    if ($compressed) { Write-Row '  Compressed' (Format-Size $compressed) }
    Write-Row -Label 'Cached' -Value (Format-Size $cached) -Hint '(freed instantly when apps need it)'
    Write-Row 'Available' (Format-Size $available)
    Write-Row -Label 'Committed' -Value ('{0} of {1}' -f (Format-Size $perf.CommittedBytes), (Format-Size $perf.CommitLimit)) -Hint "($commitPct%, RAM + page file)"
    Write-Row 'Page file used' ('{0} of {1}' -f (Format-Size $pageUsed), (Format-Size $pageSize))

    Write-Host ('  {0,-22} ' -f 'Memory pressure') -NoNewline
    $high = $availPct -lt 10 -or $commitPct -ge 90
    $elevated = $availPct -lt 20 -or $commitPct -ge 80
    if ($high) { Write-Text 'High' Red -NoNewline }
    elseif ($elevated) { Write-Text 'Elevated' DarkYellow -NoNewline }
    else { Write-Text 'Normal' Green -NoNewline }
    Write-Text " ($availPct% available)" DarkGray

    Write-Host ''
    Write-Text '  Top apps by memory' '' -NoNewline
    Write-Text ' (working set, approximate)' DarkGray
    Get-Process | Where-Object { $_.Id -ne 0 } | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Count = $_.Count
            Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
        }
    } | Sort-Object Bytes -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Host ('    {0,-10} {1}' -f (Format-Size $_.Bytes), $_.Name) -NoNewline
        if ($_.Count -gt 1) { Write-Text " ($($_.Count) processes)" DarkGray } else { Write-Host '' }
    }

    if ($high -or $elevated) {
        Write-Warn 'Your PC is short on memory. Close apps at the top of this list, or restart.'
    } else {
        Write-Note 'High "in use" memory is normal. Only memory pressure tells you if RAM is a problem.'
    }
}

# ---------------------------------------------------------------------------
# Space hogs
# ---------------------------------------------------------------------------

function Add-Item {
    param(
        [string]$Id,
        [string]$Safety,
        [string]$Label,
        [string]$Note,
        [bool]$Cleanable,
        [string[]]$Paths = @(),
        [switch]$Admin
    )
    $Items.Add([pscustomobject]@{
            Id        = $Id
            Safety    = $Safety
            Label     = $Label
            Note      = $Note
            Cleanable = $Cleanable
            Admin     = [bool]$Admin
            Paths     = @($Paths | Where-Object { $_ })
            Bytes     = [long]-1
        })
}

# Expand wildcard patterns (browser profiles, WSL distros) into existing paths.
function Resolve-Pattern([string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if ($p.Contains('*')) {
            Get-Item -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        } else {
            $p
        }
    }
}

function Get-KnownFolder([string]$Guid, [string]$Fallback) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $value = (Get-ItemProperty -Path $key -Name $Guid -ErrorAction SilentlyContinue).$Guid
    if ($value) { return $value }
    return $Fallback
}

function Initialize-Item {
    $L = $env:LOCALAPPDATA
    $R = $env:APPDATA
    $U = $env:USERPROFILE
    $W = $env:windir
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:Downloads = Get-KnownFolder '{374DE290-123F-4565-9164-39C4925E467B}' (Join-Path $U 'Downloads')
    $script:Desktop = [Environment]::GetFolderPath('Desktop')

    $browserCaches = @(
        "$L\Google\Chrome\User Data\*\Cache"
        "$L\Google\Chrome\User Data\*\Code Cache"
        "$L\Microsoft\Edge\User Data\*\Cache"
        "$L\Microsoft\Edge\User Data\*\Code Cache"
        "$L\BraveSoftware\Brave-Browser\User Data\*\Cache"
        "$L\BraveSoftware\Brave-Browser\User Data\*\Code Cache"
        "$L\Mozilla\Firefox\Profiles\*\cache2"
    )
    $appCaches = @(
        "$R\Code\Cache", "$R\Code\CachedData", "$R\Code\CachedExtensionVSIXs"
        "$R\Cursor\Cache", "$R\Cursor\CachedData"
        "$R\Slack\Cache", "$R\Slack\Service Worker\CacheStorage"
        "$R\discord\Cache"
    )
    $systemCaches = @(
        "$L\Temp", "$L\CrashDumps", "$L\D3DSCache", "$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache"
        "$L\Microsoft\Windows\INetCache"
        "$L\Microsoft\Windows\WER\ReportArchive", "$L\Microsoft\Windows\WER\ReportQueue"
    )
    $adminDumps = @("$W\Minidump", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")

    # The only folders whose contents storage-doctor will ever delete. Exact matches only.
    $cleanable = @($browserCaches + $appCaches + $systemCaches + $adminDumps + @(
            "$W\Temp", "$W\SoftwareDistribution\Download"
            "$L\pip\Cache", "$L\Yarn\Cache", "$U\.gradle\caches", "$U\.m2\repository"
            "$U\.cargo\registry\cache", "$U\.cargo\registry\src", "$U\.bun\install\cache"
        ))
    foreach ($p in (Resolve-Pattern $cleanable)) { [void]$Allowed.Add([IO.Path]::GetFullPath($p).TrimEnd('\')) }
    [void]$AllowedFiles.Add([IO.Path]::GetFullPath("$W\MEMORY.DMP"))

    $recycle = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { "$($_.DeviceID)\`$Recycle.Bin\$sid" }

    Add-Item -Id user_temp -Safety SAFE -Label 'Temporary files' -Note 'Leftovers from installers and apps. Files still in use are skipped.' -Cleanable $true -Paths "$L\Temp"
    Add-Item -Id recycle_bin -Safety SAFE -Label 'Recycle Bin' -Note 'Things you already deleted. Emptying it is permanent.' -Cleanable $true -Paths $recycle
    Add-Item -Id browser_caches -Safety SAFE -Label 'Browser caches (Chrome, Edge, Brave, Firefox)' -Note 'Web page caches. Close the browser before cleaning.' -Cleanable $true -Paths (Resolve-Pattern $browserCaches)
    Add-Item -Id app_caches -Safety SAFE -Label 'Desktop app web caches (VS Code, Cursor, Slack, Discord)' -Note 'Close these apps before cleaning.' -Cleanable $true -Paths $appCaches
    Add-Item -Id windows_caches -Safety SAFE -Label 'Windows caches and crash reports' -Note 'Shader caches, web cache, crash dumps and error reports. Rebuilt as needed.' -Cleanable $true -Paths ($systemCaches | Where-Object { $_ -ne "$L\Temp" })

    Add-Item -Id npm -Safety SAFE -Label 'npm cache' -Note 'Packages are downloaded again when needed.' -Cleanable (Test-Command npm) -Paths "$L\npm-cache"
    Add-Item -Id pnpm -Safety SAFE -Label 'pnpm store' -Note "Clean runs 'pnpm store prune', which only drops packages no project uses." -Cleanable (Test-Command pnpm) -Paths "$L\pnpm\store"
    Add-Item -Id yarn -Safety SAFE -Label 'Yarn cache' -Note 'Packages are downloaded again when needed.' -Cleanable $true -Paths "$L\Yarn\Cache"
    Add-Item -Id pip -Safety SAFE -Label 'pip cache' -Note 'Packages are downloaded again when needed.' -Cleanable $true -Paths "$L\pip\Cache"
    Add-Item -Id bun -Safety SAFE -Label 'Bun cache' -Note 'Packages are downloaded again when needed.' -Cleanable $true -Paths "$U\.bun\install\cache"
    Add-Item -Id nuget -Safety SAFE -Label 'NuGet packages' -Note "Clean runs 'dotnet nuget locals all --clear'. Packages are restored on the next build." -Cleanable (Test-Command dotnet) -Paths "$U\.nuget\packages"
    Add-Item -Id go_mod -Safety SAFE -Label 'Go module cache' -Note 'Modules are downloaded again when needed.' -Cleanable (Test-Command go) -Paths "$U\go\pkg\mod"
    Add-Item -Id cargo -Safety SAFE -Label 'Cargo registry cache' -Note 'Crates are downloaded again when needed.' -Cleanable $true -Paths "$U\.cargo\registry\cache", "$U\.cargo\registry\src"
    Add-Item -Id gradle -Safety SAFE -Label 'Gradle caches' -Note 'Dependencies are downloaded again. Stop Gradle daemons first.' -Cleanable $true -Paths "$U\.gradle\caches"
    Add-Item -Id maven -Safety CAUTION -Label 'Maven local repository' -Note "Also holds artifacts you built with 'mvn install', which are not re-downloadable." -Cleanable $true -Paths "$U\.m2\repository"
    Add-Item -Id docker -Safety CAUTION -Label 'Docker Desktop data' -Note "Clean runs 'docker system prune': stopped containers, dangling images, build cache. Volumes are kept." -Cleanable (Test-Command docker) -Paths "$L\Docker\wsl"

    Add-Item -Id system_temp -Safety SAFE -Label 'Windows temporary files' -Note 'System-wide temp folder. Files still in use are skipped.' -Cleanable $true -Paths "$W\Temp" -Admin
    Add-Item -Id windows_update -Safety SAFE -Label 'Windows Update downloads' -Note 'Already installed update files. Windows Update is paused while cleaning.' -Cleanable $true -Paths "$W\SoftwareDistribution\Download" -Admin
    Add-Item -Id delivery_opt -Safety SAFE -Label 'Delivery Optimization cache' -Note 'Update pieces shared with other PCs. Re-downloaded if needed.' -Cleanable (Test-Command Delete-DeliveryOptimizationCache) -Paths "$W\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" -Admin
    Add-Item -Id crash_dumps -Safety SAFE -Label 'System crash dumps' -Note 'Only useful for diagnosing a past blue screen.' -Cleanable $true -Paths (@("$W\MEMORY.DMP") + $adminDumps) -Admin
    Add-Item -Id windows_old -Safety CAUTION -Label 'Previous Windows installation (Windows.old)' -Note 'Remove it in Settings > System > Storage > Temporary files. You cannot roll back afterwards.' -Cleanable $false -Paths "$env:SystemDrive\Windows.old" -Admin

    Add-Item -Id wsl -Safety REVIEW -Label 'WSL Linux distros' -Note "Your Linux files. 'wsl --unregister <name>' removes an unused distro and everything in it." -Cleanable $false -Paths (Resolve-Pattern @("$L\Packages\*\LocalState\ext4.vhdx", "$L\wsl\*\ext4.vhdx"))
    Add-Item -Id virtualbox -Safety REVIEW -Label 'VirtualBox VMs' -Note 'Delete VMs you no longer use from VirtualBox itself.' -Cleanable $false -Paths "$U\VirtualBox VMs"
    Add-Item -Id android_avd -Safety REVIEW -Label 'Android emulators' -Note 'Delete emulators you no longer use in Android Studio > Device Manager.' -Cleanable $false -Paths "$U\.android\avd"
    Add-Item -Id android_images -Safety REVIEW -Label 'Android system images' -Note 'Uninstall unused API levels in Android Studio > SDK Manager.' -Cleanable $false -Paths "$L\Android\Sdk\system-images"
    Add-Item -Id downloads -Safety REVIEW -Label 'Downloads folder' -Note 'Your files. Sort by size in Explorer and remove what you no longer need.' -Cleanable $false -Paths $script:Downloads

    Initialize-Installer
}

# Installers are measured file by file, so they get a precomputed size.
function Initialize-Installer {
    $files = @(foreach ($root in @($script:Downloads, $script:Desktop)) {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
            Get-ChildItem -LiteralPath $root -File -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -in '.msi', '.msix', '.msixbundle', '.iso' -or
                ($_.Extension -eq '.exe' -and $_.Name -match 'setup|install')
            }
        })
    if ($files.Count -eq 0) { return }
    $script:InstallerFiles = @($files | ForEach-Object { $_.FullName })
    Add-Item -Id installers -Safety CAUTION -Label "Installer files ($($files.Count) .msi/.iso/setup.exe)" -Note 'Rarely needed after installing. Clean moves them to the Recycle Bin, so it can be undone.' -Cleanable $true
    $Items[$Items.Count - 1].Bytes = [long]($files | Measure-Object Length -Sum).Sum
}

function Measure-Item {
    $n = 0
    foreach ($item in $Items) {
        $n++
        if ($item.Bytes -ge 0) { continue }
        Write-Progress -Activity 'storage-doctor' -Status "Scanning $($item.Label)" -PercentComplete ($n * 100 / $Items.Count)
        $total = [long]0
        foreach ($p in $item.Paths) { $total += Get-PathSize $p }
        $item.Bytes = $total
    }
    Write-Progress -Activity 'storage-doctor' -Completed
}

function Get-VisibleItem { $Items | Where-Object { $_.Bytes -ge 1MB } | Sort-Object Bytes -Descending }

function Show-Item {
    Write-Section 'Space hogs'
    Write-Text ('  {0,-10} {1,-7}  {2}' -f 'SIZE', 'SAFETY', 'WHAT') DarkGray
    foreach ($item in (Get-VisibleItem)) {
        Write-Host ('  {0,-10} ' -f (Format-Size $item.Bytes)) -NoNewline
        Write-Badge $item.Safety
        Write-Text "  $($item.Label)"
        $note = $item.Note
        if ($item.Admin) { $note = "[admin] $note" }
        Write-Text ('  {0,-18}  {1}' -f '', $note) DarkGray
        if ($item.Paths.Count -gt 0) { Write-Text ('  {0,-18}  {1}' -f '', (Format-Path $item.Paths[0])) DarkGray }
    }
    if (-not $IsAdmin) {
        Write-Note 'Run as administrator to also measure system caches (Windows Update, crash dumps, Windows.old).'
    }
}

# ---------------------------------------------------------------------------
# Detailed scans (skipped with -Quick)
# ---------------------------------------------------------------------------

function Get-CacheHint([string]$Name) {
    switch ($Name) {
        'npm-cache' { return 'npm cache clean --force' }
        'pip' { return 'pip cache purge' }
        'Temp' { return 'temporary files' }
        'NVIDIA' { return 'shader caches are safe' }
        'ms-playwright' { return "browsers for Playwright, 'npx playwright install' restores them" }
        'JetBrains' { return 'folders of old IDE versions can go' }
        'Docker' { return 'Docker Desktop data, see above' }
        'Packages' { return 'Microsoft Store apps and WSL distros' }
    }
    return ''
}

function Show-Breakdown([string]$Dir, [int]$Count) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return }
    Write-Progress -Activity 'storage-doctor' -Status "Scanning $(Format-Path $Dir)"
    $rows = Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ([int]$_.Attributes -band $ReparsePoint) } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = Get-PathSize $_.FullName } } |
        Sort-Object Bytes -Descending | Select-Object -First $Count
    Write-Progress -Activity 'storage-doctor' -Completed
    Write-Host ''
    Write-Text "  $(Format-Path $Dir)"
    foreach ($r in $rows) {
        Write-Host ('    {0,-10} {1}' -f (Format-Size $r.Bytes), $r.Name) -NoNewline
        $hint = Get-CacheHint $r.Name
        if ($hint) { Write-Text " ($hint)" DarkGray } else { Write-Host '' }
    }
}

function Show-AppDataBreakdown {
    Write-Section 'Where the space inside AppData goes'
    Show-Breakdown $env:LOCALAPPDATA 8
    Show-Breakdown $env:APPDATA 8
    Write-Note 'AppData holds app data (settings, databases). Folders of apps you already'
    Write-Note 'uninstalled can be removed, but check first. storage-doctor never cleans these folders.'
}

function Show-DevProject {
    $U = $env:USERPROFILE
    $candidates = @("$U\dev", "$U\source\repos", "$U\Projects", "$U\code", "$U\workspace",
        "$U\src", "$U\git", "$U\Documents\GitHub") + $ExtraDevDirs
    $roots = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
    if ($roots.Count -eq 0) { return }

    Write-Progress -Activity 'storage-doctor' -Status 'Scanning node_modules and Python virtualenvs'
    $found = @(Find-DependencyFolder $roots | Sort-Object -Unique | ForEach-Object {
            [pscustomobject]@{ Path = $_; Bytes = Get-PathSize $_ }
        } | Sort-Object Bytes -Descending)
    Write-Progress -Activity 'storage-doctor' -Completed
    if ($found.Count -eq 0) { return }

    Write-Section 'Dev project dependencies'
    $total = ($found | Measure-Object Bytes -Sum).Sum
    Write-Text "  $(Format-Size $total) in $($found.Count) folders" '' -NoNewline
    Write-Text ' (node_modules, Python venvs)' DarkGray
    foreach ($f in ($found | Select-Object -First 8)) {
        Write-Host ('    {0,-10} {1}' -f (Format-Size $f.Bytes), (Format-Path $f.Path))
    }
    Write-Note "REVIEW: reinstallable with 'npm install' / 'pip install -r ...', but only remove them for"
    Write-Note "projects you are not working on. 'npx npkill' lets you pick them interactively."
}

function Show-LargeFile {
    Write-Progress -Activity 'storage-doctor' -Status "Scanning for files larger than $LargeMB MB"
    $files = @(Find-LargeFile $env:USERPROFILE $LargeBytes | Sort-Object Bytes -Descending | Select-Object -First 15)
    Write-Progress -Activity 'storage-doctor' -Completed
    if ($files.Count -eq 0) { return }

    Write-Section "Large files (> $LargeMB MB)"
    Write-Text ('  {0,-10} {1,-11} {2}' -f 'SIZE', 'MODIFIED', 'FILE') DarkGray
    foreach ($f in $files) {
        Write-Host ('  {0,-10} {1,-11} {2}' -f (Format-Size $f.Bytes), $f.Modified.ToString('yyyy-MM-dd'), (Format-Path $f.Path))
    }
    Write-Note 'REVIEW: these are your files. Old videos, disk images and archives are the usual suspects.'
}

# ---------------------------------------------------------------------------
# Things Windows manages itself
# ---------------------------------------------------------------------------

function Show-SystemInfo {
    Write-Section 'Managed by Windows (do not delete by hand)'
    foreach ($name in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') {
        $f = Get-Item -LiteralPath "$env:SystemDrive\$name" -Force -ErrorAction SilentlyContinue
        if ($null -eq $f) { continue }
        Write-Row $name (Format-Size $f.Length)
        switch ($name) {
            'pagefile.sys' { Write-Note 'Virtual memory. Windows sizes it automatically.' }
            'hiberfil.sys' { Write-Note "Hibernation. 'powercfg /hibernate off' (admin) frees it, but also disables Fast Startup." }
            'swapfile.sys' { Write-Note 'Used by Store apps. Managed by Windows.' }
        }
    }
    Write-Row 'WinSxS' 'Windows component store'
    Write-Note 'Looks huge in Explorer because of hard links. Never delete it by hand; as admin, run'
    Write-Note "'Dism /Online /Cleanup-Image /StartComponentCleanup' to trim old versions."
    Write-Row 'Restore points' 'System Protection'
    Write-Note 'Manage their size in Control Panel > System > System Protection > Configure.'
    Write-Row 'Storage Sense' 'Settings > System > Storage'
    Write-Note 'Can empty temp files and the Recycle Bin for you on a schedule.'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Show-Summary {
    $visible = @(Get-VisibleItem)
    $sum = @{ SAFE = [long]0; CAUTION = [long]0; REVIEW = [long]0 }
    foreach ($item in $visible) { $sum[$item.Safety] += $item.Bytes }

    Write-Section 'Summary'
    $lines = @(
        @('SAFE', 'regenerated automatically, no data loss'),
        @('CAUTION', 'regenerable, read the note first'),
        @('REVIEW', 'your data, check by hand (never cleaned by storage-doctor)')
    )
    foreach ($l in $lines) {
        Write-Host '  ' -NoNewline
        Write-Badge $l[0]
        Write-Text ('  {0,-10}' -f (Format-Size $sum[$l[0]])) '' -NoNewline
        Write-Host " $($l[1])"
    }
    if (-not $DoClean) {
        Write-Host ''
        Write-Host '  Run again with -Clean to clean SAFE and CAUTION items (asks for each one),'
        Write-Host '  or with -DryRun to preview without changing anything.'
    }
}

# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

# Delete a file or folder without ever following a junction or symlink into
# somewhere else. Files that are in use or locked are left alone.
function Remove-Entry([System.IO.FileSystemInfo]$Entry) {
    try {
        if ($Entry -is [System.IO.DirectoryInfo]) {
            if ([int]$Entry.Attributes -band $ReparsePoint) {
                [System.IO.Directory]::Delete($Entry.FullName, $false)   # removes the link only
                return
            }
            foreach ($child in $Entry.GetFileSystemInfos()) { Remove-Entry $child }
            $Entry.Attributes = [System.IO.FileAttributes]::Directory
            $Entry.Delete($false)
        } else {
            $Entry.Attributes = [System.IO.FileAttributes]::Normal
            $Entry.Delete()
        }
    } catch {
        Write-Verbose "skipped $($Entry.FullName): $($_.Exception.Message)"
    }
}

# Delete the contents of a folder (not the folder itself), only if it is on the allowlist.
function Clear-FolderContent([string]$Dir) {
    $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    if (-not $Allowed.Contains($full)) {
        Write-Warn "refusing to touch $Dir (not on the allowlist)"
        return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
    $info = New-Object System.IO.DirectoryInfo $full
    if ([int]$info.Attributes -band $ReparsePoint) {
        Write-Warn "refusing to touch $Dir (it is a link)"
        return
    }
    if ($DryRunMode) {
        Write-Note "would delete the contents of $(Format-Path $full)"
        return
    }
    try { $entries = $info.GetFileSystemInfos() } catch { Write-Warn "cannot read $Dir"; return }
    foreach ($e in $entries) { Remove-Entry $e }
}

function Remove-AllowedFile([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $AllowedFiles.Contains($full)) {
        Write-Warn "refusing to touch $Path (not on the allowlist)"
        return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    if ($DryRunMode) { Write-Note "would delete $full"; return }
    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
}

function Invoke-Tool([string]$File, [string[]]$Arguments) {
    if ($DryRunMode) {
        Write-Note "would run: $File $($Arguments -join ' ')"
        return
    }
    & $File @Arguments
}

function Clear-RecycleBinSafe {
    if ($DryRunMode) { Write-Note 'would empty the Recycle Bin'; return }
    # Clear-RecycleBin is missing in PowerShell 7, the shell API works everywhere.
    if (-not ('StorageDoctor.Shell' -as [type])) {
        Add-Type -Namespace StorageDoctor -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);
'@
    }
    # 7 = no confirmation, no progress UI, no sound
    [void][StorageDoctor.Shell]::SHEmptyRecycleBin([IntPtr]::Zero, $null, 7)
}

function Move-InstallerToRecycleBin {
    Add-Type -AssemblyName Microsoft.VisualBasic
    foreach ($f in $script:InstallerFiles) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if ($DryRunMode) { Write-Note "would move to Recycle Bin: $(Format-Path $f)"; continue }
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } catch {
            Write-Warn "could not move $(Format-Path $f) to the Recycle Bin"
        }
    }
}

function Clear-WindowsUpdateCache {
    $services = @(Get-Service wuauserv, bits -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    if ($DryRunMode) {
        Write-Note 'would pause Windows Update, empty its download folder and start it again'
        return
    }
    $services | Stop-Service -Force -ErrorAction SilentlyContinue
    Clear-FolderContent "$env:windir\SoftwareDistribution\Download"
    $services | Start-Service -ErrorAction SilentlyContinue
}

function Invoke-ItemClean($Item) {
    switch ($Item.Id) {
        'recycle_bin' { Clear-RecycleBinSafe }
        'npm' { Invoke-Tool npm @('cache', 'clean', '--force') }
        'pnpm' { Invoke-Tool pnpm @('store', 'prune') }
        'go_mod' { Invoke-Tool go @('clean', '-modcache') }
        'nuget' { Invoke-Tool dotnet @('nuget', 'locals', 'all', '--clear') }
        'docker' {
            & docker info *> $null
            if ($LASTEXITCODE -ne 0) { Write-Warn 'Docker is not running. Start Docker Desktop and try again.'; return }
            Invoke-Tool docker @('system', 'prune', '--force')
        }
        'delivery_opt' {
            if ($DryRunMode) { Write-Note 'would run: Delete-DeliveryOptimizationCache -Force'; return }
            Delete-DeliveryOptimizationCache -Force
        }
        'windows_update' { Clear-WindowsUpdateCache }
        'installers' { Move-InstallerToRecycleBin }
        'crash_dumps' {
            foreach ($p in $Item.Paths) {
                if ($p -like '*.DMP') { Remove-AllowedFile $p } else { Clear-FolderContent $p }
            }
        }
        default { foreach ($p in $Item.Paths) { Clear-FolderContent $p } }
    }
}

function Invoke-Clean {
    Write-Section 'Clean up'
    if ([Console]::IsInputRedirected) {
        Write-Warn '-Clean needs an interactive console to ask for confirmation.'
        return
    }
    if ($DryRunMode) {
        Write-Note 'Dry run: nothing will be changed.'
    } else {
        Write-Note 'Close the apps whose caches you clean. Answer y to clean an item, anything else skips it.'
    }

    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $before = $drive.FreeSpace
    $cleaned = 0
    foreach ($item in (Get-VisibleItem)) {
        if (-not $item.Cleanable -or $item.Safety -eq 'REVIEW') { continue }
        Write-Host ''
        Write-Host '  ' -NoNewline
        Write-Badge $item.Safety
        Write-Text "  $($item.Label)" '' -NoNewline
        Write-Host " ($(Format-Size $item.Bytes))"
        Write-Note $item.Note
        if ($item.Admin -and -not $IsAdmin) {
            Write-Warn 'skipped: needs "Run as administrator"'
            continue
        }
        $answer = Read-Host '  Clean it? [y/N]'
        if ($answer -match '^(y|yes)$') {
            Invoke-ItemClean $item
            $cleaned++
        }
    }

    if ($DryRunMode) { return }
    $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
    Write-Host ''
    Write-Host ('  Cleaned {0} item(s). Free space on {1} went from {2} to {3}.' -f $cleaned, $env:SystemDrive, (Format-Size $before), (Format-Size $after))
}

# ---------------------------------------------------------------------------
# Main. Dot-sourcing the script (". .\storage-doctor.ps1") only loads the
# functions, which is handy for testing.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Version) { "storage-doctor $ScriptVersion (Windows)"; return }
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'This is the Windows version. On macOS, run macos/storage-doctor.sh with bash instead.'
    exit 1
}

$IsAdmin = Test-Admin
$os = Get-CimInstance Win32_OperatingSystem
Write-Text "storage-doctor $ScriptVersion" '' -NoNewline
Write-Text " - $env:COMPUTERNAME, $($os.Caption) $($os.Version)" DarkGray
Write-Note 'Read-only scan. Nothing is deleted unless you run -Clean and confirm.'
if ($IsAdmin) { Write-Note 'Running as administrator: system caches are included.' }

Show-Disk
Show-Memory
Initialize-Item
Measure-Item
Show-Item
if (-not $Quick) {
    Show-AppDataBreakdown
    Show-DevProject
    Show-LargeFile
}
Show-SystemInfo
Show-Summary
if ($DoClean) { Invoke-Clean }
