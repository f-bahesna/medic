package sysinfo

import (
	"fmt"
	"os"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	kernel32                 = windows.NewLazySystemDLL("kernel32.dll")
	psapi                    = windows.NewLazySystemDLL("psapi.dll")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	procGetPerformanceInfo   = psapi.NewProc("GetPerformanceInfo")
)

// ReadHost returns the computer name and Windows edition and version.
func ReadHost() Host {
	name, _ := os.Hostname()
	if env := os.Getenv("COMPUTERNAME"); env != "" {
		name = env
	}
	v := windows.RtlGetVersion()
	product := "Windows"
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE); err == nil {
		if s, _, err := k.GetStringValue("ProductName"); err == nil {
			product = s
		}
		k.Close()
	}
	// Windows 11 still says "Windows 10" in ProductName.
	if v.BuildNumber >= 22000 {
		product = strings.Replace(product, "Windows 10", "Windows 11", 1)
	}
	return Host{Name: name, OS: fmt.Sprintf("Microsoft %s %d.%d.%d", product, v.MajorVersion, v.MinorVersion, v.BuildNumber)}
}

// ReadDisks returns the fixed drives, sorted by letter.
func ReadDisks() []Disk {
	mask, _ := windows.GetLogicalDrives()
	system := strings.ToUpper(os.Getenv("SystemDrive"))
	var disks []Disk
	for i := 0; i < 26; i++ {
		if mask&(1<<i) == 0 {
			continue
		}
		name := string(rune('A'+i)) + ":"
		root, _ := windows.UTF16PtrFromString(name + `\`)
		if windows.GetDriveType(root) != windows.DRIVE_FIXED {
			continue
		}
		var avail, total, free uint64
		if windows.GetDiskFreeSpaceEx(root, &avail, &total, &free) != nil || total == 0 {
			continue
		}
		label := make([]uint16, windows.MAX_PATH+1)
		_ = windows.GetVolumeInformation(root, &label[0], uint32(len(label)), nil, nil, nil, nil, 0)
		disks = append(disks, Disk{
			Name:   name,
			Label:  windows.UTF16ToString(label),
			System: name == system,
			Total:  int64(total),
			Free:   int64(free),
			Used:   int64(total - free),
		})
	}
	return disks
}

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

type performanceInformation struct {
	Size              uint32
	CommitTotal       uintptr
	CommitLimit       uintptr
	CommitPeak        uintptr
	PhysicalTotal     uintptr
	PhysicalAvailable uintptr
	SystemCache       uintptr
	KernelTotal       uintptr
	KernelPaged       uintptr
	KernelNonpaged    uintptr
	PageSize          uintptr
	HandleCount       uint32
	ProcessCount      uint32
	ThreadCount       uint32
}

type pageFileInformation struct {
	NextEntryOffset uint32
	TotalSize       uint32
	TotalInUse      uint32
	PeakUsage       uint32
	PageFileName    windows.NTUnicodeString
}

// ReadMemory reads RAM use the way Task Manager shows it.
func ReadMemory() Memory {
	ms := memoryStatusEx{Length: uint32(unsafe.Sizeof(memoryStatusEx{}))}
	_, _, _ = procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&ms)))
	pi := performanceInformation{Size: uint32(unsafe.Sizeof(performanceInformation{}))}
	_, _, _ = procGetPerformanceInfo.Call(uintptr(unsafe.Pointer(&pi)), uintptr(pi.Size))
	page := int64(pi.PageSize)
	if page == 0 {
		page = 4096
	}

	m := Memory{
		Total:       int64(ms.TotalPhys),
		Free:        int64(ms.AvailPhys),
		Used:        int64(ms.TotalPhys - ms.AvailPhys),
		Cached:      int64(pi.SystemCache) * page,
		Committed:   int64(pi.CommitTotal) * page,
		CommitLimit: int64(pi.CommitLimit) * page,
	}
	m.SwapUsed, m.SwapTotal = readPageFile(page)
	m.AvailablePct = int(m.Free * 100 / max(m.Total, 1))
	commitPct := int(m.Committed * 100 / max(m.CommitLimit, 1))
	switch {
	case m.AvailablePct < 10 || commitPct >= 90:
		m.Pressure = "critical"
	case m.AvailablePct < 20 || commitPct >= 80:
		m.Pressure = "warning"
	default:
		m.Pressure = "normal"
	}
	m.TopApps, m.Compressed = readApps()
	return m
}

func readPageFile(page int64) (used, total int64) {
	buf := make([]byte, 4096)
	var n uint32
	if windows.NtQuerySystemInformation(windows.SystemPageFileInformation, unsafe.Pointer(&buf[0]), uint32(len(buf)), &n) != nil {
		return 0, 0
	}
	for off := uint32(0); off < n; {
		e := (*pageFileInformation)(unsafe.Pointer(&buf[off]))
		used += int64(e.TotalInUse) * page
		total += int64(e.TotalSize) * page
		if e.NextEntryOffset == 0 {
			break
		}
		off += e.NextEntryOffset
	}
	return used, total
}

// readApps groups processes by name with their working sets, like Get-Process.
// It also returns the working set of "Memory Compression".
func readApps() ([]App, int64) {
	size := uint32(1 << 20)
	var buf []byte
	for {
		buf = make([]byte, size)
		var n uint32
		err := windows.NtQuerySystemInformation(windows.SystemProcessInformation, unsafe.Pointer(&buf[0]), size, &n)
		if err == nil {
			break
		}
		if err != windows.STATUS_INFO_LENGTH_MISMATCH || size > 64<<20 {
			return nil, 0
		}
		size = max(size*2, n+64<<10)
	}
	sum, count := map[string]int64{}, map[string]int{}
	var compressed int64
	for off := uintptr(0); ; {
		p := (*windows.SYSTEM_PROCESS_INFORMATION)(unsafe.Pointer(&buf[off]))
		if p.UniqueProcessID != 0 {
			name := strings.TrimSuffix(p.ImageName.String(), ".exe")
			if name == "Memory Compression" {
				compressed = int64(p.WorkingSetSize)
			}
			sum[name] += int64(p.WorkingSetSize)
			count[name]++
		}
		if p.NextEntryOffset == 0 {
			break
		}
		off += uintptr(p.NextEntryOffset)
	}
	return topApps(sum, count), compressed
}

// IsAdmin reports whether medic runs elevated ("Run as administrator").
func IsAdmin() bool { return windows.GetCurrentProcessToken().IsElevated() }

// SystemDrive is where cleaning frees space, like "C:".
func SystemDrive() string {
	if d := os.Getenv("SystemDrive"); d != "" {
		return strings.ToUpper(d)
	}
	return "C:"
}

// FreeBytes is the free space on the system drive.
func FreeBytes() int64 {
	for _, d := range ReadDisks() {
		if d.System {
			return d.Free
		}
	}
	return 0
}

// TimeMachineSnapshots is a macOS concept.
func TimeMachineSnapshots() int { return 0 }

// SystemFiles are the page, hibernation and swap files that exist on the
// system drive. The directory listing has their size even though they are
// locked.
func SystemFiles() []File {
	root := SystemDrive() + `\`
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var files []File
	for _, e := range entries {
		switch strings.ToLower(e.Name()) {
		case "pagefile.sys", "hiberfil.sys", "swapfile.sys":
			if info, err := e.Info(); err == nil {
				files = append(files, File{Path: root + e.Name(), Bytes: info.Size()})
			}
		}
	}
	return files
}
