package scan

import (
	"os"
	"path/filepath"
	"strings"
)

func devRootCandidates(home string) []string {
	var out []string
	for _, d := range []string{"dev", `source\repos`, "Projects", "code", "workspace", "src", "git", `Documents\GitHub`} {
		out = append(out, filepath.Join(home, d))
	}
	return out
}

func skipForLargeFiles(home, path, name string) bool {
	return strings.EqualFold(path, filepath.Join(home, "AppData")) || name == "node_modules" || name == ".git"
}

// BreakdownDirs are the app data folders worth a breakdown.
func BreakdownDirs(string) []string { return []string{os.Getenv("LOCALAPPDATA"), os.Getenv("APPDATA")} }

func cacheHint(name string) string {
	return map[string]string{
		"npm-cache":     "npm cache clean --force",
		"pip":           "pip cache purge",
		"Temp":          "temporary files",
		"NVIDIA":        "shader caches are safe",
		"ms-playwright": "browsers for Playwright, 'npx playwright install' restores them",
		"JetBrains":     "folders of old IDE versions can go",
		"Docker":        "Docker Desktop data, see above",
		"Packages":      "Microsoft Store apps and WSL distros",
	}[name]
}
