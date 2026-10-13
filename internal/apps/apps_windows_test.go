package apps

import (
	"os"
	"path/filepath"
	"testing"
)

// A carelessly written uninstall entry must never offer a drive, a system
// folder or a profile folder for the Recycle Bin.
func TestSafeInstallDir(t *testing.T) {
	unsafe := []string{
		`C:\`, os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), os.Getenv("windir"),
		os.Getenv("USERPROFILE"), os.Getenv("LOCALAPPDATA"), os.Getenv("APPDATA"), os.Getenv("ProgramData"),
		filepath.Dir(os.Getenv("USERPROFILE")), // C:\Users
		filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs"),
	}
	for _, p := range unsafe {
		if p != "" && safeInstallDir(p) {
			t.Errorf("safeInstallDir(%q) = true, want false", p)
		}
	}
	safe := []string{
		filepath.Join(os.Getenv("ProgramFiles"), "Slack"),
		filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "Microsoft VS Code"),
		`D:\Games\Some Game`,
	}
	for _, p := range safe {
		if !safeInstallDir(p) {
			t.Errorf("safeInstallDir(%q) = false, want true", p)
		}
	}
}

func TestUninstallCommand(t *testing.T) {
	tests := map[string]string{
		`MsiExec.exe /I{23170F69-40C1-2702-2408-000001000000}`: `MsiExec.exe /X{23170F69-40C1-2702-2408-000001000000}`,
		`MsiExec.exe /X{23170F69-40C1-2702-2408-000001000000}`: `MsiExec.exe /X{23170F69-40C1-2702-2408-000001000000}`,
		`"C:\Program Files\App\uninstall.exe"`:                 `"C:\Program Files\App\uninstall.exe"`,
	}
	for in, want := range tests {
		if got := UninstallCommand(App{Uninstaller: in}); got != want {
			t.Errorf("UninstallCommand(%q) = %q, want %q", in, got, want)
		}
	}
}
