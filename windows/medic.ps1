<#
.SYNOPSIS
    medic for Windows - see what is filling up your PC and what is safe to clean.

.DESCRIPTION
    Read-only by default: nothing is deleted unless you run "medic clean" or
    "medic purge" and confirm. Only SAFE and CAUTION items can ever be cleaned.
    REVIEW items (your personal data) are reported, never touched.

    Commands (the first argument):
      report    Full report (default)
      disk      Disk, space hogs, delete commands, dev folders and large files
      memory    Memory use and the apps using the most
      clean     Pick SAFE and CAUTION items to clean
      purge     Pick dependency and build folders of inactive projects to delete
      check     Exit with 1 when the disk is almost full or memory is critical

    Exit codes: 0 ok, 1 error or failed check, 2 wrong usage.

    Runs on the Windows PowerShell 5.1 that ships with Windows 10 and 11, and on
    PowerShell 7. No dependencies. The macOS version lives in macos/medic.sh.

    Safety levels:
      SAFE      Regenerated automatically. No data loss.
      CAUTION   Regenerable, but you lose more than a cache (stopped containers,
                locally installed artifacts) or it costs a long rebuild.
      REVIEW    May contain personal data. Reported only, never deleted.

.EXAMPLE
    medic
    Full read-only report, once medic is installed (see the README).

.EXAMPLE
    medic clean -DryRun
    Pick items to clean and show what would happen, change nothing.

.EXAMPLE
    medic clean -Yes -Only safe
    Clean every SAFE item without asking, for scripts.

.EXAMPLE
    medic check -MinFree 20G
    Exit with 1 when the system drive has less than 20 GB free.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\medic.ps1
    Full read-only report, running the downloaded script directly.

.LINK
    https://github.com/f-bahesna/medic
#>
[CmdletBinding()]
param(
    # report (default), disk, memory, clean, purge or check.
    [Parameter(Position = 0)]
    [string]$Command = '',
    # Print JSON instead of text (report, disk, memory, purge, check).
    [switch]$Json,
    # Skip the slow scans (breakdowns, dev folders, large files).
    [switch]$Quick,
    # Report files bigger than this many megabytes.
    [ValidateRange(1, 10485760)]
    [int]$LargeMB = 500,
    # Extra project folders to scan.
    [string[]]$DevDir = @(),
    # clean, purge: show what would happen, change nothing.
    [switch]$DryRun,
    # clean, purge: do not ask, take every listed item.
    [switch]$Yes,
    # clean: only these levels (safe, caution) or item ids, comma-separated. With -Yes the default is safe.
    [string]$Only = '',
    # purge: only projects with no file changed in this many days (0 for all).
    [ValidateRange(0, 36500)]
    [int]$OlderThan = 30,
    # check: free space needed on the system drive, like 20G, 500M or 10%.
    [string]$MinFree = '10%',
    # Disable colored output (NO_COLOR is honored too).
    [switch]$NoColor,
    # Show the version and exit.
    [switch]$Version,
    # Before 0.4: same as "clean".
    [switch]$Clean
)

Set-StrictMode -Version 2.0

$ScriptVersion = '0.4.0'
$Cmd = $Command.ToLowerInvariant()
if ($Cmd -eq 'ram') { $Cmd = 'memory' }
if (-not $Cmd -and ($Clean -or $DryRun)) { $Cmd = 'clean' }   # before 0.4 cleaning was -Clean or -DryRun
if (-not $Cmd) { $Cmd = 'report' }
$DryRunMode = [bool]$DryRun
$AssumeYes = [bool]$Yes
$PurgeDays = $OlderThan
$MinFreeText = $MinFree
$SkipSlowScans = [bool]$Quick
$LargeBytes = [long]$LargeMB * 1MB
$ExtraDevDirs = @($DevDir)
$UseColor = -not $NoColor -and -not $env:NO_COLOR -and -not $Json
$Failed = $false
$OnlyTokens = @($Only.ToLowerInvariant() -split '[,\s]+' | Where-Object { $_ })

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

function Get-UserSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

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

function Get-DiskInfo {
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID)) {
        if (-not $d.Size) { continue }
        $used = [long]($d.Size - $d.FreeSpace)
        [pscustomobject]@{
            Name       = $d.DeviceID
            VolumeName = $d.VolumeName
            System     = ($d.DeviceID -eq $env:SystemDrive)
            Total      = [long]$d.Size
            Used       = $used
            Free       = [long]$d.FreeSpace
            Pct        = [int][math]::Floor($used * 100 / $d.Size)
        }
    }
}

function Show-Disk($Disks) {
    Write-Section 'Disk'
    foreach ($d in $Disks) {
        $name = $d.Name
        if ($d.VolumeName) { $name += " $($d.VolumeName)" }
        if ($d.System) { $name += ' (system drive)' }
        Write-Text "  $name"
        Write-Row '  Capacity' (Format-Size $d.Total)
        Write-Host ('  {0,-22} {1,-10} ' -f '  Used', (Format-Size $d.Used)) -NoNewline
        Write-Bar $d.Pct
        Write-Host " $($d.Pct)%"
        Write-Row '  Free' (Format-Size $d.Free)
        if ($d.System -and $d.Pct -ge 90) {
            Write-Warn 'The Windows drive is almost full. Updates fail and Windows slows down below ~10% free.'
        }
    }
}

