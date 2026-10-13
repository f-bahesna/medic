package scan

import (
	"path/filepath"
	"strings"
)

func devRootCandidates(home string) []string {
	var out []string
	for _, d := range []string{"dev", "Developer", "Projects", "code", "workspace", "src", "git", "Documents/GitHub"} {
		out = append(out, filepath.Join(home, d))
	}
	return out
}

func skipForLargeFiles(home, path, name string) bool {
	return path == filepath.Join(home, "Library") || path == filepath.Join(home, ".Trash") ||
		strings.HasSuffix(name, ".photoslibrary") || name == "node_modules" || name == ".git"
}

// BreakdownDirs are the app data folders worth a breakdown.
func BreakdownDirs(home string) []string {
	return []string{filepath.Join(home, "Library", "Caches"), filepath.Join(home, "Library", "Application Support")}
}

func cacheHint(name string) string {
	return map[string]string{
		"Homebrew":           "brew cleanup --prune=all",
		"pip":                "pip cache purge",
		"CocoaPods":          "pod cache clean --all",
		"Yarn":               "yarn cache clean",
		"go-build":           "go clean -cache",
		"JetBrains":          "folders of old IDE versions can go",
		"com.apple.dt.Xcode": "Xcode cache, safe",
		"com.spotify.client": "Spotify offline cache, re-downloads",
		"ms-playwright":      "browsers for Playwright, 'npx playwright install' restores them",
		"colima":             "downloaded VM images",
	}[name]
}
