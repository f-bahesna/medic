package scan

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
)

// PurgeNames are the folder names purge looks for. PurgeKind checks the file
// next to them (or in them, for venvs) that proves what they are.
var PurgeNames = []string{"node_modules", ".next", ".venv", "venv", "target", "build"}

func isPurgeName(name string) bool {
	for _, n := range PurgeNames {
		if strings.EqualFold(n, name) {
			return true
		}
	}
	return false
}

// PurgeKind says what dir is, or "" when it is not a folder purge may delete.
func PurgeKind(dir string) string {
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || fsx.IsLink(dir, info) {
		return ""
	}
	parent := filepath.Dir(dir)
	next := func(name string) bool { return isFile(filepath.Join(parent, name)) }
	switch strings.ToLower(filepath.Base(dir)) {
	case "node_modules":
		if next("package.json") {
			return "node_modules"
		}
	case ".next":
		if next("package.json") {
			return "Next.js build"
		}
	case ".venv", "venv":
		if isFile(filepath.Join(dir, "pyvenv.cfg")) {
			return "Python venv"
		}
	case "target":
		if next("Cargo.toml") {
			return "Rust build"
		}
		if next("pom.xml") {
			return "Maven build"
		}
	case "build":
		if next("build.gradle") || next("build.gradle.kts") {
			return "Gradle build"
		}
	}
	return ""
}

var errActive = errors.New("active")

// ProjectActive reports whether any file in dir changed in the last days.
// Purgeable folders and .git are skipped: installs and fetches are not work.
func ProjectActive(dir string, days int) bool {
	if days <= 0 {
		return false
	}
	since := time.Now().AddDate(0, 0, -days)
	err := filepath.WalkDir(dir, func(path string, e os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		info, err := e.Info()
		if err != nil {
			return nil
		}
		if e.IsDir() {
			if path != dir && (e.Name() == ".git" || isPurgeName(e.Name()) || fsx.IsLink(path, info)) {
				return filepath.SkipDir
			}
			return nil
		}
		if info.Mode().IsRegular() && info.ModTime().After(since) {
			return errActive
		}
		return nil
	})
	return err == errActive
}

// PurgeFolders is every purgeable folder in the roots whose project had no
// file changed in the last days (0 for all), biggest first. progress gets
// each folder before it is measured.
func PurgeFolders(roots []string, days int, progress func(path string)) []Entry {
	var list []Entry
	walk(roots, func(path string, e os.DirEntry) bool {
		if e.Name() == ".git" {
			return false
		}
		if !isPurgeName(e.Name()) {
			return true
		}
		if kind := PurgeKind(path); kind != "" && !ProjectActive(filepath.Dir(path), days) {
			if progress != nil {
				progress(path)
			}
			list = append(list, Entry{Path: path, Kind: kind, Bytes: fsx.Size(path)})
		}
		return false
	})
	return bySize(list)
}

// CanPurge reports whether path is a purgeable folder inside one of the roots.
// Checked again right before deleting.
func CanPurge(path string, roots []string) bool {
	for _, r := range roots {
		if fsx.Under(path, r) {
			return PurgeKind(path) != ""
		}
	}
	return false
}