# ---------------------------------------------------------------------------
# Memory (RAM) overview
# ---------------------------------------------------------------------------

function Get-MemoryInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $total = [double]$os.TotalVisibleMemorySize * 1024
    $available = [double]$perf.AvailableBytes
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

    $pressure = 'normal'
    if ($availPct -lt 10 -or $commitPct -ge 90) { $pressure = 'critical' }
    elseif ($availPct -lt 20 -or $commitPct -ge 80) { $pressure = 'warning' }

    $apps = @(Get-Process | Where-Object { $_.Id -ne 0 } | Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{
                Name  = $_.Name
                Count = $_.Count
                Bytes = [long]($_.Group | Measure-Object WorkingSet64 -Sum).Sum
            }
        } | Sort-Object Bytes -Descending | Select-Object -First 8)

    [pscustomobject]@{
        Total       = $total
        Used        = $total - $available
        Available   = $available
        Cached      = [double]$perf.StandbyCacheCoreBytes + $perf.StandbyCacheNormalPriorityBytes +
        $perf.StandbyCacheReserveBytes + $perf.ModifiedPageListBytes
        Compressed  = $compressed
        Committed   = [double]$perf.CommittedBytes
        CommitLimit = [double]$perf.CommitLimit
        CommitPct   = $commitPct
        AvailPct    = $availPct
        PageUsed    = $pageUsed
        PageSize    = $pageSize
        Pressure    = $pressure
        TopApps     = $apps
    }
}

function Show-Memory($Mem) {
    $pct = [int][math]::Floor($Mem.Used * 100 / $Mem.Total)
    Write-Section 'Memory (RAM)'
    Write-Row 'Physical memory' (Format-Size $Mem.Total)
    Write-Host ('  {0,-22} {1,-10} ' -f 'In use', (Format-Size $Mem.Used)) -NoNewline
    Write-Bar $pct
    Write-Host " $pct%"
    if ($Mem.Compressed) { Write-Row '  Compressed' (Format-Size $Mem.Compressed) }
    Write-Row -Label 'Cached' -Value (Format-Size $Mem.Cached) -Hint '(freed instantly when apps need it)'
    Write-Row 'Available' (Format-Size $Mem.Available)
    Write-Row -Label 'Committed' -Value ('{0} of {1}' -f (Format-Size $Mem.Committed), (Format-Size $Mem.CommitLimit)) -Hint "($($Mem.CommitPct)%, RAM + page file)"
    Write-Row 'Page file used' ('{0} of {1}' -f (Format-Size $Mem.PageUsed), (Format-Size $Mem.PageSize))

    Write-Host ('  {0,-22} ' -f 'Memory pressure') -NoNewline
    switch ($Mem.Pressure) {
        'critical' { Write-Text 'High' Red -NoNewline }
        'warning' { Write-Text 'Elevated' DarkYellow -NoNewline }
        default { Write-Text 'Normal' Green -NoNewline }
    }
    Write-Text " ($($Mem.AvailPct)% available)" DarkGray

    Write-Host ''
    Write-Text '  Top apps by memory' '' -NoNewline
    Write-Text ' (working set, approximate)' DarkGray
    foreach ($app in $Mem.TopApps) {
        Write-Host ('    {0,-10} {1}' -f (Format-Size $app.Bytes), $app.Name) -NoNewline
        if ($app.Count -gt 1) { Write-Text " ($($app.Count) processes)" DarkGray } else { Write-Host '' }
    }

    if ($Mem.Pressure -ne 'normal') {
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
    $sid = Get-UserSid
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

    # The only folders whose contents medic will ever delete. Exact matches only.
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
        Write-Progress -Activity 'medic' -Status "Scanning $($item.Label)" -PercentComplete ($n * 100 / $Items.Count)
        $total = [long]0
        foreach ($p in $item.Paths) { $total += Get-PathSize $p }
        $item.Bytes = $total
    }
    Write-Progress -Activity 'medic' -Completed
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

# Pasted once before the Clear-Folder commands. Remove-Item -Recurse is avoided on
# purpose: Windows PowerShell 5.1 follows junctions with it. rd removes a link
# without entering it.
$ClearFolderHelper = 'function Clear-Folder($Path) { Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { cmd /c rd "$($_.FullName)" } elseif ($_.PSIsContainer) { cmd /c rd /s /q "$($_.FullName)" 2>$null } else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } } }'

# Show a path the way it is typed in PowerShell, so the command works on any PC.
function Format-EnvPath([string]$Path) {
    foreach ($name in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'ProgramData', 'windir', 'SystemDrive') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $Path.StartsWith($value, [StringComparison]::OrdinalIgnoreCase)) {
            return '$env:' + $name + $Path.Substring($value.Length)
        }
    }
    return $Path
}

