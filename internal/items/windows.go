package items

import (
	"fmt"
	"strings"
)

// The Windows list of locations, as plain data: it builds on any system, so
// the README screenshot shows the real labels. Paths are joined with
// backslashes by hand for the same reason.

// Env holds the folders the Windows list is built from: LOCALAPPDATA,
// APPDATA, USERPROFILE, windir, ProgramData and SystemDrive.
type Env struct{ L, R, U, W, ProgramData, SystemDrive string }

func (e Env) browserCaches() []string {
	return []string{
		e.L + `\Google\Chrome\User Data\*\Cache`, e.L + `\Google\Chrome\User Data\*\Code Cache`,
		e.L + `\Microsoft\Edge\User Data\*\Cache`, e.L + `\Microsoft\Edge\User Data\*\Code Cache`,
		e.L + `\BraveSoftware\Brave-Browser\User Data\*\Cache`, e.L + `\BraveSoftware\Brave-Browser\User Data\*\Code Cache`,
		e.L + `\Mozilla\Firefox\Profiles\*\cache2`,
	}
}

func (e Env) appCaches() []string {
	return []string{
		e.R + `\Code\Cache`, e.R + `\Code\CachedData`, e.R + `\Code\CachedExtensionVSIXs`,
		e.R + `\Cursor\Cache`, e.R + `\Cursor\CachedData`,
		e.R + `\Slack\Cache`, e.R + `\Slack\Service Worker\CacheStorage`, e.R + `\discord\Cache`,
	}
}

func (e Env) systemCaches() []string {
	return []string{
		e.L + `\Temp`, e.L + `\CrashDumps`, e.L + `\D3DSCache`, e.L + `\NVIDIA\DXCache`, e.L + `\NVIDIA\GLCache`,
		e.L + `\Microsoft\Windows\INetCache`, e.L + `\Microsoft\Windows\WER\ReportArchive`, e.L + `\Microsoft\Windows\WER\ReportQueue`,
	}
}

func (e Env) adminDumps() []string {
	return []string{e.W + `\Minidump`, e.ProgramData + `\Microsoft\Windows\WER\ReportArchive`, e.ProgramData + `\Microsoft\Windows\WER\ReportQueue`}
}

// winCleanableDirs returns the only folders whose contents medic will ever
// delete, and the only single files. Exact matches only. expand resolves the
// wildcards in browser profile paths.
func winCleanableDirs(e Env, expand func([]string) []string) (dirs, files []string) {
	all := append(append(append(e.browserCaches(), e.appCaches()...), e.systemCaches()...), e.adminDumps()...)
	all = append(all, e.W+`\Temp`, e.W+`\SoftwareDistribution\Download`, e.L+`\pip\Cache`, e.L+`\Yarn\Cache`,
		e.U+`\.gradle\caches`, e.U+`\.m2\repository`, e.U+`\.cargo\registry\cache`, e.U+`\.cargo\registry\src`, e.U+`\.bun\install\cache`)
	for _, p := range expand(all) {
		dirs = append(dirs, cleanWin(p))
	}
	return dirs, []string{cleanWin(e.W + `\MEMORY.DMP`)}
}

