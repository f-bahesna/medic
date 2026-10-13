// Command screenshot prints the report for the README screenshots: the real
// lists of locations and the real rendering, with made-up sizes and system
// data. docs/make-screenshots.py turns its colored output into SVG.
//
//	go run ./tools/screenshot macos
//	go run ./tools/screenshot windows
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/f-bahesna/medic/internal/app"
	"github.com/f-bahesna/medic/internal/items"
	"github.com/f-bahesna/medic/internal/sysinfo"
	"github.com/f-bahesna/medic/internal/ui"
)

// version is the sample version shown in the screenshots.
const version = "0.5.0"

// Sizes in the units each system shows: decimal on macOS, binary on Windows.
func gb(v float64) int64  { return int64(v * 1e9) }
func mb(v float64) int64  { return int64(v * 1e6) }
func gib(v float64) int64 { return int64(v * (1 << 30)) }
func mib(v float64) int64 { return int64(v * (1 << 20)) }

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: screenshot macos|windows")
		os.Exit(2)
	}
	var r *app.Report
	switch os.Args[1] {
	case "macos":
		r = mac()
	case "windows":
		r = win()
	default:
		fmt.Fprintln(os.Stderr, "usage: screenshot macos|windows")
		os.Exit(2)
	}
	p := ui.NewPrinter(os.Stdout, true)
	app.RenderHeader(p, r, false)
	app.RenderReport(p, r)
}

// measure sets each item's size from sizes, keyed by path.
func measure(list []*items.Item, sizes map[string]int64) {
	for _, it := range list {
		if it.Measured {
			continue
		}
		it.Bytes, it.Measured = 0, true
		for _, p := range it.Paths {
			it.Bytes += sizes[p]
		}
	}
}

func tools(names ...string) func(string) bool {
	return func(tool string) bool {
		for _, n := range names {
			if n == tool {
				return true
			}
		}
		return false
	}
}

func mac() *app.Report {
	home := "/Users/alex"
	sizes := map[string]int64{
		home + "/Pictures/Photos Library.photoslibrary":         gb(24.3),
		home + "/Library/Caches":                                gb(14.8),
		home + "/Library/Containers/com.docker.docker/Data/vms": gb(9.6),
		home + "/Library/Developer/Xcode/DerivedData":           gb(7.2),
		home + "/Library/Application Support/MobileSync/Backup": gb(5.1),
		home + "/.npm/_cacache":                                 gb(2.4),
	}
	list := items.MacItems(home, tools("npm", "docker"), nil, []string{home + "/Pictures/Photos Library.photoslibrary"})
	var installers []string
	var total int64
	for _, f := range []struct {
		name string
		mb   int64
	}{{"Docker.dmg", 610}, {"UTM.dmg", 430}, {"LibreOffice_25.8.1_MacOS_aarch64.dmg", 330},
		{"googlechrome.dmg", 230}, {"Slack-4.46.99-macOS.dmg", 180}, {"Zoom.pkg", 120}} {
		installers = append(installers, home+"/Downloads/"+f.name)
		total += mb(float64(f.mb))
	}
	list = append(list, items.MacInstallers(installers, total))
	measure(list, sizes)
	items.DescribeMac(list, home, func(p string) bool { return sizes[p] > 0 })

	const page = 16384
	pages := func(g float64) int64 { return gib(g) / page * page }
	appMem := pages(6.3) - pages(0.2)
	apps := []sysinfo.App{
		{Name: "Google Chrome", Bytes: mib(3174), Processes: 24}, {Name: "Slack", Bytes: mib(1229), Processes: 6},
		{Name: "Visual Studio Code", Bytes: mib(1126), Processes: 9}, {Name: "Docker", Bytes: mib(842), Processes: 4},
		{Name: "Spotify", Bytes: mib(612), Processes: 3}, {Name: "Finder", Bytes: mib(214), Processes: 1},
		{Name: "WindowServer", Bytes: mib(176), Processes: 1}, {Name: "trustd", Bytes: mib(38), Processes: 1},
	}
	return report{
		OS: "macos", Host: sysinfo.Host{Name: "MacBook Air", OS: "macOS 15.5"}, Home: home,
		Disks: []sysinfo.Disk{{Name: "/", System: true, Total: 482812500 * 1024, Free: 61718750 * 1024,
			Used: (482812500 - 61718750) * 1024, SystemVolume: 11523438 * 1024, DataVolume: 393164063 * 1024}},
		Memory: &sysinfo.Memory{Total: gib(16), App: appMem, Wired: pages(2.3), Compressed: pages(3.0),
			Used: appMem + pages(2.3) + pages(3.0), Cached: pages(3.7) + pages(0.2), Free: mib(712) / page * page,
			SwapUsed: mib(1228.8), SwapTotal: mib(2048), Pressure: "normal", AvailablePct: 52, TopApps: apps},
		Items: list, Snapshots: 1,
	}.build()
}