# The commands that clean an item by hand, one per line. Mirrors Invoke-ItemClean;
# for folders only allowlisted ones that have contents are listed.
function Get-ItemCommand($Item) {
    switch ($Item.Id) {
        'recycle_bin' { 'powershell -NoProfile -Command "Clear-RecycleBin -Force"' }
        'npm' { 'npm cache clean --force' }
        'pnpm' { 'pnpm store prune' }
        'go_mod' { 'go clean -modcache' }
        'nuget' { 'dotnet nuget locals all --clear' }
        'docker' { 'docker system prune --force' }
        'delivery_opt' { 'Delete-DeliveryOptimizationCache -Force' }
        'installers' { }
        'windows_update' {
            'Stop-Service wuauserv, bits -Force'
            'Clear-Folder "$env:windir\SoftwareDistribution\Download"'
            'Start-Service wuauserv, bits'
        }
        default {
            foreach ($p in $Item.Paths) {
                if ($p -like '*.DMP') {
                    if (Test-Path -LiteralPath $p -PathType Leaf) { 'Remove-Item "' + (Format-EnvPath $p) + '" -Force' }
                    continue
                }
                if (-not $Allowed.Contains([IO.Path]::GetFullPath($p).TrimEnd('\'))) { continue }
                $hasContent = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hasContent) { 'Clear-Folder "' + (Format-EnvPath $p) + '"' }
            }
        }
    }
}

function Show-DeleteCommand {
    $entries = @(foreach ($item in (Get-VisibleItem)) {
            if (-not $item.Cleanable -or $item.Safety -eq 'REVIEW') { continue }
            $commands = @(Get-ItemCommand $item)
            if ($commands.Count -gt 0) { [pscustomobject]@{ Item = $item; Commands = $commands } }
        })
    if ($entries.Count -eq 0) { return }

    Write-Section 'Delete commands'
    Write-Note "Prefer 'medic clean': it asks first and only touches allowlisted folders."
    Write-Note 'To clean by hand, close the related apps and copy the commands under an item.'
    if (@($entries | Where-Object { $_.Commands -match '^Clear-Folder' }).Count -gt 0) {
        Write-Host ''
        Write-Note 'Paste this helper once per PowerShell window. It empties a folder without following links:'
        Write-Host "    $ClearFolderHelper"
    }
    foreach ($e in $entries) {
        Write-Host ''
        Write-Host '  ' -NoNewline
        Write-Badge $e.Item.Safety
        Write-Text "  $($e.Item.Label)" -NoNewline
        $hint = Format-Size $e.Item.Bytes
        if ($e.Item.Admin) { $hint += ', run as administrator' }
        Write-Text " ($hint)" DarkGray
        foreach ($c in $e.Commands) { Write-Host "    $c" }
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
    Write-Progress -Activity 'medic' -Status "Scanning $(Format-Path $Dir)"
    $rows = Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ([int]$_.Attributes -band $ReparsePoint) } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = Get-PathSize $_.FullName } } |
        Where-Object { $_.Bytes -ge 1MB } | Sort-Object Bytes -Descending | Select-Object -First $Count
    Write-Progress -Activity 'medic' -Completed
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
    Write-Note 'uninstalled can be removed, but check first. medic never cleans these folders.'
}

# The project folders that exist, each once, as full paths.
function Get-DevRoot {
    $U = $env:USERPROFILE
    $candidates = @("$U\dev", "$U\source\repos", "$U\Projects", "$U\code", "$U\workspace",
        "$U\src", "$U\git", "$U\Documents\GitHub") + $ExtraDevDirs
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
}

# node_modules and Python venvs in the project folders, biggest first.
function Get-DevFolder {
    $roots = @(Get-DevRoot)
    if ($roots.Count -eq 0) { return }
    Write-Progress -Activity 'medic' -Status 'Scanning node_modules and Python virtualenvs'
    Find-DependencyFolder $roots | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Path = $_; Bytes = Get-PathSize $_ }
    } | Sort-Object Bytes -Descending
    Write-Progress -Activity 'medic' -Completed
}

function Show-DevFolder($Found) {
    if ($Found.Count -eq 0) { return }
    Write-Section 'Dev project dependencies'
    $total = ($Found | Measure-Object Bytes -Sum).Sum
    Write-Text "  $(Format-Size $total) in $($Found.Count) folders" '' -NoNewline
    Write-Text ' (node_modules, Python venvs)' DarkGray
    foreach ($f in ($Found | Select-Object -First 8)) {
        Write-Host ('    {0,-10} {1}' -f (Format-Size $f.Bytes), (Format-Path $f.Path))
    }
    Write-Note 'REVIEW: reinstallable, but only remove them for projects you are not working on.'
    Write-Note "Run 'medic purge' to pick the ones of projects untouched for $PurgeDays days."
}

