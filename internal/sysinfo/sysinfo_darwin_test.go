package sysinfo

import (
	"os"
	"runtime"
	"testing"
)

func TestParseTopMemory(t *testing.T) {
	out := `Processes: 511 total, 3 running, 508 sleeping, 3001 threads
PhysMem: 7557M used (1707M wired, 2384M compressor), 74M unused.

PID    MEM
0      1897M
420    1115M+
98104  512K-
7      12G
8      1.5G
`
	want := map[int]int64{0: 1897 << 20, 420: 1115 << 20, 98104: 512 << 10, 7: 12 << 30, 8: 3 << 29}
	got := parseTopMemory(out)
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for pid, bytes := range want {
		if got[pid] != bytes {
			t.Errorf("pid %d: got %d, want %d", pid, got[pid], bytes)
		}
	}
}

// The footprint read by the system call and the one top prints are the same
// counter, read a moment apart.
func TestFootprintMatchesTop(t *testing.T) {
	buf := make([]byte, 64<<20)
	for i := range buf {
		buf[i] = 1
	}
	own, ok := footprint(os.Getpid())
	if !ok || own < int64(len(buf)) {
		t.Fatalf("footprint of this test = %d, %v; it holds %d bytes", own, ok, len(buf))
	}
	top := parseTopMemory(output("top", "-l", "1", "-stats", "pid,mem"))
	if d := top[os.Getpid()] - own; d < -8<<20 || d > 8<<20 {
		t.Errorf("top says %d bytes, the system call %d", top[os.Getpid()], own)
	}
	// launchd runs as root: the system call cannot read it, top can.
	if top[1] <= 0 {
		t.Errorf("top did not print launchd's footprint")
	}
	runtime.KeepAlive(buf)
}
