package scan

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func mk(t *testing.T, path string, old bool) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if old {
		then := time.Now().AddDate(-1, 0, 0)
		if err := os.Chtimes(path, then, then); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPurgeFolders(t *testing.T) {
	root := t.TempDir()
	mk(t, filepath.Join(root, "old-web", "package.json"), true)
	mk(t, filepath.Join(root, "old-web", "node_modules", "pkg", "index.js"), false)
	mk(t, filepath.Join(root, "old-web", "node_modules", "dep", "node_modules", "x.js"), false)
	mk(t, filepath.Join(root, "new-web", "package.json"), false)
	mk(t, filepath.Join(root, "new-web", "node_modules", "pkg", "index.js"), false)
	mk(t, filepath.Join(root, "old-rust", "Cargo.toml"), true)
	mk(t, filepath.Join(root, "old-rust", "target", "debug", "app"), false)
	mk(t, filepath.Join(root, "old-py", "main.py"), true)
	mk(t, filepath.Join(root, "old-py", ".venv", "pyvenv.cfg"), false)
	mk(t, filepath.Join(root, "no-marker", "node_modules", "pkg", "index.js"), false)
	mk(t, filepath.Join(root, "plain", "build", "notes.txt"), true)

	kinds := map[string]string{}
	for _, e := range PurgeFolders([]string{root}, 30, nil) {
		rel, _ := filepath.Rel(root, e.Path)
		kinds[filepath.ToSlash(rel)] = e.Kind
	}
	want := map[string]string{"old-web/node_modules": "node_modules", "old-rust/target": "Rust build", "old-py/.venv": "Python venv"}
	if len(kinds) != len(want) {
		t.Fatalf("PurgeFolders found %v, want %v", kinds, want)
	}
	for k, v := range want {
		if kinds[k] != v {
			t.Errorf("PurgeFolders found %v, want %v", kinds, want)
		}
	}

	if n := len(PurgeFolders([]string{root}, 0, nil)); n != 4 {
		t.Errorf("with days 0, PurgeFolders found %d folders, want 4 (active projects too)", n)
	}
}

func TestCanPurge(t *testing.T) {
	root := t.TempDir()
	mk(t, filepath.Join(root, "app", "package.json"), false)
	mk(t, filepath.Join(root, "app", "node_modules", "x.js"), false)
	other := t.TempDir()
	mk(t, filepath.Join(other, "app", "package.json"), false)
	mk(t, filepath.Join(other, "app", "node_modules", "x.js"), false)

	if !CanPurge(filepath.Join(root, "app", "node_modules"), []string{root}) {
		t.Error("node_modules next to package.json in the root should be purgeable")
	}
	if CanPurge(filepath.Join(other, "app", "node_modules"), []string{root}) {
		t.Error("a folder outside the roots must not be purgeable")
	}
	if CanPurge(filepath.Join(root, "app"), []string{root}) {
		t.Error("a project folder must not be purgeable")
	}
	_ = os.Remove(filepath.Join(root, "app", "package.json"))
	if CanPurge(filepath.Join(root, "app", "node_modules"), []string{root}) {
		t.Error("node_modules without package.json must not be purgeable")
	}
}