function Get-LargeFileList {
    Write-Progress -Activity 'medic' -Status "Scanning for files larger than $LargeMB MB"
    Find-LargeFile $env:USERPROFILE $LargeBytes | Sort-Object Bytes -Descending | Select-Object -First 15
    Write-Progress -Activity 'medic' -Completed
}

function Show-LargeFile($Files) {
    if ($Files.Count -eq 0) { return }
    Write-Section "Large files (> $LargeMB MB)"
    Write-Text ('  {0,-10} {1,-11} {2}' -f 'SIZE', 'MODIFIED', 'FILE') DarkGray
    foreach ($f in $Files) {
        Write-Host ('  {0,-10} {1,-11} {2}' -f (Format-Size $f.Bytes), $f.Modified.ToString('yyyy-MM-dd'), (Format-Path $f.Path))
    }
    Write-Note 'REVIEW: these are your files. Old videos, disk images and archives are the usual suspects.'
}

# ---------------------------------------------------------------------------
# Things Windows manages itself
# ---------------------------------------------------------------------------

# Page, hibernation and swap files that exist. FileInfo reads the size from the
# directory entry, which works for locked system files.
function Get-SystemFile {
    $paths = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) +
        @("$env:SystemDrive\hiberfil.sys", "$env:SystemDrive\swapfile.sys")
    foreach ($path in ($paths | Select-Object -Unique)) {
        $f = New-Object System.IO.FileInfo $path
        if ($f.Exists) { $f }
    }
}

function Show-SystemInfo {
    Write-Section 'Managed by Windows (do not delete by hand)'
    foreach ($f in @(Get-SystemFile)) {
        $name = $f.Name.ToLowerInvariant()
        Write-Row $f.FullName (Format-Size $f.Length)
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
        @('REVIEW', 'your data, check by hand (never cleaned by medic)')
    )
    foreach ($l in $lines) {
        Write-Host '  ' -NoNewline
        Write-Badge $l[0]
        Write-Text ('  {0,-10}' -f (Format-Size $sum[$l[0]])) '' -NoNewline
        Write-Host " $($l[1])"
    }
    Write-Host ''
    Write-Host '  Run ' -NoNewline
    Write-Text 'medic clean' White -NoNewline
    Write-Host ' to pick SAFE and CAUTION items to clean,'
    Write-Host '  or ' -NoNewline
    Write-Text 'medic clean -DryRun' White -NoNewline
    Write-Host ' to preview without changing anything.'
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
    if (-not ('Medic.Shell' -as [type])) {
        Add-Type -Namespace Medic -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);
'@
    }
    # 7 = no confirmation, no progress UI, no sound
    [void][Medic.Shell]::SHEmptyRecycleBin([IntPtr]::Zero, $null, 7)
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

# ---------------------------------------------------------------------------
# Picking items: numbered list, then "1,3", "2-5", "all" or a safety level
# ---------------------------------------------------------------------------

# The picked row numbers (1-based), or $null when the answer is not valid.
# Levels are the safety level of each row, for "safe" and "caution".
function Get-Selection([string]$Answer, [int]$Count, [string[]]$Levels = @()) {
    $picked = New-Object 'System.Collections.Generic.SortedSet[int]'
    foreach ($token in ($Answer.ToLowerInvariant() -split '[,\s]+' | Where-Object { $_ })) {
        if ($token -eq 'all') {
            for ($n = 1; $n -le $Count; $n++) { [void]$picked.Add($n) }
        } elseif ($token -eq 'safe' -or $token -eq 'caution') {
            if ($Levels.Count -eq 0) { return $null }
            for ($n = 1; $n -le $Count; $n++) { if ($Levels[$n - 1] -eq $token) { [void]$picked.Add($n) } }
        } elseif ($token -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
            if ($from -lt 1 -or $to -gt $Count -or $from -gt $to) { return $null }
            for ($n = $from; $n -le $to; $n++) { [void]$picked.Add($n) }
        } elseif ($token -match '^\d+$' -and [int]$token -ge 1 -and [int]$token -le $Count) {
            [void]$picked.Add([int]$token)
        } else {
            return $null
        }
    }
    return , @($picked)
}

# Ask which rows to take. Returns their 0-based indexes, or nothing on cancel.
function Read-Selection([int]$Count, [string]$Hint, [string[]]$Levels = @()) {
    while ($true) {
        Write-Host ''
        Write-Host '  Which ones? ' -NoNewline
        Write-Text "$Hint, Enter to cancel:" DarkGray -NoNewline
        $answer = Read-Host ' '
        if (-not $answer) { return $null }
        $picked = Get-Selection -Answer $answer -Count $Count -Levels $Levels
        if ($null -ne $picked -and $picked.Count -gt 0) { return , @($picked | ForEach-Object { $_ - 1 }) }
        Write-Warn "'$answer' is not a valid choice."
    }
}

function Confirm-Action([string]$Question) {
    return (Read-Host "  $Question [y/N]") -match '^(y|yes)$'
}

