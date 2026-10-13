// Package sysinfo reads the computer's name, disks and memory.
package sysinfo

import "sort"

// Host describes the computer.
type Host struct {
	Name string // computer name
	OS   string // "macOS 15.5" or "Microsoft Windows 11 Pro 10.0.26100"
}

// Disk is a volume's capacity, in bytes.
type Disk struct {
	Name   string // "/" on macOS, "C:" on Windows
	Label  string // Windows volume label
	System bool   // the volume the operating system runs from
	Total  int64
	Used   int64
	Free   int64
	// macOS only: the read-only system volume and the data volume, which share
	// the space of one APFS container.
	SystemVolume int64
	DataVolume   int64
}

// UsedPct is how full the disk is, rounded down.
func (d Disk) UsedPct() int {
	if d.Total <= 0 {
		return 0
	}
	return int(d.Used * 100 / d.Total)
}

// App is memory used by all processes of one app.
type App struct {
	Name      string
	Bytes     int64
	Processes int
}

// Memory is RAM use, in bytes. Pressure is normal, warning, critical or unknown.
type Memory struct {
	Total        int64
	Used         int64
	Cached       int64 // freed instantly when apps need it
	Free         int64 // macOS: free pages; Windows: available memory
	SwapUsed     int64 // macOS swap, Windows page file
	SwapTotal    int64
	Pressure     string
	AvailablePct int // -1 when unknown
	TopApps      []App

	// macOS only.
	App        int64
	Wired      int64
	Compressed int64 // also Windows: the Memory Compression process

	// Windows only.
	Committed   int64
	CommitLimit int64
}

// UsedPct is how much RAM is in use, rounded down.
func (m Memory) UsedPct() int {
	if m.Total <= 0 {
		return 0
	}
	return int(m.Used * 100 / m.Total)
}

// CommitPct is the share of the Windows commit limit (RAM + page file) in use.
func (m Memory) CommitPct() int { return int(m.Committed * 100 / max(m.CommitLimit, 1)) }

// topApps sums memory per app and keeps the 8 biggest.
func topApps(sum map[string]int64, count map[string]int) []App {
	apps := make([]App, 0, len(sum))
	for name, bytes := range sum {
		apps = append(apps, App{Name: name, Bytes: bytes, Processes: count[name]})
	}
	sort.Slice(apps, func(i, j int) bool {
		if apps[i].Bytes != apps[j].Bytes {
			return apps[i].Bytes > apps[j].Bytes
		}
		return apps[i].Name < apps[j].Name
	})
	if len(apps) > 8 {
		apps = apps[:8]
	}
	return apps
}

// File is a file the operating system manages, like pagefile.sys.
type File struct {
	Path  string
	Bytes int64
}