// WindowsItems lists the known locations on a PC. downloads is the Downloads
// folder, recycle the user's Recycle Bin folder on each drive, has says
// whether a tool is installed and expand resolves wildcards.
func WindowsItems(e Env, downloads string, recycle []string, has func(string) bool, expand func([]string) []string) []*Item {
	var windowsCaches []string
	for _, p := range e.systemCaches() {
		if p != e.L+`\Temp` {
			windowsCaches = append(windowsCaches, p)
		}
	}

	var list []*Item
	add(&list, Item{ID: "user_temp", Safety: Safe, Label: "Temporary files",
		Note: "Leftovers from installers and apps. Files still in use are skipped.", Cleanable: true, Paths: []string{e.L + `\Temp`}})
	add(&list, Item{ID: "recycle_bin", Safety: Safe, Label: "Recycle Bin",
		Note: "Things you already deleted. Emptying it is permanent.", Cleanable: true, Paths: recycle})
	add(&list, Item{ID: "browser_caches", Safety: Safe, Label: "Browser caches (Chrome, Edge, Brave, Firefox)",
		Note: "Web page caches. Close the browser before cleaning.", Cleanable: true, Paths: expand(e.browserCaches())})
	add(&list, Item{ID: "app_caches", Safety: Safe, Label: "Desktop app web caches (VS Code, Cursor, Slack, Discord)",
		Note: "Close these apps before cleaning.", Cleanable: true, Paths: e.appCaches()})
	add(&list, Item{ID: "windows_caches", Safety: Safe, Label: "Windows caches and crash reports",
		Note: "Shader caches, web cache, crash dumps and error reports. Rebuilt as needed.", Cleanable: true, Paths: windowsCaches})

	add(&list, Item{ID: "npm", Safety: Safe, Label: "npm cache", Note: "Packages are downloaded again when needed.",
		Cleanable: has("npm"), Paths: []string{e.L + `\npm-cache`}})
	add(&list, Item{ID: "pnpm", Safety: Safe, Label: "pnpm store",
		Note: "Clean runs 'pnpm store prune', which only drops packages no project uses.", Cleanable: has("pnpm"), Paths: []string{e.L + `\pnpm\store`}})
	add(&list, Item{ID: "yarn", Safety: Safe, Label: "Yarn cache", Note: "Packages are downloaded again when needed.",
		Cleanable: true, Paths: []string{e.L + `\Yarn\Cache`}})
	add(&list, Item{ID: "pip", Safety: Safe, Label: "pip cache", Note: "Packages are downloaded again when needed.",
		Cleanable: true, Paths: []string{e.L + `\pip\Cache`}})
	add(&list, Item{ID: "bun", Safety: Safe, Label: "Bun cache", Note: "Packages are downloaded again when needed.",
		Cleanable: true, Paths: []string{e.U + `\.bun\install\cache`}})
	add(&list, Item{ID: "nuget", Safety: Safe, Label: "NuGet packages",
		Note: "Clean runs 'dotnet nuget locals all --clear'. Packages are restored on the next build.", Cleanable: has("dotnet"),
		Paths: []string{e.U + `\.nuget\packages`}})
	add(&list, Item{ID: "go_mod", Safety: Safe, Label: "Go module cache", Note: "Modules are downloaded again when needed.",
		Cleanable: has("go"), Paths: []string{e.U + `\go\pkg\mod`}})
	add(&list, Item{ID: "cargo", Safety: Safe, Label: "Cargo registry cache", Note: "Crates are downloaded again when needed.",
		Cleanable: true, Paths: []string{e.U + `\.cargo\registry\cache`, e.U + `\.cargo\registry\src`}})
	add(&list, Item{ID: "gradle", Safety: Safe, Label: "Gradle caches", Note: "Dependencies are downloaded again. Stop Gradle daemons first.",
		Cleanable: true, Paths: []string{e.U + `\.gradle\caches`}})
	add(&list, Item{ID: "maven", Safety: Caution, Label: "Maven local repository",
		Note: "Also holds artifacts you built with 'mvn install', which are not re-downloadable.", Cleanable: true, Paths: []string{e.U + `\.m2\repository`}})
	add(&list, Item{ID: "docker", Safety: Caution, Label: "Docker Desktop data",
		Note:      "Clean runs 'docker system prune': stopped containers, dangling images, build cache. Volumes are kept.",
		Cleanable: has("docker"), Paths: []string{e.L + `\Docker\wsl`}})

	add(&list, Item{ID: "system_temp", Safety: Safe, Label: "Windows temporary files",
		Note: "System-wide temp folder. Files still in use are skipped.", Cleanable: true, Admin: true, Paths: []string{e.W + `\Temp`}})
	add(&list, Item{ID: "windows_update", Safety: Safe, Label: "Windows Update downloads",
		Note: "Already installed update files. Windows Update is paused while cleaning.", Cleanable: true, Admin: true,
		Paths: []string{e.W + `\SoftwareDistribution\Download`}})
	add(&list, Item{ID: "delivery_opt", Safety: Safe, Label: "Delivery Optimization cache",
		Note: "Update pieces shared with other PCs. Re-downloaded if needed.", Cleanable: true, Admin: true,
		Paths: []string{e.W + `\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache`}})
	add(&list, Item{ID: "crash_dumps", Safety: Safe, Label: "System crash dumps",
		Note: "Only useful for diagnosing a past blue screen.", Cleanable: true, Admin: true,
		Paths: append([]string{e.W + `\MEMORY.DMP`}, e.adminDumps()...)})
	add(&list, Item{ID: "windows_old", Safety: Caution, Label: "Previous Windows installation (Windows.old)",
		Note: "Remove it in Settings > System > Storage > Temporary files. You cannot roll back afterwards.", Admin: true,
		Paths: []string{e.SystemDrive + `\Windows.old`}})

	add(&list, Item{ID: "wsl", Safety: Review, Label: "WSL Linux distros",
		Note:  "Your Linux files. 'wsl --unregister <name>' removes an unused distro and everything in it.",
		Paths: expand([]string{e.L + `\Packages\*\LocalState\ext4.vhdx`, e.L + `\wsl\*\ext4.vhdx`})})
	add(&list, Item{ID: "virtualbox", Safety: Review, Label: "VirtualBox VMs",
		Note: "Delete VMs you no longer use from VirtualBox itself.", Paths: []string{e.U + `\VirtualBox VMs`}})
	add(&list, Item{ID: "android_avd", Safety: Review, Label: "Android emulators",
		Note: "Delete emulators you no longer use in Android Studio > Device Manager.", Paths: []string{e.U + `\.android\avd`}})
	add(&list, Item{ID: "android_images", Safety: Review, Label: "Android system images",
		Note: "Uninstall unused API levels in Android Studio > SDK Manager.", Paths: []string{e.L + `\Android\Sdk\system-images`}})
	add(&list, Item{ID: "downloads", Safety: Review, Label: "Downloads folder",
		Note: "Your files. Sort by size in Explorer and remove what you no longer need.", Paths: []string{downloads}})

	return list
}