function Test-Interactive([string]$What) {
    if ([Console]::IsInputRedirected) {
        Write-Warn "$What needs a console to ask first. Pass -Yes to go ahead without asking."
        return $false
    }
    return $true
}

function Get-SystemDriveFree { return [long](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace }

function Write-Freed([long]$Before) {
    if ($DryRunMode) { return }
    Write-Host ''
    Write-Host ('  Free space on {0} went from {1} to {2}.' -f $env:SystemDrive, (Format-Size $Before), (Format-Size (Get-SystemDriveFree)))
}

# ---------------------------------------------------------------------------
# medic clean
# ---------------------------------------------------------------------------

# Does the item pass -Only (default: everything, or SAFE with -Yes)?
function Test-OnlyMatch($Item) {
    $tokens = $OnlyTokens
    if ($tokens.Count -eq 0 -and $AssumeYes) { $tokens = @('safe') }
    if ($tokens.Count -eq 0) { return $true }
    foreach ($t in $tokens) {
        if ($t -eq $Item.Safety.ToLowerInvariant() -or $t -eq $Item.Id) { return $true }
    }
    return $false
}

function Assert-Only {
    foreach ($t in $OnlyTokens) {
        if ($t -eq 'safe' -or $t -eq 'caution') { continue }
        $known = @($Items | Where-Object { $_.Id -eq $t -and $_.Cleanable -and $_.Safety -ne 'REVIEW' })
        if ($known.Count -eq 0) {
            Exit-Usage "-Only: '$t' is not a level (safe, caution) or a cleanable item id. 'medic report -Json' lists the ids."
        }
    }
}

function Invoke-Clean {
    $rows = @(Get-VisibleItem | Where-Object { $_.Cleanable -and $_.Safety -ne 'REVIEW' -and (Test-OnlyMatch $_) })
    Write-Section 'Clean up'
    if ($rows.Count -eq 0) { Write-Note 'Nothing to clean.'; return }

    Write-Text ('  {0,-3} {1,-10} {2,-7}  {3}' -f '#', 'SIZE', 'SAFETY', 'WHAT') DarkGray
    for ($n = 0; $n -lt $rows.Count; $n++) {
        $item = $rows[$n]
        Write-Host ('  {0,-3} {1,-10} ' -f ($n + 1), (Format-Size $item.Bytes)) -NoNewline
        Write-Badge $item.Safety
        Write-Text "  $($item.Label)"
        $note = $item.Note
        if ($item.Admin -and -not $IsAdmin) { $note = "[admin, skipped: run as administrator] $note" }
        elseif ($item.Admin) { $note = "[admin] $note" }
        Write-Text ('  {0,-22}  {1}' -f '', $note) DarkGray
    }

    if ($AssumeYes) {
        $picked = @(0..($rows.Count - 1))
    } else {
        if (-not (Test-Interactive 'clean')) { $script:Failed = $true; return }
        $levels = @($rows | ForEach-Object { $_.Safety.ToLowerInvariant() })
        $picked = Read-Selection -Count $rows.Count -Hint "numbers like 1,3 or 2-5, 'safe', 'all'" -Levels $levels
        if ($null -eq $picked) { Write-Note 'Nothing cleaned.'; return }
        if (-not $DryRunMode) {
            $total = [long]0
            foreach ($n in $picked) { $total += $rows[$n].Bytes }
            Write-Note 'Close the apps whose caches you clean.'
            if (-not (Confirm-Action "Clean $($picked.Count) item(s), $(Format-Size $total)?")) { Write-Note 'Nothing cleaned.'; return }
        }
    }

    if ($DryRunMode) { Write-Note 'Dry run: nothing will be changed.' }
    $before = Get-SystemDriveFree
    $cleaned = 0
    foreach ($n in $picked) {
        $item = $rows[$n]
        Write-Text "  $($item.Label)"
        if ($item.Admin -and -not $IsAdmin) { Write-Warn 'skipped: needs "Run as administrator"'; continue }
        Invoke-ItemClean $item
        $cleaned++
    }
    if (-not $DryRunMode) { Write-Host ''; Write-Host "  Cleaned $cleaned item(s)." -NoNewline }
    Write-Freed $before
}

# ---------------------------------------------------------------------------
# medic purge: dependency and build folders of projects nobody touched lately
# ---------------------------------------------------------------------------

# The folder names purge looks for. Get-PurgeKind checks the file next to them
# (or in them, for venvs) that proves what they are.
$PurgeNames = @('node_modules', '.next', '.venv', 'venv', 'target', 'build')

function Get-PurgeKind([System.IO.DirectoryInfo]$Dir) {
    if (-not $Dir.Exists -or ([int]$Dir.Attributes -band $ReparsePoint)) { return '' }
    $parent = $Dir.Parent.FullName
    switch ($Dir.Name.ToLowerInvariant()) {
        'node_modules' { if (Test-Path -LiteralPath (Join-Path $parent 'package.json') -PathType Leaf) { return 'node_modules' } }
        '.next' { if (Test-Path -LiteralPath (Join-Path $parent 'package.json') -PathType Leaf) { return 'Next.js build' } }
        { $_ -eq '.venv' -or $_ -eq 'venv' } { if (Test-Path -LiteralPath (Join-Path $Dir.FullName 'pyvenv.cfg') -PathType Leaf) { return 'Python venv' } }
        'target' {
            if (Test-Path -LiteralPath (Join-Path $parent 'Cargo.toml') -PathType Leaf) { return 'Rust build' }
            if (Test-Path -LiteralPath (Join-Path $parent 'pom.xml') -PathType Leaf) { return 'Maven build' }
        }
        'build' {
            if ((Test-Path -LiteralPath (Join-Path $parent 'build.gradle') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $parent 'build.gradle.kts') -PathType Leaf)) { return 'Gradle build' }
        }
    }
    return ''
}

