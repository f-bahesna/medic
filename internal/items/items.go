// Package items is the list of known space hogs: where they are, how safe
// they are to clean, how to measure them and how to clean them.
package items

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/f-bahesna/medic/internal/fsx"
	"github.com/f-bahesna/medic/internal/ui"
)

// Safety levels.
const (
	Safe    = "SAFE"    // regenerated automatically, no data loss
	Caution = "CAUTION" // regenerable, but you lose more than a cache
	Review  = "REVIEW"  // may contain your data, never cleaned
)

// ClearFolderHelper is pasted once (Windows) before the Clear-Folder commands. It empties
// a folder without following links: rd removes a junction without entering it,
// while Remove-Item -Recurse in Windows PowerShell 5.1 follows them.
const ClearFolderHelper = `function Clear-Folder($Path) { Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object { if ($_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { cmd /c rd "$($_.FullName)" } elseif ($_.PSIsContainer) { cmd /c rd /s /q "$($_.FullName)" 2>$null } else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } } }`

// Item is one known location.
type Item struct {
	ID        string
	Safety    string
	Label     string
	Note      string
	Paths     []string
	Cleanable bool     // a cleanup exists and its tool is installed
	Admin     bool     // Windows: needs "Run as administrator"
	Files     []string // single files, for installers
	Bytes     int64
	Measured  bool     // Bytes is known; Measure skips the item
	Commands  []string // commands that clean it by hand, from Describe
}

// CanClean reports whether medic's cleanup may touch the item.
func (it *Item) CanClean() bool { return it.Cleanable && it.Safety != Review }

func add(list *[]*Item, it Item) { *list = append(*list, &it) }

func has(tool string) bool {
	_, err := exec.LookPath(tool)
	return err == nil
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func isFile(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode().IsRegular()
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if strings.EqualFold(x, s) {
			return true
		}
	}
	return false
}

// walkDepth calls fn for every entry below root, at most depth folders deep,
// without following links.
func walkDepth(root string, depth int, fn func(path string, e os.DirEntry)) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, e := range entries {
		path := filepath.Join(root, e.Name())
		fn(path, e)
		if e.IsDir() && depth > 1 {
			if info, err := e.Info(); err == nil && !fsx.IsLink(path, info) {
				walkDepth(path, depth-1, fn)
			}
		}
	}
}

// run runs a cleanup tool, or with dry set says that it would.
func run(p *ui.Printer, dry bool, args ...string) bool {
	if dry {
		p.Note("would run: %s", strings.Join(args, " "))
		return true
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout, cmd.Stderr = p.W, p.W
	if err := cmd.Run(); err != nil {
		p.Warn("%s failed: %v", args[0], err)
		return false
	}
	return true
}

// Measure fills in the size of every item, several at a time. progress is
// called from one goroutine with the label of each finished item.
func Measure(list []*Item, progress func(label string)) {
	type result struct {
		it    *Item
		bytes int64
	}
	work := make(chan *Item)
	done := make(chan result)
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range work {
				var total int64
				for _, p := range it.Paths {
					total += fsx.Size(p)
				}
				done <- result{it, total}
			}
		}()
	}
	go func() {
		for _, it := range list {
			if !it.Measured {
				work <- it
			}
		}
		close(work)
		wg.Wait()
		close(done)
	}()
	for r := range done {
		r.it.Bytes, r.it.Measured = r.bytes, true
		if progress != nil {
			progress(r.it.Label)
		}
	}
}

// Visible is every item of 1 MB or more, biggest first.
func Visible(list []*Item) []*Item {
	var out []*Item
	for _, it := range list {
		if it.Bytes >= 1<<20 {
			out = append(out, it)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Bytes > out[j].Bytes })
	return out
}

// Totals sums the visible items per safety level.
func Totals(list []*Item) map[string]int64 {
	t := map[string]int64{Safe: 0, Caution: 0, Review: 0}
	for _, it := range Visible(list) {
		t[it.Safety] += it.Bytes
	}
	return t
}
