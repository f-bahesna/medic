package items

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
	"github.com/f-bahesna/medic/internal/ui"
)

// Collect lists the known locations for this Mac, with the installers in
// Downloads and on the Desktop found and measured. Measure does the rest.
func Collect(home string) []*Item {
	var conda, photos []string
	for _, p := range []string{"miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "opt/anaconda3/pkgs"} {
		if isDir(filepath.Join(home, p)) {
			conda = append(conda, filepath.Join(home, p))
		}
	}
	libs, _ := filepath.Glob(filepath.Join(home, "Pictures", "*.photoslibrary"))
	for _, lib := range libs {
		if isDir(lib) {
			photos = append(photos, lib)
		}
	}
	list := MacItems(home, has, conda, photos)
	if files := findInstallers(home); len(files) > 0 {
		var total int64
		for _, f := range files {
			total += fsx.Size(f)
		}
		list = append(list, MacInstallers(files, total))
	}
	return list
}

// Describe fills in the commands that clean each item by hand.
func Describe(list []*Item, home string) { DescribeMac(list, home, fsx.HasContent) }

// findInstallers lists disk images and installer packages in Downloads and on
// the Desktop, up to three folders deep.
func findInstallers(home string) []string {
	var files []string
	for _, root := range []string{filepath.Join(home, "Downloads"), filepath.Join(home, "Desktop")} {
		walkDepth(root, 3, func(path string, e os.DirEntry) {
			switch strings.ToLower(filepath.Ext(e.Name())) {
			case ".dmg", ".pkg", ".xip", ".iso":
				if e.Type().IsRegular() {
					files = append(files, path)
				}
			}
		})
	}
	return files
}

// Clean cleans one item. With dry set it only says what it would do. It
// returns false when the item could not be cleaned.
func Clean(it *Item, home string, dry bool, p *ui.Printer) bool {
	switch it.ID {
	case "trash":
		return emptyTrash(filepath.Join(home, ".Trash"), dry, p)
	case "sim_devices":
		return run(p, dry, "xcrun", "simctl", "delete", "unavailable")
	case "docker":
		if exec.Command("docker", "info").Run() != nil {
			p.Warn("Docker is not running. Start Docker Desktop and try again.")
			return false
		}
		return run(p, dry, macToolCommand(it.ID)...)
	case "npm", "pnpm", "go_mod", "conda":
		return run(p, dry, macToolCommand(it.ID)...)
	case "installers":
		for _, f := range it.Files {
			if !isFile(f) {
				continue
			}
			if dry {
				p.Note("would move to Trash: %s", ui.Tilde(f, home))
				continue
			}
			if err := fsx.Trash(f); err != nil {
				p.Warn("could not move %s to the Trash: %v", ui.Tilde(f, home), err)
			}
		}
		return true
	}
	ok := true
	for _, d := range it.Paths {
		ok = emptyAllowed(d, macCleanableDirs(home), home, dry, p) && ok
	}
	return ok
}

// emptyTrash empties the Trash. With Full Disk Access medic does it itself;
// without, macOS hides the Trash from the terminal and Finder has to, which
// may ask once for permission to control Finder.
func emptyTrash(trash string, dry bool, p *ui.Printer) bool {
	if dry {
		p.Note("would empty the Trash")
		return true
	}
	if _, err := os.ReadDir(trash); err == nil {
		fsx.EmptyDir(trash)
		return true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := exec.CommandContext(ctx, "osascript", "-e", `tell application "Finder" to empty trash`).Run(); err != nil {
		p.Warn("could not empty the Trash: allow the terminal to control Finder, or empty it in Finder")
		return false
	}
	return true
}

// emptyAllowed deletes the contents of dir, only if it is on the allowlist
// and not a symlink.
func emptyAllowed(dir string, allowed []string, home string, dry bool, p *ui.Printer) bool {
	if !contains(allowed, dir) {
		p.Warn("refusing to touch %s (not on the allowlist)", dir)
		return false
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return true
	}
	if fsx.IsLink(dir, info) || !info.IsDir() {
		p.Warn("refusing to touch %s (it is a symlink)", dir)
		return false
	}
	if dry {
		p.Note("would delete the contents of %s", ui.Tilde(dir, home))
		return true
	}
	fsx.EmptyDir(dir)
	return true
}