# Did any file in the project change in the last -OlderThan days? Purgeable
# folders and .git are skipped: installs and fetches are not work.
function Test-ProjectActive([string]$Dir) {
    if ($PurgeDays -eq 0) { return $false }
    $since = (Get-Date).AddDays(-$PurgeDays)
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((New-Object System.IO.DirectoryInfo $Dir))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $entries = $d.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($e -is [System.IO.DirectoryInfo]) {
                if (([int]$e.Attributes -band $ReparsePoint) -or $e.Name -eq '.git' -or $PurgeNames -contains $e.Name) { continue }
                $stack.Push($e)
            } elseif ($e.LastWriteTime -gt $since) {
                return $true
            }
        }
    }
    return $false
}

# Purge candidates in the project folders, biggest first.
function Find-PurgeFolder([string[]]$Roots) {
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    foreach ($r in $Roots) { $stack.Push((New-Object System.IO.DirectoryInfo $r)) }
    $found = @(while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { $subs = $dir.GetDirectories() } catch { continue }
            foreach ($s in $subs) {
                if ([int]$s.Attributes -band $ReparsePoint -or $s.Name -eq '.git') { continue }
                if ($PurgeNames -notcontains $s.Name) { $stack.Push($s); continue }
                $kind = Get-PurgeKind $s
                if ($kind -and -not (Test-ProjectActive $s.Parent.FullName)) {
                    Write-Progress -Activity 'medic' -Status "Scanning $(Format-Path $s.FullName)"
                    [pscustomobject]@{ Path = $s.FullName; Kind = $kind; Bytes = Get-PathSize $s.FullName }
                }
            }
        })
    Write-Progress -Activity 'medic' -Completed
    return , @($found | Sort-Object Bytes -Descending)
}