func win() *app.Report {
	e := items.Env{L: `C:\Users\alex\AppData\Local`, R: `C:\Users\alex\AppData\Roaming`, U: `C:\Users\alex`,
		W: `C:\WINDOWS`, ProgramData: `C:\ProgramData`, SystemDrive: "C:"}
	L, downloads := e.L, e.U+`\Downloads`
	ubuntu := L + `\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState\ext4.vhdx`
	sizes := map[string]int64{
		ubuntu: gib(41.2),
		L + `\Google\Chrome\User Data\Default\Cache`:      gib(7.9),
		L + `\Google\Chrome\User Data\Default\Code Cache`: gib(1.6),
		L + `\Microsoft\Edge\User Data\Default\Cache`:     gib(3.1),
		L + `\Temp`:       gib(8.4),
		L + `\Docker\wsl`: gib(6.9),
		downloads:         gib(3.8),
		L + `\npm-cache`:  gib(2.2),
	}
	wildcards := map[string]string{
		L + `\Google\Chrome\User Data\*\Cache`:      L + `\Google\Chrome\User Data\Default\Cache`,
		L + `\Google\Chrome\User Data\*\Code Cache`: L + `\Google\Chrome\User Data\Default\Code Cache`,
		L + `\Microsoft\Edge\User Data\*\Cache`:     L + `\Microsoft\Edge\User Data\Default\Cache`,
		L + `\Packages\*\LocalState\ext4.vhdx`:      ubuntu,
	}
	expand := func(patterns []string) []string {
		var out []string
		for _, p := range patterns {
			if !strings.Contains(p, "*") {
				out = append(out, p)
			} else if m, ok := wildcards[p]; ok {
				out = append(out, m)
			}
		}
		return out
	}
	sid := "S-1-5-21-1004336348-1177238915-682003330-1001"
	list := items.WindowsItems(e, downloads, []string{`C:\$Recycle.Bin\` + sid, `D:\$Recycle.Bin\` + sid}, tools("npm", "docker"), expand)
	var installers []string
	var total int64
	for _, f := range []struct {
		name string
		mb   int64
	}{{"Docker Desktop Installer.exe", 520}, {"virtio-win-0.1.271.iso", 753}, {"PowerToysUserSetup-0.94.0-x64.exe", 260},
		{"VSCodeUserSetup-x64-1.104.0.exe", 105}, {"ZoomInstallerFull.exe", 90}, {"node-v22.20.0-x64.msi", 31},
		{"ChromeSetup.exe", 10}, {"OfficeSetup.exe", 7}, {"SteamSetup.exe", 3}} {
		installers = append(installers, downloads+`\`+f.name)
		total += mib(float64(f.mb))
	}
	list = append(list, items.WindowsInstallers(installers, total))
	measure(list, sizes)
	items.DescribeWindows(list, e, func(p string) bool { return sizes[p] > 0 }, func(string) bool { return false }, expand)

	apps := []sysinfo.App{
		{Name: "chrome", Bytes: gib(2.7), Processes: 31}, {Name: "Memory Compression", Bytes: gib(1.4), Processes: 1},
		{Name: "Code", Bytes: gib(1.3), Processes: 11}, {Name: "svchost", Bytes: gib(1.1), Processes: 94},
		{Name: "ms-teams", Bytes: mib(986), Processes: 4}, {Name: "explorer", Bytes: mib(604), Processes: 1},
		{Name: "Discord", Bytes: mib(433), Processes: 6}, {Name: "OneDrive", Bytes: mib(388), Processes: 1},
	}
	return report{
		OS: "windows", Host: sysinfo.Host{Name: "DESKTOP-7K2M4QX", OS: "Microsoft Windows 11 Pro 10.0.26100"}, Home: e.U,
		Disks: []sysinfo.Disk{
			{Name: "C:", System: true, Total: gib(475.8), Free: gib(63.5), Used: gib(475.8) - gib(63.5)},
			{Name: "D:", Label: "Data", Total: gib(931.5), Free: gib(643.4), Used: gib(931.5) - gib(643.4)},
		},
		Memory: &sysinfo.Memory{Total: gib(16), Used: gib(16) - gib(5.1), Free: gib(5.1), Cached: gib(4.2),
			Compressed: gib(1.4), Committed: gib(14.6), CommitLimit: gib(34.9), SwapUsed: mib(1126), SwapTotal: mib(19354),
			Pressure: "normal", AvailablePct: 31, TopApps: apps},
		Items:       list,
		SystemFiles: []sysinfo.File{{Path: `C:\pagefile.sys`, Bytes: gib(18.9)}, {Path: `C:\hiberfil.sys`, Bytes: gib(6.4)}},
	}.build()
}

// report is a sample report for the screenshot of a "medic --quick" run.
type report app.Report

func (r report) build() *app.Report {
	out := app.Report(r)
	out.Version, out.Command, out.LargeMB, out.OlderThan = version, "report", 500, 30
	return &out
}
