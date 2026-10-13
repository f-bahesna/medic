//go:build !windows

package fsx

import (
	"os"
	"testing"
)

func link(t *testing.T, target, path string) {
	t.Helper()
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}
