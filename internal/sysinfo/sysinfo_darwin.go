package sysinfo

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func output(name string, args ...string) string {
	out, _ := exec.Command(name, args...).Output()
	return strings.TrimSpace(string(out))
}

// ReadHost returns the computer name and macOS version.
func ReadHost() Host {
	name := output("scutil", "--get", "ComputerName")
	if name == "" {
		name, _ = os.Hostname()
	}
	return Host{Name: name, OS: "macOS " + output("sw_vers", "-productVersion")}
}

// ReadDisks returns the startup disk. Its APFS volumes share one container,
// so "used" is everything that is not free: system, data, swap, snapshots.
// The per-volume use comes from df, which asks APFS for it; statfs only knows
// the container.
func ReadDisks() []Disk {
	var root unix.Statfs_t
	if unix.Statfs("/", &root) != nil {
		return nil
	}
	bsize := int64(root.Bsize)
	d := Disk{Name: "/", System: true, Total: int64(root.Blocks) * bsize, Free: int64(root.Bavail) * bsize}
	d.Used = d.Total - d.Free
	out, _ := exec.Command("df", "-k", "/", "/System/Volumes/Data").Output()
	for i, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Fields(line)
		if i == 0 || len(f) < 4 {
			continue
		}
		used, _ := strconv.ParseInt(f[2], 10, 64)
		switch f[len(f)-1] {
		case "/":
			d.SystemVolume = used * 1024
		case "/System/Volumes/Data":
			d.DataVolume = used * 1024
		}
	}
	return []Disk{d}
}

var vmStatLine = regexp.MustCompile(`^(.+):\s+(\d+)\.?$`)

// ReadMemory reads RAM use the way Activity Monitor shows it.
func ReadMemory() Memory {
	pages := map[string]int64{}
	vm := output("vm_stat")
	pageSize := int64(16384)
	if m := regexp.MustCompile(`page size of (\d+) bytes`).FindStringSubmatch(vm); m != nil {
		pageSize, _ = strconv.ParseInt(m[1], 10, 64)
	}
	for _, line := range strings.Split(vm, "\n") {
		if m := vmStatLine.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			n, _ := strconv.ParseInt(m[2], 10, 64)
			pages[m[1]] = n * pageSize
		}
	}

	m := Memory{AvailablePct: -1}
	total, _ := unix.SysctlUint64("hw.memsize")
	m.Total = int64(total)
	m.Wired = pages["Pages wired down"]
	m.Compressed = pages["Pages occupied by compressor"]
	purgeable := pages["Pages purgeable"]
	m.App = max(pages["Anonymous pages"]-purgeable, 0)
	m.Used = m.App + m.Wired + m.Compressed
	m.Cached = pages["File-backed pages"] + purgeable
	m.Free = pages["Pages free"]

	m.Pressure = "unknown"
	if level, err := unix.SysctlUint32("kern.memorystatus_vm_pressure_level"); err == nil {
		m.Pressure = map[uint32]string{1: "normal", 2: "warning", 4: "critical"}[level]
		if m.Pressure == "" {
			m.Pressure = "unknown"
		}
	}
	if pm := regexp.MustCompile(`free percentage: (\d+)%`).FindStringSubmatch(output("memory_pressure", "-Q")); pm != nil {
		m.AvailablePct, _ = strconv.Atoi(pm[1])
	}
	// struct xsw_usage: total, avail, used (uint64), pagesize, encrypted.
	if raw, err := unix.SysctlRaw("vm.swapusage"); err == nil && len(raw) >= 24 {
		m.SwapTotal = int64(binary.LittleEndian.Uint64(raw[0:8]))
		m.SwapUsed = int64(binary.LittleEndian.Uint64(raw[16:24]))
	}
	m.TopApps = readApps()
	return m
}

var appBundle = regexp.MustCompile(`([^/]+)\.app/`)

// readApps groups processes by app: everything inside "Foo.app/" counts as Foo,
// so helper processes add up under their app.
func readApps() []App {
	out, _ := exec.Command("ps", "-axo", "rss=,comm=").Output()
	sum, count := map[string]int64{}, map[string]int{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		fields := strings.SplitN(strings.TrimSpace(sc.Text()), " ", 2)
		if len(fields) != 2 {
			continue
		}
		kb, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			continue
		}
		path := strings.TrimSpace(fields[1])
		name := path[strings.LastIndex(path, "/")+1:]
		if m := appBundle.FindStringSubmatch(path); m != nil {
			name = m[1]
		}
		sum[name] += kb * 1024
		count[name]++
	}
	return topApps(sum, count)
}

// IsAdmin is always false on macOS: medic refuses to run as root.
func IsAdmin() bool { return false }

// SystemDrive is where cleaning frees space.
func SystemDrive() string { return "/" }

// FreeBytes is the free space on the startup disk.
func FreeBytes() int64 {
	if disks := ReadDisks(); len(disks) > 0 {
		return disks[0].Free
	}
	return 0
}

// TimeMachineSnapshots counts local Time Machine snapshots.
func TimeMachineSnapshots() int {
	return strings.Count(output("tmutil", "listlocalsnapshots", "/"), "com.apple")
}

// SystemFiles is a Windows concept: macOS keeps swap inside its own volumes.
func SystemFiles() []File { return nil }
