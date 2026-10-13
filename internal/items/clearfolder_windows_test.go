package items

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The Clear-Folder helper printed under "Delete commands" must empty a folder,
// read-only files included, without touching what junctions inside point to.
// It runs exactly as users paste it, in both Windows PowerShell and pwsh.
func TestClearFolderHelper(t *testing.T) {
	for _, shell := range []string{"powershell.exe", "pwsh.exe"} {
		if _, err := exec.LookPath(shell); err != nil {
			continue
		}
		t.Run(shell, func(t *testing.T) {
			root := t.TempDir()
			cache, target := filepath.Join(root, "cache"), filepath.Join(root, "target")
			for _, d := range []string{filepath.Join(cache, "sub"), target} {
				if err := os.MkdirAll(d, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			keep := filepath.Join(target, "keep.txt")
			for _, f := range []string{keep, filepath.Join(cache, "top.txt"), filepath.Join(cache, "sub", "deep.txt")} {
				if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			_ = os.Chmod(filepath.Join(cache, "sub", "deep.txt"), 0o444)
			for _, l := range []string{filepath.Join(cache, "link"), filepath.Join(cache, "sub", "deeplink")} {
				if out, err := exec.Command("cmd", "/c", "mklink", "/J", l, target).CombinedOutput(); err != nil {
					t.Fatalf("mklink: %v: %s", err, out)
				}
			}

			script := ClearFolderHelper + "\nClear-Folder '" + cache + "'"
			if out, err := exec.Command(shell, "-NoProfile", "-NonInteractive", "-Command", script).CombinedOutput(); err != nil {
				t.Fatalf("%s: %v: %s", shell, err, out)
			}
			if entries, _ := os.ReadDir(cache); len(entries) != 0 {
				t.Errorf("cache not emptied, left: %v", entries)
			}
			if _, err := os.Stat(keep); err != nil {
				t.Error("a junction target was deleted")
			}
		})
	}
}
