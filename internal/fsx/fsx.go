// Package fsx measures and deletes files without ever following a symlink or
// junction, so nothing outside the given folder is counted or touched.
package fsx

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
)

// Size is the disk space used by path and everything below it, in bytes.
// Links are not followed. On macOS it counts allocated blocks like du, on
// Windows the file sizes, skipping cloud-only OneDrive files. Unreadable
// folders count as empty.
func Size(path string) int64 {
	info, err := os.Lstat(path)
	if err != nil {
		return 0
	}
	seen := map[fileID]bool{}
	if !info.IsDir() || IsLink(path, info) {
		return diskUsage(info, seen)
	}
	var total atomic.Int64
	var mu sync.Mutex
	Walk(path, nil, func(_ string, e os.DirEntry) {
		if info, err := e.Info(); err == nil {
			mu.Lock()
			total.Add(diskUsage(info, seen))
			mu.Unlock()
		}
	})
	return total.Load()
}

// Walk visits everything below root, reading folders in parallel. It never
// enters a link. enter decides whether to go into a folder (nil: always);
// visit gets every other entry. Both are called from several goroutines.
func Walk(root string, enter func(path string, e os.DirEntry) bool, visit func(path string, e os.DirEntry)) {
	w := &walker{enter: enter, visit: visit, slots: make(chan struct{}, 16)}
	w.wg.Add(1)
	w.dir(root)
	w.wg.Wait()
}

type walker struct {
	enter func(string, os.DirEntry) bool
	visit func(string, os.DirEntry)
	wg    sync.WaitGroup
	slots chan struct{} // limits the goroutines reading folders
}

func (w *walker) dir(dir string) {
	defer w.wg.Done()
	for _, e := range readDir(dir) {
		full := filepath.Join(dir, e.Name())
		if !e.IsDir() || linkEntry(e) {
			w.visit(full, e)
			continue
		}
		if w.enter != nil && !w.enter(full, e) {
			continue
		}
		w.wg.Add(1)
		select {
		case w.slots <- struct{}{}:
			go func() {
				w.dir(full)
				<-w.slots
			}()
		default:
			w.dir(full)
		}
	}
}

// readDir lists a folder without sorting it, which os.ReadDir does.
func readDir(dir string) []os.DirEntry {
	f, err := os.Open(dir)
	if err != nil {
		return nil
	}
	defer f.Close()
	entries, _ := f.ReadDir(-1)
	return entries
}

// IsLink reports whether info (from Lstat or ReadDir) is a symlink, or on
// Windows any reparse point such as a junction.
func IsLink(path string, info fs.FileInfo) bool {
	return info.Mode()&fs.ModeSymlink != 0 || isReparsePoint(path, info)
}

// HasContent reports whether dir has at least one entry.
func HasContent(dir string) bool {
	f, err := os.Open(dir)
	if err != nil {
		return false
	}
	defer f.Close()
	names, _ := f.Readdirnames(1)
	return len(names) > 0
}

// EmptyDir deletes everything inside dir but not dir itself. Links inside are
// removed, never followed. Files that are in use are skipped.
func EmptyDir(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		RemoveTree(filepath.Join(dir, e.Name()))
	}
}

// RemoveTree deletes path and everything below it, best effort. A link is
// removed itself, never followed.
func RemoveTree(path string) {
	info, err := os.Lstat(path)
	if err != nil {
		return
	}
	if info.IsDir() && !IsLink(path, info) {
		EmptyDir(path)
	}
	remove(path, info)
}

// Under reports whether path is inside root (not root itself), comparing like
// the file system does: case-insensitive on macOS and Windows.
func Under(path, root string) bool {
	root = strings.TrimRight(root, `/\`)
	if len(path) <= len(root)+1 || !strings.EqualFold(path[:len(root)], root) {
		return false
	}
	return os.IsPathSeparator(path[len(root)])
}
