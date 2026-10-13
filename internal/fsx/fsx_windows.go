//go:build windows

package fsx

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

type fileID struct{}

const (
	attrReparsePoint = 0x400
	// Offline | RecallOnOpen | RecallOnDataAccess: OneDrive placeholders that
	// take no space on this disk.
	attrCloudOnly = 0x441000
)

func attributes(info fs.FileInfo) uint32 {
	if d, ok := info.Sys().(*syscall.Win32FileAttributeData); ok {
		return d.FileAttributes
	}
	return 0
}

func diskUsage(info fs.FileInfo, _ map[fileID]bool) int64 {
	if attributes(info)&attrCloudOnly != 0 {
		return 0
	}
	return info.Size()
}

func isReparsePoint(_ string, info fs.FileInfo) bool {
	return attributes(info)&attrReparsePoint != 0 || info.Mode()&fs.ModeIrregular != 0
}

// remove deletes one file, empty folder or link. Read-only files are made
// writable first; files in use stay.
func remove(path string, info fs.FileInfo) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	_ = syscall.SetFileAttributes(p, syscall.FILE_ATTRIBUTE_NORMAL)
	if info.IsDir() || attributes(info)&syscall.FILE_ATTRIBUTE_DIRECTORY != 0 {
		// RemoveDirectory on a junction or directory symlink removes the link only.
		_ = syscall.RemoveDirectory(p)
		return
	}
	_ = syscall.DeleteFile(p)
}

// SameDevice reports whether two results are on the same drive. Windows has
// no mount points inside the profile that matter here.
func SameDevice(_, _ fs.FileInfo) bool { return true }

// ID identifies a folder by its full path: NTFS paths are unique ignoring case.
func ID(path string, _ fs.FileInfo) string { return strings.ToLower(filepath.Clean(path)) }

// linkEntry reports whether a directory entry is a junction or symlink. Go
// may report a junction as a folder, so the attributes from the listing,
// which cost no extra call, decide.
func linkEntry(e os.DirEntry) bool {
	info, err := e.Info()
	return err != nil || attributes(info)&attrReparsePoint != 0
}

var procSHFileOperation = syscall.NewLazyDLL("shell32.dll").NewProc("SHFileOperationW")

type shFileOpStruct struct {
	Hwnd                 uintptr
	Func                 uint32
	From                 *uint16
	To                   *uint16
	Flags                uint16
	AnyOperationsAborted int32
	NameMappings         uintptr
	ProgressTitle        *uint16
}

// Trash moves path to the Recycle Bin, so it can be restored.
func Trash(path string) error {
	if _, err := os.Lstat(path); err != nil {
		return nil
	}
	const (
		foDelete          = 3
		fofSilent         = 0x4
		fofNoConfirmation = 0x10
		fofAllowUndo      = 0x40
		fofNoErrorUI      = 0x400
	)
	from, err := syscall.UTF16FromString(path)
	if err != nil {
		return err
	}
	from = append(from, 0) // the list ends with two NULs
	op := shFileOpStruct{Func: foDelete, From: &from[0], Flags: fofSilent | fofNoConfirmation | fofAllowUndo | fofNoErrorUI}
	if r, _, _ := procSHFileOperation.Call(uintptr(unsafe.Pointer(&op))); r != 0 || op.AnyOperationsAborted != 0 {
		return fmt.Errorf("the Recycle Bin refused it (code %d)", r)
	}
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("it is still there, maybe in use")
	}
	return nil
}
