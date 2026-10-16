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
	"unsafe"

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

var (
	appBundle = regexp.MustCompile(`([^/]+)\.app/`)
	psLine    = regexp.MustCompile(`^\s*(\d+)\s+(\d+)\s+(.+)$`)
	topLine   = regexp.MustCompile(`^\s*(\d+)\s+(\d+(?:\.\d+)?)([BKMGT])[+-]?\s*$`)
)

// readApps groups processes by app: everything inside "Foo.app/" counts as Foo,
// so helper processes add up under their app. Memory is the physical
// footprint, Activity Monitor's "Memory" column. The resident size ps prints
// leaves out what is compressed or swapped, often most of a big app.
func readApps() []App {
	out, _ := exec.Command("ps", "-axo", "pid=,rss=,comm=").Output()
	var others map[int]int64
	sum, count := map[string]int64{}, map[string]int{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := psLine.FindStringSubmatch(sc.Text())
		if f == nil {
			continue
		}
		pid, _ := strconv.Atoi(f[1])
		size, ok := footprint(pid)
		if !ok {
			// Processes of root and other users: only top, which runs as
			// root, can read their footprint.
			if others == nil {
				others = parseTopMemory(output("top", "-l", "1", "-stats", "pid,mem"))
			}
			if size, ok = others[pid]; !ok {
				kb, _ := strconv.ParseInt(f[2], 10, 64)
				size = kb * 1024
			}
		}
		path := strings.TrimSpace(f[3])
		name := path[strings.LastIndex(path, "/")+1:]
		if m := appBundle.FindStringSubmatch(path); m != nil {
			name = m[1]
		}
		sum[name] += size
		count[name]++
	}
	return topApps(sum, count)
}

// footprint is a process's physical footprint to the byte, as
// proc_pid_rusage(3) reads it. The kernel answers only for this user's
// processes.
func footprint(pid int) (int64, bool) {
	const callPIDRusage, rusageInfoV0 = 9, 0
	var info [96]byte // struct rusage_info_v0
	_, _, errno := unix.Syscall6(unix.SYS_PROC_INFO, callPIDRusage, uintptr(pid), rusageInfoV0, 0, uintptr(unsafe.Pointer(&info[0])), 0)
	if errno != 0 {
		return 0, false
	}
	// After the 16-byte uuid come uint64 fields; ri_phys_footprint is the 8th.
	return int64(binary.LittleEndian.Uint64(info[72:80])), true
}

// parseTopMemory reads the footprint of every process from
// "top -l 1 -stats pid,mem", which prints sizes like 18M, 512K or 1115M+.
func parseTopMemory(out string) map[int]int64 {
	unit := map[string]float64{"B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
	mem := map[int]int64{}
	for _, line := range strings.Split(out, "\n") {
		if m := topLine.FindStringSubmatch(line); m != nil {
			pid, _ := strconv.Atoi(m[1])
			n, _ := strconv.ParseFloat(m[2], 64)
			mem[pid] = int64(n * unit[m[3]])
		}
	}
	return mem
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
