//go:build !windows

package fsx

import (
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

type fileID struct{ dev, ino uint64 }

// diskUsage counts allocated blocks, and hard links only once, like du.
func diskUsage(info fs.FileInfo, seen map[fileID]bool) int64 {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info.Size()
	}
	if st.Nlink > 1 && !info.IsDir() {
		id := fileID{uint64(st.Dev), uint64(st.Ino)}
		if seen[id] {
			return 0
		}
		seen[id] = true
	}
	return int64(st.Blocks) * 512
}

func isReparsePoint(string, fs.FileInfo) bool { return false }

func remove(path string, _ fs.FileInfo) { _ = os.Remove(path) }

// SameDevice reports whether two Lstat results are on the same file system.
func SameDevice(a, b fs.FileInfo) bool {
	sa, ok1 := a.Sys().(*syscall.Stat_t)
	sb, ok2 := b.Sys().(*syscall.Stat_t)
	return !ok1 || !ok2 || sa.Dev == sb.Dev
}

// ID identifies a folder, so two paths to it (like ~/code and ~/Code on a
// case-insensitive disk) count once.
func ID(path string, info fs.FileInfo) string {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return fmt.Sprintf("%d:%d", st.Dev, st.Ino)
	}
	return path
}

// linkEntry reports whether a directory entry is a link. On macOS the listing
// already says so: a symlink is never reported as a folder.
func linkEntry(os.DirEntry) bool { return false }
