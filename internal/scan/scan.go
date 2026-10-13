// Package scan finds what the fixed list of locations cannot: the biggest
// folders in the app data folders, dependency folders in projects, large
// files, and the dependency and build folders purge can delete.
package scan

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
)

// Entry is a measured folder or file.
type Entry struct {
	Path     string
	Name     string
	Bytes    int64
	Kind     string    // purge: what the folder is
	Modified time.Time // large files
	Hint     string    // breakdowns: what it is or how to clean it
}

func bySize(list []Entry) []Entry {
	sort.SliceStable(list, func(i, j int) bool { return list[i].Bytes > list[j].Bytes })
	return list
}

// Breakdown is the biggest entries directly inside dir, at least 1 MB, at
// most count of them. Hidden entries and links are skipped.
func Breakdown(dir string, count int) []Entry {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var list []Entry
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		info, err := e.Info()
		if err != nil || strings.HasPrefix(e.Name(), ".") || fsx.IsLink(path, info) {
			continue
		}
		if b := fsx.Size(path); b >= 1<<20 {
			list = append(list, Entry{Path: path, Name: e.Name(), Bytes: b, Hint: cacheHint(e.Name())})
		}
	}
	list = bySize(list)
	if len(list) > count {
		list = list[:count]
	}
	return list
}

// DevRoots is the project folders that exist, each once: the usual places in
// home plus extra.
func DevRoots(home string, extra []string) []string {
	var roots []string
	seen := map[string]bool{}
	for _, r := range append(devRootCandidates(home), extra...) {
		abs, err := filepath.Abs(r)
		if err != nil {
			continue
		}
		info, err := os.Stat(abs)
		if err != nil || !info.IsDir() {
			continue
		}
		// The default file system is case-insensitive, so ~/code and ~/Code
		// can be the same folder.
		id := fsx.ID(abs, info)
		if seen[id] {
			continue
		}
		seen[id] = true
		if real, err := filepath.EvalSymlinks(abs); err == nil {
			abs = real
		}
		roots = append(roots, abs)
	}
	return roots
}

// walk visits every folder below the roots, without following links. visit
// returns false to not go into a folder.
func walk(roots []string, visit func(path string, e os.DirEntry) bool) {
	stack := append([]string(nil), roots...)
	for len(stack) > 0 {
		dir := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			path := filepath.Join(dir, e.Name())
			info, err := e.Info()
			if err != nil || fsx.IsLink(path, info) {
				continue
			}
			if visit(path, e) {
				stack = append(stack, path)
			}
		}
	}
}

// DevFolders is every node_modules and Python virtualenv in the roots,
// biggest first.
func DevFolders(roots []string) []Entry {
	var list []Entry
	walk(roots, func(path string, e os.DirEntry) bool {
		switch e.Name() {
		case ".git":
			return false
		case "node_modules":
			list = append(list, Entry{Path: path, Bytes: fsx.Size(path)})
			return false
		case ".venv", "venv":
			if isFile(filepath.Join(path, "pyvenv.cfg")) {
				list = append(list, Entry{Path: path, Bytes: fsx.Size(path)})
				return false
			}
		}
		return true
	})
	return bySize(list)
}

// LargeFiles is the 15 biggest files of at least minBytes in home, skipping
// app data, dependency folders and other disks.
func LargeFiles(home string, minBytes int64) []Entry {
	rootInfo, err := os.Lstat(home)
	if err != nil {
		return nil
	}
	var mu sync.Mutex
	var list []Entry
	fsx.Walk(home, func(path string, e os.DirEntry) bool {
		if skipForLargeFiles(home, path, e.Name()) {
			return false
		}
		info, err := e.Info()
		return err == nil && fsx.SameDevice(rootInfo, info)
	}, func(path string, e os.DirEntry) {
		if !e.Type().IsRegular() {
			return
		}
		info, err := e.Info()
		if err != nil || info.Size() < minBytes {
			return
		}
		if b := fsx.Size(path); b > 0 {
			mu.Lock()
			list = append(list, Entry{Path: path, Bytes: b, Modified: info.ModTime()})
			mu.Unlock()
		}
	})
	list = bySize(list)
	if len(list) > 15 {
		list = list[:15]
	}
	return list
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
