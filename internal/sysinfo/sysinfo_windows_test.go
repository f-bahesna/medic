package sysinfo

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// Memory per app is what Task Manager shows: the private working set, which
// is also a performance counter.
func TestAppMemoryMatchesTaskManager(t *testing.T) {
	buf := make([]byte, 64<<20)
	for i := range buf {
		buf[i] = 1
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	name := strings.TrimSuffix(filepath.Base(exe), ".exe")
	sum, count, _ := appMemory()
	if count[name] != 1 {
		t.Fatalf("found %d processes named %s", count[name], name)
	}
	out, err := exec.Command("powershell", "-NoProfile", "-Command",
		`(Get-Counter '\Process(`+name+`)\Working Set - Private').CounterSamples[0].RawValue`).Output()
	if err != nil {
		t.Fatal(err)
	}
	counter, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		t.Fatalf("Get-Counter printed %q", out)
	}
	if sum[name] < int64(len(buf)) {
		t.Errorf("private working set %d is less than the %d bytes this test holds", sum[name], len(buf))
	}
	// The same counter, read a moment apart.
	if d := sum[name] - counter; d < -8<<20 || d > 8<<20 {
		t.Errorf("medic says %d bytes, Task Manager's counter %d", sum[name], counter)
	}
	runtime.KeepAlive(buf)
}
