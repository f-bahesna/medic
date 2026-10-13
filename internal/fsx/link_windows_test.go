package fsx

import (
	"os/exec"
	"testing"
)

// link makes a junction, the kind of link Windows user profiles are full of.
// Unlike symlinks it needs no special rights.
func link(t *testing.T, target, path string) {
	t.Helper()
	if out, err := exec.Command("cmd", "/c", "mklink", "/J", path, target).CombinedOutput(); err != nil {
		t.Fatalf("mklink: %v: %s", err, out)
	}
}
