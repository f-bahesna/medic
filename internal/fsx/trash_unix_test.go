//go:build !windows

package fsx

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTrashMovesIntoTheTrashWithoutReplacing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	trash := filepath.Join(home, ".Trash")
	if err := os.MkdirAll(trash, 0o700); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(trash, "report.txt"), 1)

	app := filepath.Join(home, "Applications", "Demo.app", "Contents")
	if err := os.MkdirAll(app, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(home, "report.txt")
	write(t, file, 2)

	for _, p := range []string{filepath.Dir(app), file} {
		if err := Trash(p); err != nil {
			t.Fatalf("Trash(%s): %v", p, err)
		}
		if _, err := os.Lstat(p); err == nil {
			t.Errorf("%s is still there", p)
		}
	}
	entries, _ := os.ReadDir(trash)
	if len(entries) != 3 {
		t.Errorf("the Trash has %d entries, want 3: the old report.txt, Demo.app and the new report", len(entries))
	}
	if _, err := os.Stat(filepath.Join(trash, "Demo.app", "Contents")); err != nil {
		t.Error("Demo.app was not moved whole")
	}
	if err := Trash(filepath.Join(home, "missing")); err != nil {
		t.Errorf("Trash of a missing path: %v", err)
	}
}