// WindowsInstallers is the item for installer files found in Downloads and on
// the Desktop, with their total size.
func WindowsInstallers(files []string, total int64) *Item {
	return &Item{ID: "installers", Safety: Caution, Label: fmt.Sprintf("Installer files (%d .msi/.iso/setup.exe)", len(files)),
		Note: "Rarely needed after installing. Clean moves them to the Recycle Bin, so it can be undone.", Cleanable: true,
		Files: files, Bytes: total, Measured: true}
}

// cleanWin normalizes a Windows path for comparing: no trailing backslash.
func cleanWin(p string) string { return strings.TrimRight(p, `\`) }

// EnvPath shows a path the way it is typed in PowerShell, so a printed
// command works on any PC.
func (e Env) EnvPath(path string) string {
	for _, v := range [][2]string{{"LOCALAPPDATA", e.L}, {"APPDATA", e.R}, {"USERPROFILE", e.U},
		{"ProgramData", e.ProgramData}, {"windir", e.W}, {"SystemDrive", e.SystemDrive}} {
		if v[1] != "" && len(path) >= len(v[1]) && strings.EqualFold(path[:len(v[1])], v[1]) {
			return "$env:" + v[0] + path[len(v[1]):]
		}
	}
	return path
}

// DescribeWindows fills in the commands that clean each item by hand. They
// mirror Clean; for folders only allowlisted ones with contents are listed.
func DescribeWindows(list []*Item, e Env, hasContent, isFile func(string) bool, expand func([]string) []string) {
	dirs, _ := winCleanableDirs(e, expand)
	for _, it := range list {
		it.Commands = nil
		switch it.ID {
		case "recycle_bin":
			it.Commands = []string{`powershell -NoProfile -Command "Clear-RecycleBin -Force"`}
		case "npm", "pnpm", "go_mod", "nuget", "docker":
			it.Commands = []string{strings.Join(winToolCommand(it.ID), " ")}
		case "delivery_opt":
			it.Commands = []string{"Delete-DeliveryOptimizationCache -Force"}
		case "installers":
		case "windows_update":
			it.Commands = []string{"Stop-Service wuauserv, bits -Force", `Clear-Folder "$env:windir\SoftwareDistribution\Download"`, "Start-Service wuauserv, bits"}
		default:
			for _, p := range it.Paths {
				if strings.HasSuffix(strings.ToLower(p), ".dmp") {
					if isFile(p) {
						it.Commands = append(it.Commands, `Remove-Item "`+e.EnvPath(p)+`" -Force`)
					}
					continue
				}
				if contains(dirs, cleanWin(p)) && hasContent(p) {
					it.Commands = append(it.Commands, `Clear-Folder "`+e.EnvPath(p)+`"`)
				}
			}
		}
	}
}

func winToolCommand(id string) []string {
	return map[string][]string{
		"npm":    {"npm", "cache", "clean", "--force"},
		"pnpm":   {"pnpm", "store", "prune"},
		"go_mod": {"go", "clean", "-modcache"},
		"nuget":  {"dotnet", "nuget", "locals", "all", "--clear"},
		"docker": {"docker", "system", "prune", "--force"},
	}[id]
}
