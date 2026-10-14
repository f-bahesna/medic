// Package apps lists installed applications and finds what each one left in
// the user's folders, so medic uninstall can show it all for review before
// anything is moved to the Trash or Recycle Bin.
package apps

import (
	"regexp"
	"sort"
	"strings"
	"time"
)

// App is an installed application.
type App struct {
	Name      string
	Version   string
	ID        string // macOS bundle id, Windows uninstall registry key
	Publisher string
	Path      string // macOS: the .app bundle; Windows: the install folder, if known
	Bytes     int64
	LastUsed  time.Time // macOS: last opened; Windows: installed
	// Windows: the app's own uninstaller, a command line.
	Uninstaller string
}

// Leftover is a file or folder an app keeps outside its own bundle or folder.
type Leftover struct {
	Path  string
	Bytes int64
	Why   string // "bundle id" or "same name": how it was matched
}

// Find returns the apps a query names: the one whose name matches exactly
// (ignoring case), or else every app whose name contains it.
func Find(list []App, query string) []App {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil
	}
	var contains []App
	for _, a := range list {
		if strings.EqualFold(a.Name, query) {
			return []App{a}
		}
		if strings.Contains(strings.ToLower(a.Name), strings.ToLower(query)) {
			contains = append(contains, a)
		}
	}
	return contains
}

func bySize(list []App) []App {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].Bytes != list[j].Bytes {
			return list[i].Bytes > list[j].Bytes
		}
		return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name)
	})
	return list
}

// baseName is the app's name without a trailing version, architecture or
// language, like "Mozilla Firefox (x64 en-US)" -> "Mozilla Firefox".
var nameTail = regexp.MustCompile(`(?i)(\s+(\(.*\)|v?\d[\d.]*|x64|x86|64-bit|32-bit))+$`)

func baseName(name string) string { return strings.TrimSpace(nameTail.ReplaceAllString(name, "")) }

var teamPrefix = regexp.MustCompile(`^[A-Z0-9]{10}\.`)

// belongsTo reports whether a folder entry named name belongs to the app with
// bundle id id: the id itself, or the id of one of its parts (id.Helper,
// id.ShipIt.<uuid>), optionally after a team id for group containers. An
// entry that matches another installed app's longer id belongs to that app,
// so com.google.Chrome.canary is not counted as Chrome's.
func belongsTo(name, id string, others []string) bool {
	if id == "" {
		return false
	}
	for _, suffix := range []string{".plist", ".savedState", ".binarycookies"} {
		name = strings.TrimSuffix(name, suffix)
	}
	name = teamPrefix.ReplaceAllString(name, "")
	if !strings.EqualFold(name, id) && !hasPrefixFold(name, id+".") {
		return false
	}
	for _, other := range others {
		if len(other) > len(id) && hasPrefixFold(other, id+".") &&
			(strings.EqualFold(name, other) || hasPrefixFold(name, other+".")) {
			return false
		}
	}
	return true
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}