# Delete a purge folder itself, after checking again that it is one and that
# it is inside a project folder. Junctions inside are removed, never followed.
function Remove-PurgeFolder([string]$Path, [string[]]$Roots) {
    $sep = [IO.Path]::DirectorySeparatorChar
    $inside = @($Roots | Where-Object { $Path.StartsWith($_ + $sep, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $dir = New-Object System.IO.DirectoryInfo $Path
    if (-not $inside -or -not (Get-PurgeKind $dir)) {
        Write-Warn "refusing to touch $(Format-Path $Path) (not a dependency or build folder in a project folder)"
        return $false
    }
    if ($DryRunMode) { Write-Note "would delete $(Format-Path $Path)"; return $true }
    Remove-Entry $dir
    if (Test-Path -LiteralPath $Path) { Write-Warn "could not delete everything in $(Format-Path $Path)" }
    return $true
}

function Invoke-Purge([string[]]$Roots, $Rows) {
    Write-Section 'Purge'
    if ($PurgeDays -gt 0) {
        Write-Note "Dependency and build folders of projects with no file changed in $PurgeDays days."
    } else {
        Write-Note 'Dependency and build folders of all projects.'
    }
    $list = 'no project folders found'
    if ($Roots.Count -gt 0) { $list = ($Roots | ForEach-Object { Format-Path $_ }) -join ', ' }
    Write-Note "Looked in: $list. Add more with -DevDir DIR."
    if ($Rows.Count -eq 0) { Write-Note 'Nothing to purge.'; return }

    Write-Host ''
    Write-Text ('  {0,-3} {1,-10} {2,-13} {3}' -f '#', 'SIZE', 'KIND', 'FOLDER') DarkGray
    for ($n = 0; $n -lt $Rows.Count; $n++) {
        Write-Host ('  {0,-3} {1,-10} {2,-13} {3}' -f ($n + 1), (Format-Size $Rows[$n].Bytes), $Rows[$n].Kind, (Format-Path $Rows[$n].Path))
    }
    Write-Note "Reinstall with 'npm install', 'pip install -r requirements.txt' or a new build when you need them."

    if ($AssumeYes) {
        $picked = @(0..($Rows.Count - 1))
    } else {
        if (-not (Test-Interactive 'purge')) { $script:Failed = $true; return }
        $picked = Read-Selection -Count $Rows.Count -Hint "numbers like 1,3 or 2-5, 'all'"
        if ($null -eq $picked) { Write-Note 'Nothing deleted.'; return }
        if (-not $DryRunMode) {
            $total = [long]0
            foreach ($n in $picked) { $total += $Rows[$n].Bytes }
            if (-not (Confirm-Action "Delete $($picked.Count) folder(s), $(Format-Size $total)?")) { Write-Note 'Nothing deleted.'; return }
        }
    }

    if ($DryRunMode) { Write-Note 'Dry run: nothing will be changed.' }
    $before = Get-SystemDriveFree
    $deleted = 0
    foreach ($n in $picked) {
        if (Remove-PurgeFolder $Rows[$n].Path $Roots) { $deleted++ }
    }
    if (-not $DryRunMode) { Write-Host ''; Write-Host "  Deleted $deleted folder(s)." -NoNewline }
    Write-Freed $before
}

# ---------------------------------------------------------------------------
# medic check
# ---------------------------------------------------------------------------

# -MinFree in bytes. Units are binary, like the sizes medic shows on Windows.
function Get-MinFreeByte([long]$Total) {
    if ($MinFreeText -match '^(\d+)%$') { return [long]($Total * [int]$Matches[1] / 100) }
    if ($MinFreeText -match '^(\d+(?:\.\d+)?)([KMGT]?)B?$') {
        $unit = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB }[$Matches[2].ToUpperInvariant()]
        return [long]([double]$Matches[1] * $unit)
    }
    Exit-Usage "-MinFree: '$MinFreeText' is not a size like 20G, 500M or 10%"
}

function Invoke-Check {
    $disk = @(Get-DiskInfo | Where-Object { $_.System }) | Select-Object -First 1
    $mem = Get-MemoryInfo
    $need = Get-MinFreeByte $disk.Total
    $diskOk = $disk.Free -ge $need
    $memOk = $mem.Pressure -ne 'critical'
    if ($Json) {
        Write-Json ([ordered]@{
                version = $ScriptVersion; os = 'windows'; ok = ($diskOk -and $memOk)
                checks  = @(
                    [ordered]@{ name = 'disk'; ok = $diskOk; free_bytes = $disk.Free; min_free_bytes = $need }
                    [ordered]@{ name = 'memory'; ok = $memOk; pressure = $mem.Pressure }
                )
            })
    } else {
        Write-CheckLine $diskOk "disk: $(Format-Size $disk.Free) free on $($disk.Name), needs $(Format-Size $need)"
        Write-CheckLine $memOk "memory: pressure is $($mem.Pressure)"
    }
    if (-not ($diskOk -and $memOk)) { $script:Failed = $true }
}

function Write-CheckLine([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Text 'OK   ' Green -NoNewline } else { Write-Text 'FAIL ' Red -NoNewline }
    Write-Host $Text
}

# ---------------------------------------------------------------------------
# JSON output. Sizes are in bytes, the same shape as the macOS version.
# ---------------------------------------------------------------------------

function Write-Json($Data) { $Data | ConvertTo-Json -Depth 6 -Compress | Write-Output }

function ConvertTo-DiskJson($Disks) {
    return , @(foreach ($d in $Disks) {
            [ordered]@{ name = $d.Name; system = $d.System; total_bytes = $d.Total; used_bytes = $d.Used; free_bytes = $d.Free; used_percent = $d.Pct }
        })
}

function ConvertTo-MemoryJson($Mem) {
    return [ordered]@{
        total_bytes = [long]$Mem.Total; used_bytes = [long]$Mem.Used; cached_bytes = [long]$Mem.Cached
        swap_used_bytes = [long]$Mem.PageUsed; swap_total_bytes = [long]$Mem.PageSize; pressure = $Mem.Pressure
        top_apps = @(foreach ($a in $Mem.TopApps) { [ordered]@{ name = $a.Name; bytes = $a.Bytes; processes = $a.Count } })
    }
}

function ConvertTo-ItemJson {
    return , @(foreach ($item in (Get-VisibleItem)) {
            $paths = @($item.Paths | Where-Object { Test-Path -LiteralPath $_ })
            if ($item.Id -eq 'installers') { $paths = @($script:InstallerFiles) }
            [ordered]@{
                id = $item.Id; label = $item.Label; safety = $item.Safety; bytes = $item.Bytes
                cleanable = ($item.Cleanable -and $item.Safety -ne 'REVIEW'); admin = $item.Admin; note = $item.Note; paths = $paths
            }
        })
}

function ConvertTo-SummaryJson {
    $sum = @{ SAFE = [long]0; CAUTION = [long]0; REVIEW = [long]0 }
    foreach ($item in @(Get-VisibleItem)) { $sum[$item.Safety] += $item.Bytes }
    return [ordered]@{ safe_bytes = $sum.SAFE; caution_bytes = $sum.CAUTION; review_bytes = $sum.REVIEW }
}

# ---------------------------------------------------------------------------
# Main. Dot-sourcing the script (". .\medic.ps1") only loads the
# functions, which is handy for tests and for drawing the README screenshots.
# ---------------------------------------------------------------------------

function Exit-Usage([string]$Message) {
    [Console]::Error.WriteLine("medic: $Message")
    [Console]::Error.WriteLine('Run "medic -?" for usage.')
    exit 2
}

function Assert-Usage {
    if ($Cmd -notin 'report', 'disk', 'memory', 'clean', 'purge', 'check') { Exit-Usage "unknown command: $Command" }
    if ($Cmd -notin 'clean', 'purge') {
        if ($DryRun) { Exit-Usage '-DryRun only works with clean and purge' }
        if ($AssumeYes) { Exit-Usage '-Yes only works with clean and purge' }
    }
    if ($Cmd -eq 'clean' -and $Json) { Exit-Usage "clean has no JSON output; 'medic report -Json' lists the items" }
    if ($OnlyTokens.Count -gt 0 -and $Cmd -ne 'clean') { Exit-Usage '-Only only works with clean' }
    if ($MinFreeText -notmatch '^(\d+%|\d+(\.\d+)?[KMGTkmgt]?[Bb]?)$') { Exit-Usage "-MinFree: '$MinFreeText' is not a size like 20G, 500M or 10%" }
}

function Write-Header {
    if ($Json -or $Cmd -eq 'check') { return }
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Text "medic $ScriptVersion" '' -NoNewline
    Write-Text " - $env:COMPUTERNAME, $($os.Caption) $($os.Version)" DarkGray
    if ($Cmd -in 'clean', 'purge') {
        if ($DryRunMode) { Write-Note 'Dry run: shows what would happen, changes nothing.' }
    } else {
        Write-Note "Read-only. Nothing is deleted unless you run 'medic clean' or 'medic purge' and confirm."
    }
    if ($IsAdmin -and $Cmd -in 'report', 'disk', 'clean') { Write-Note 'Running as administrator: system caches are included.' }
}

# The report and disk commands.
function Invoke-StorageReport([bool]$WithMemory) {
    $data = [ordered]@{ version = $ScriptVersion; os = 'windows'; command = $Cmd }
    $disks = @(Get-DiskInfo)
    $data.disks = ConvertTo-DiskJson $disks
    if (-not $Json) { Show-Disk $disks }
    if ($WithMemory) {
        $mem = Get-MemoryInfo
        $data.memory = ConvertTo-MemoryJson $mem
        if (-not $Json) { Show-Memory $mem }
    }
    Initialize-Item
    Measure-Item
    $data.items = ConvertTo-ItemJson
    $data.summary = ConvertTo-SummaryJson
    if (-not $Json) {
        Show-Item
        Show-DeleteCommand
    }
    if (-not $SkipSlowScans) {
        if (-not $Json) { Show-AppDataBreakdown }
        $dev = @(Get-DevFolder)
        $large = @(Get-LargeFileList)
        $data.dev_folders = @(foreach ($f in $dev) { [ordered]@{ path = $f.Path; bytes = $f.Bytes } })
        $data.large_files = @(foreach ($f in $large) { [ordered]@{ path = $f.Path; bytes = $f.Bytes; modified = $f.Modified.ToString('yyyy-MM-dd') } })
        if (-not $Json) {
            Show-DevFolder $dev
            Show-LargeFile $large
        }
    }
    if ($Json) { Write-Json $data; return }
    Show-SystemInfo
    Show-Summary
}

# Sets $Failed when the command failed, for the exit code.
function Invoke-Medic {
    $script:IsAdmin = Test-Admin
    Write-Header
    switch ($Cmd) {
        'report' { Invoke-StorageReport $true }
        'disk' { Invoke-StorageReport $false }
        'memory' {
            $mem = Get-MemoryInfo
            if ($Json) { Write-Json ([ordered]@{ version = $ScriptVersion; os = 'windows'; command = $Cmd; memory = (ConvertTo-MemoryJson $mem) }) }
            else { Show-Memory $mem }
        }
        'clean' {
            Initialize-Item
            Assert-Only
            Measure-Item
            Invoke-Clean
        }
        'purge' {
            $roots = @(Get-DevRoot)
            $rows = @(Find-PurgeFolder $roots)
            if ($Json) {
                Write-Json ([ordered]@{
                        version = $ScriptVersion; os = 'windows'; command = $Cmd
                        purge = [ordered]@{
                            older_than_days = $PurgeDays; roots = $roots
                            folders = @(foreach ($r in $rows) { [ordered]@{ path = $r.Path; kind = $r.Kind; bytes = $r.Bytes } })
                        }
                    })
            } else {
                Invoke-Purge $roots $rows
            }
        }
        'check' { Invoke-Check }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Version) { "medic $ScriptVersion (Windows)"; return }
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'This is the Windows version. On macOS, run macos/medic.sh with bash instead.'
    exit 1
}
Assert-Usage

Invoke-Medic
if ($Failed) { exit 1 }
