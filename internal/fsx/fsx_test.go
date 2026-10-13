package fsx

import (
	"os"
	"path/filepath"
	"testing"
)

// tree makes dir/cache with files and a link to dir/outside, which must never
// be counted or deleted.
func tree(t *testing.T) (cache, outside string) {
	t.Helper()
	dir := t.TempDir()
	cache, outside = filepath.Join(dir, "cache"), filepath.Join(dir, "outside")
	for _, d := range []string{filepath.Join(cache, "sub"), outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write(t, filepath.Join(cache, "a"), 100_000)
	write(t, filepath.Join(cache, "sub", "b"), 200_000)
	write(t, filepath.Join(outside, "keep"), 5_000_000)
	link(t, outside, filepath.Join(cache, "link"))
	link(t, outside, filepath.Join(cache, "sub", "deeplink"))
	return cache, outside
}

func write(t *testing.T, path string, n int) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestSizeDoesNotFollowLinks(t *testing.T) {
	cache, _ := tree(t)
	got := Size(cache)
	if got < 300_000 || got > 1_000_000 {
		t.Errorf("Size = %d, want about 300 KB: the 5 MB behind the links must not count", got)
	}
	if Size(filepath.Join(cache, "missing")) != 0 {
		t.Error("Size of a missing path should be 0")
	}
}

func TestEmptyDirKeepsLinkTargets(t *testing.T) {
	cache, outside := tree(t)
	EmptyDir(cache)
	if HasContent(cache) {
		t.Error("cache was not emptied")
	}
	if _, err := os.Stat(cache); err != nil {
		t.Error("the folder itself was deleted")
	}
	if _, err := os.Stat(filepath.Join(outside, "keep")); err != nil {
		t.Error("a link target was deleted")
	}
}

func TestRemoveTreeKeepsLinkTargets(t *testing.T) {
	cache, outside := tree(t)
	RemoveTree(cache)
	if _, err := os.Lstat(cache); err == nil {
		t.Error("cache still exists")
	}
	if _, err := os.Stat(filepath.Join(outside, "keep")); err != nil {
		t.Error("a link target was deleted")
	}
}

func TestUnder(t *testing.T) {
	sep := string(os.PathSeparator)
	root := sep + "home" + sep + "dev"
	tests := []struct {
		path string
		want bool
	}{
		{root + sep + "app" + sep + "node_modules", true},
		{root, false},
		{root + "x" + sep + "a", false},
		{sep + "home" + sep + "DEV" + sep + "a", true},
	}
	for _, tt := range tests {
		if got := Under(tt.path, root); got != tt.want {
			t.Errorf("Under(%q, %q) = %v, want %v", tt.path, root, got, tt.want)
		}
	}
}
