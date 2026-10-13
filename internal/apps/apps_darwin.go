package apps

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
)

// appDirs are where apps are installed: directly, or one folder down
// (/Applications/Utilities, vendor folders like /Applications/Datacolor).
func appDirs(home string) []string {
	return []string{"/Applications", filepath.Join(home, "Applications")}
}

func plistValue(app, key string) string {
	out, err := exec.Command("plutil", "-extract", key, "raw", "-o", "-", filepath.Join(app, "Contents", "Info.plist")).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// List returns the installed apps, biggest first. Apple's own apps are left
// out: macOS protects them and reinstalls them with updates.
func List(home string) []App {
	var paths []string
	for _, dir := range appDirs(home) {
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			path := filepath.Join(dir, e.Name())
			if strings.HasSuffix(e.Name(), ".app") {
				paths = append(paths, path)
				continue
			}
			if e.IsDir() {
				inner, _ := os.ReadDir(path)
				for _, i := range inner {
					if strings.HasSuffix(i.Name(), ".app") {
						paths = append(paths, filepath.Join(path, i.Name()))
					}
				}
			}
		}
	}
	used := lastUsed(paths)
	var list []App
	for _, p := range paths {
		info, err := os.Lstat(p)
		if err != nil || !info.IsDir() {
			continue
		}
		id := plistValue(p, "CFBundleIdentifier")
		if strings.HasPrefix(id, "com.apple.") {
			continue
		}
		list = append(list, App{
			Name:     strings.TrimSuffix(filepath.Base(p), ".app"),
			Version:  plistValue(p, "CFBundleShortVersionString"),
			ID:       id,
			Path:     p,
			Bytes:    fsx.Size(p),
			LastUsed: used[p],
		})
	}
	return bySize(list)
}

// lastUsed asks Spotlight when each app was last opened, in one call.
func lastUsed(paths []string) map[string]time.Time {
	out := map[string]time.Time{}
	if len(paths) == 0 {
		return out
	}
	args := append([]string{"-raw", "-name", "kMDItemLastUsedDate"}, paths...)
	raw, err := exec.Command("mdls", args...).Output()
	if err != nil {
		return out
	}
	values := bytes.Split(raw, []byte{0})
	for i, p := range paths {
		if i < len(values) {
			if t, err := time.Parse("2006-01-02 15:04:05 -0700", strings.TrimSpace(string(values[i]))); err == nil {
				out[p] = t
			}
		}
	}
	return out
}

// leftoverDirs are the folders in ~/Library where apps keep data, and
// whether an entry may also match by the app's name there.
var leftoverDirs = []struct {
	dir    string
	byName bool
}{
	{"Application Support", true},
	{"Caches", true},
	{"Logs", true},
	{"Containers", false},
	{"Group Containers", false},
	{"Application Scripts", false},
	{"Preferences", false},
	{"Preferences/ByHost", false},
	{"Saved Application State", false},
	{"HTTPStorages", false},
	{"WebKit", false},
	{"Cookies", false},
	{"LaunchAgents", false},
}

// Leftovers finds what app keeps in ~/Library, matched by its bundle id or,
// in a few folders, by its exact name. others are the bundle ids of every
// installed app, so another app's data is never claimed.
func Leftovers(app App, home string, others []string) []Leftover {
	var list []Leftover
	for _, d := range leftoverDirs {
		dir := filepath.Join(home, "Library", d.dir)
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			why := ""
			switch {
			case belongsTo(e.Name(), app.ID, others):
				why = "bundle id"
			case d.byName && len(app.Name) >= 3 && strings.EqualFold(e.Name(), app.Name):
				why = "same name"
			default:
				continue
			}
			path := filepath.Join(dir, e.Name())
			list = append(list, Leftover{Path: path, Bytes: fsx.Size(path), Why: why})
		}
	}
	return list
}

// Running reports whether any process runs from inside the app bundle.
func Running(app App) bool {
	out, _ := exec.Command("ps", "-axo", "comm=").Output()
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), app.Path+"/") {
			return true
		}
	}
	return false
}

// Remove moves one file or folder to the Trash or Recycle Bin.
func Remove(path string) error { return fsx.Trash(path) }

// Allowed reports whether medic may move path to the Trash for an uninstall:
// an app bundle in an app folder, or an entry in a ~/Library data folder.
func Allowed(path string, _ App, home string) bool {
	for _, dir := range appDirs(home) {
		if fsx.Under(path, dir) && strings.HasSuffix(path, ".app") {
			return true
		}
	}
	for _, d := range leftoverDirs {
		if filepath.Dir(path) == filepath.Join(home, "Library", d.dir) {
			return true
		}
	}
	return false
}

// TrashName is what the Trash is called on this system.
const TrashName = "Trash"

// UninstallCommand is empty on macOS: an app is its bundle, there is no
// uninstaller to run.
func UninstallCommand(App) string { return "" }

// RunUninstaller has nothing to run on macOS.
func RunUninstaller(App) error { return nil }
