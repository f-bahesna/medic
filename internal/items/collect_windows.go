package items

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/f-bahesna/medic/internal/fsx"
	"github.com/f-bahesna/medic/internal/ui"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func readEnv() Env {
	return Env{os.Getenv("LOCALAPPDATA"), os.Getenv("APPDATA"), os.Getenv("USERPROFILE"), os.Getenv("windir"),
		os.Getenv("ProgramData"), os.Getenv("SystemDrive")}
}

// expand turns wildcard patterns (browser profiles, WSL distros) into the
// paths that exist; plain paths stay as they are.
func expand(patterns []string) []string {
	var out []string
	for _, p := range patterns {
		if !strings.Contains(p, "*") {
			out = append(out, p)
			continue
		}
		matches, _ := filepath.Glob(p)
		out = append(out, matches...)
	}
	return out
}

// Collect lists the known locations for this PC, with the installers in
// Downloads and on the Desktop found and measured. Measure does the rest.
func Collect(home string) []*Item {
	e := readEnv()
	downloads := knownFolder(windows.FOLDERID_Downloads, e.U+`\Downloads`)
	desktop := knownFolder(windows.FOLDERID_Desktop, e.U+`\Desktop`)
	sid := userSID()
	var recycle []string
	for _, d := range fixedDrives() {
		recycle = append(recycle, d+`\$Recycle.Bin\`+sid)
	}
	list := WindowsItems(e, downloads, recycle, has, expand)
	if files := findInstallers(downloads, desktop); len(files) > 0 {
		var total int64
		for _, f := range files {
			total += fsx.Size(f)
		}
		list = append(list, WindowsInstallers(files, total))
	}
	return list
}

// Describe fills in the commands that clean each item by hand.
func Describe(list []*Item, _ string) {
	DescribeWindows(list, readEnv(), fsx.HasContent, isFile, expand)
}

func userSID() string {
	u, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return ""
	}
	return u.User.Sid.String()
}

func knownFolder(id *windows.KNOWNFOLDERID, fallback string) string {
	if p, err := windows.KnownFolderPath(id, 0); err == nil && p != "" {
		return p
	}
	return fallback
}

func fixedDrives() []string {
	mask, _ := windows.GetLogicalDrives()
	var drives []string
	for i := 0; i < 26; i++ {
		if mask&(1<<i) == 0 {
			continue
		}
		root, _ := windows.UTF16PtrFromString(string(rune('A'+i)) + `:\`)
		if windows.GetDriveType(root) == windows.DRIVE_FIXED {
			drives = append(drives, string(rune('A'+i))+":")
		}
	}
	return drives
}

var setupName = regexp.MustCompile(`(?i)setup|install`)

func findInstallers(roots ...string) []string {
	var files []string
	for _, root := range roots {
		walkDepth(root, 3, func(path string, e os.DirEntry) {
			if !e.Type().IsRegular() {
				return
			}
			switch ext := strings.ToLower(filepath.Ext(e.Name())); {
			case ext == ".msi" || ext == ".msix" || ext == ".msixbundle" || ext == ".iso":
				files = append(files, path)
			case ext == ".exe" && setupName.MatchString(e.Name()):
				files = append(files, path)
			}
		})
	}
	return files
}

// Clean cleans one item. With dry set it only says what it would do. It
// returns false when the item could not be cleaned.
func Clean(it *Item, home string, dry bool, p *ui.Printer) bool {
	e := readEnv()
	dirs, files := winCleanableDirs(e, expand)
	switch it.ID {
	case "recycle_bin":
		if dry {
			p.Note("would empty the Recycle Bin")
			return true
		}
		return emptyRecycleBin()
	case "docker":
		if exec.Command("docker", "info").Run() != nil {
			p.Warn("Docker is not running. Start Docker Desktop and try again.")
			return false
		}
		return run(p, dry, winToolCommand(it.ID)...)
	case "npm", "pnpm", "go_mod", "nuget":
		return run(p, dry, winToolCommand(it.ID)...)
	case "delivery_opt":
		if dry {
			p.Note("would run: Delete-DeliveryOptimizationCache -Force")
			return true
		}
		return run(p, false, "powershell.exe", "-NoProfile", "-Command", "Delete-DeliveryOptimizationCache -Force")
	case "windows_update":
		if dry {
			p.Note("would pause Windows Update, empty its download folder and start it again")
			return true
		}
		m, err := mgr.Connect()
		if err != nil {
			p.Warn("cannot pause Windows Update: %v", err)
			return false
		}
		defer m.Disconnect()
		stopped := stopServices(m, "wuauserv", "bits")
		ok := emptyAllowed(e.W+`\SoftwareDistribution\Download`, dirs, home, false, p)
		startServices(stopped)
		return ok
	case "installers":
		for _, f := range it.Files {
			if !isFile(f) {
				continue
			}
			if dry {
				p.Note("would move to Recycle Bin: %s", ui.Tilde(f, home))
				continue
			}
			if err := fsx.Trash(f); err != nil {
				p.Warn("could not move %s to the Recycle Bin: %v", ui.Tilde(f, home), err)
			}
		}
		return true
	}
	ok := true
	for _, path := range it.Paths {
		if strings.EqualFold(filepath.Ext(path), ".dmp") {
			ok = removeAllowedFile(path, files, dry, p) && ok
			continue
		}
		ok = emptyAllowed(path, dirs, home, dry, p) && ok
	}
	return ok
}

// emptyAllowed deletes the contents of dir, only if it is on the allowlist
// and not a link.
func emptyAllowed(dir string, allowed []string, home string, dry bool, p *ui.Printer) bool {
	if !contains(allowed, cleanWin(dir)) {
		p.Warn("refusing to touch %s (not on the allowlist)", dir)
		return false
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return true
	}
	if fsx.IsLink(dir, info) || !info.IsDir() {
		p.Warn("refusing to touch %s (it is a link)", dir)
		return false
	}
	if dry {
		p.Note("would delete the contents of %s", ui.Tilde(dir, home))
		return true
	}
	fsx.EmptyDir(dir)
	return true
}

func removeAllowedFile(path string, allowed []string, dry bool, p *ui.Printer) bool {
	if !contains(allowed, cleanWin(path)) {
		p.Warn("refusing to touch %s (not on the allowlist)", path)
		return false
	}
	if !isFile(path) {
		return true
	}
	if dry {
		p.Note("would delete %s", path)
		return true
	}
	fsx.RemoveTree(path)
	return true
}

var (
	shell32               = windows.NewLazySystemDLL("shell32.dll")
	procSHEmptyRecycleBin = shell32.NewProc("SHEmptyRecycleBinW")
)

func emptyRecycleBin() bool {
	// 7 = no confirmation, no progress UI, no sound. An already empty bin
	// returns an error code too, so the result is not checked.
	_, _, _ = procSHEmptyRecycleBin.Call(0, 0, 7)
	return true
}

// stopServices stops the running ones and returns them, to start again later.
func stopServices(m *mgr.Mgr, names ...string) []*mgr.Service {
	var stopped []*mgr.Service
	for _, name := range names {
		s, err := m.OpenService(name)
		if err != nil {
			continue
		}
		if st, err := s.Query(); err != nil || st.State != svc.Running {
			s.Close()
			continue
		}
		if _, err := s.Control(svc.Stop); err != nil {
			s.Close()
			continue
		}
		for i := 0; i < 50; i++ {
			if st, err := s.Query(); err == nil && st.State == svc.Stopped {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		stopped = append(stopped, s)
	}
	return stopped
}

func startServices(services []*mgr.Service) {
	for _, s := range services {
		_ = s.Start()
		s.Close()
	}
}
