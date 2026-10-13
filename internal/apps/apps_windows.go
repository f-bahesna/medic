package apps

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
	"golang.org/x/sys/windows/registry"
)

const uninstallKey = `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`

// List returns the apps in Settings > Apps that have an uninstaller, biggest
// first. System components and updates are left out. Store apps are managed
// by Windows and not listed.
func List(string) []App {
	seen := map[string]bool{}
	var list []App
	for _, src := range []struct {
		root   registry.Key
		access uint32
	}{
		{registry.LOCAL_MACHINE, registry.WOW64_64KEY},
		{registry.LOCAL_MACHINE, registry.WOW64_32KEY},
		{registry.CURRENT_USER, 0},
	} {
		k, err := registry.OpenKey(src.root, uninstallKey, registry.ENUMERATE_SUB_KEYS|registry.QUERY_VALUE|src.access)
		if err != nil {
			continue
		}
		names, _ := k.ReadSubKeyNames(-1)
		for _, name := range names {
			if a, ok := readApp(k, name, src.access); ok && !seen[strings.ToLower(a.Name+"|"+a.Version)] {
				seen[strings.ToLower(a.Name+"|"+a.Version)] = true
				list = append(list, a)
			}
		}
		k.Close()
	}
	return bySize(list)
}

func readApp(parent registry.Key, name string, access uint32) (App, bool) {
	k, err := registry.OpenKey(parent, name, registry.QUERY_VALUE|access)
	if err != nil {
		return App{}, false
	}
	defer k.Close()
	str := func(v string) string { s, _, _ := k.GetStringValue(v); return strings.TrimSpace(s) }
	num := func(v string) uint64 { n, _, _ := k.GetIntegerValue(v); return n }
	a := App{Name: str("DisplayName"), Version: str("DisplayVersion"), ID: name, Publisher: str("Publisher"),
		Path: strings.Trim(str("InstallLocation"), `"`), Uninstaller: str("UninstallString")}
	if a.Name == "" || a.Uninstaller == "" || num("SystemComponent") == 1 || str("ParentKeyName") != "" {
		return App{}, false
	}
	switch str("ReleaseType") {
	case "Update", "Hotfix", "Security Update", "Service Pack":
		return App{}, false
	}
	if kb := num("EstimatedSize"); kb > 0 {
		a.Bytes = int64(kb) * 1024
	} else if a.Path != "" {
		a.Bytes = fsx.Size(a.Path)
	}
	if t, err := time.Parse("20060102", str("InstallDate")); err == nil {
		a.LastUsed = t
	}
	return a, true
}

func dataRoots() []string {
	return []string{os.Getenv("LOCALAPPDATA"), os.Getenv("APPDATA"), os.Getenv("ProgramData"),
		filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs")}
}

// Leftovers finds the app's install folder and the folders named after it in
// AppData and ProgramData: "<name>", "<publisher>\<name>", and for names that
// start with the publisher, "<publisher>\<rest>" (Mozilla Firefox ->
// Mozilla\Firefox).
func Leftovers(app App, _ string, _ []string) []Leftover {
	name := baseName(app.Name)
	if len(name) < 3 {
		return nil
	}
	var candidates []string
	publisher := strings.Fields(app.Publisher)
	for _, root := range dataRoots() {
		if root == "" {
			continue
		}
		candidates = append(candidates, filepath.Join(root, name))
		if app.Publisher != "" {
			candidates = append(candidates, filepath.Join(root, app.Publisher, name))
		}
		if len(publisher) > 0 && hasPrefixFold(name, publisher[0]+" ") {
			candidates = append(candidates, filepath.Join(root, publisher[0], strings.TrimSpace(name[len(publisher[0]):])))
		}
	}
	var list []Leftover
	seen := map[string]bool{}
	if app.Path != "" && isDir(app.Path) && safeInstallDir(app.Path) {
		seen[strings.ToLower(filepath.Clean(app.Path))] = true
		list = append(list, Leftover{Path: filepath.Clean(app.Path), Bytes: fsx.Size(app.Path), Why: "install folder"})
	}
	for _, c := range candidates {
		key := strings.ToLower(filepath.Clean(c))
		if seen[key] || !isDir(c) {
			continue
		}
		seen[key] = true
		list = append(list, Leftover{Path: filepath.Clean(c), Bytes: fsx.Size(c), Why: "same name"})
	}
	return list
}

// safeInstallDir rejects install locations that are not an app's own
// folder: a drive root, or a system, program or profile folder, or a folder
// that contains one. Some uninstall entries are written carelessly.
func safeInstallDir(path string) bool {
	path = filepath.Clean(path)
	if len(path) <= 3 { // "C:\"
		return false
	}
	for _, env := range []string{"ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "windir", "SystemRoot",
		"USERPROFILE", "PUBLIC", "ProgramData", "LOCALAPPDATA", "APPDATA", "CommonProgramFiles", "CommonProgramFiles(x86)"} {
		v := os.Getenv(env)
		if v == "" {
			continue
		}
		v = filepath.Clean(v)
		if strings.EqualFold(path, v) || fsx.Under(v, path) {
			return false
		}
	}
	for _, p := range append(dataRoots(), filepath.Join(filepath.VolumeName(path)+`\`, "Users")) {
		if p != "" && (strings.EqualFold(path, filepath.Clean(p)) || fsx.Under(filepath.Clean(p), path)) {
			return false
		}
	}
	return true
}

func isDir(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && !fsx.IsLink(path, info)
}

// Running is not checked on Windows: the app's uninstaller handles a running
// app itself, and files in use stay where they are.
func Running(App) bool { return false }

// UninstallCommand is the command line that uninstalls the app. MSI entries
// often say /I (change), which opens a repair dialog; /X removes.
func UninstallCommand(app App) string {
	cmd := app.Uninstaller
	if m := regexp.MustCompile(`(?i)^msiexec(\.exe)?\s+/I\s*(\{[0-9A-F-]+\})`).FindStringSubmatch(cmd); m != nil {
		return "MsiExec.exe /X" + m[2]
	}
	return cmd
}

// RunUninstaller runs the app's own uninstaller and waits for it.
func RunUninstaller(app App) error {
	cmd := exec.Command("cmd.exe")
	// The command line is used as Windows stores it, quotes and all.
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /d /c "` + UninstallCommand(app) + `"`}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

// Remove moves one file or folder to the Trash or Recycle Bin.
func Remove(path string) error { return fsx.Trash(path) }

// Allowed reports whether medic may move path to the Recycle Bin for an
// uninstall: a folder directly inside AppData, ProgramData or Programs, one
// level down for publisher folders, or the app's install folder.
func Allowed(path string, app App, _ string) bool {
	if app.Path != "" && strings.EqualFold(filepath.Clean(path), filepath.Clean(app.Path)) {
		return safeInstallDir(path)
	}
	for _, root := range dataRoots() {
		if root == "" || !fsx.Under(path, root) {
			continue
		}
		rel, err := filepath.Rel(root, path)
		if err == nil && len(strings.Split(rel, `\`)) <= 2 {
			return true
		}
	}
	return false
}

// TrashName is what the Trash is called on this system.
const TrashName = "Recycle Bin"
