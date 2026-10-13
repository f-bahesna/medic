//go:build !windows

package fsx

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
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

// Trash moves path to the user's Trash, so it can be put back. It moves it
// itself, which needs no permission prompt. Only when that is not allowed,
// like an App Store app owned by root, Finder does it and asks for a password.
func Trash(path string) error {
	if _, err := os.Lstat(path); err != nil {
		return nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	trash := filepath.Join(home, ".Trash")
	_ = os.MkdirAll(trash, 0o700)
	if err = os.Rename(path, freeName(trash, filepath.Base(path))); err == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	out, ferr := exec.CommandContext(ctx, "osascript", "-e", "on run argv", "-e", "set f to POSIX file (item 1 of argv) as alias",
		"-e", `tell application "Finder" to delete f`, "-e", "end run", path).CombinedOutput()
	if ferr != nil {
		return fmt.Errorf("%v (%s); drag it to the Trash in Finder instead", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// freeName is dir/name, or dir/"name <time>" when the Trash already has one.
func freeName(dir, name string) string {
	dest := filepath.Join(dir, name)
	if _, err := os.Lstat(dest); err != nil {
		return dest
	}
	ext := filepath.Ext(name)
	if strings.HasSuffix(name, ".app") || ext == name {
		ext = ""
	}
	return filepath.Join(dir, strings.TrimSuffix(name, ext)+" "+time.Now().Format("15.04.05.000")+ext)
}
