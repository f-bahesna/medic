package app

import (
	"errors"
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	tests := []struct {
		args []string
		want Options
	}{
		{nil, Options{Command: "report"}},
		{[]string{"ram"}, Options{Command: "memory"}},
		{[]string{"--clean"}, Options{Command: "clean"}},
		{[]string{"--dry-run"}, Options{Command: "clean", DryRun: true}},
		{[]string{"-DryRun"}, Options{Command: "clean", DryRun: true}},
		{[]string{"clean", "--yes", "--only", "safe,NPM"}, Options{Command: "clean", Yes: true, Only: []string{"safe", "npm"}}},
		{[]string{"clean", "-Yes", "-Only", "safe", "--only=caution"}, Options{Command: "clean", Yes: true, Only: []string{"safe", "caution"}}},
		{[]string{"purge", "--older-than", "0", "--dev-dir", "a,b", "-DevDir", "c"}, Options{Command: "purge", OlderThan: 0, DevDirs: []string{"a", "b", "c"}}},
		{[]string{"check", "-MinFree", "20G", "-Json"}, Options{Command: "check", MinFree: "20G", JSON: true}},
		{[]string{"--large", "2000", "--quick"}, Options{Command: "report", LargeMB: 2000, Quick: true}},
		{[]string{"-LargeMB", "100"}, Options{Command: "report", LargeMB: 100}},
		{[]string{"-?"}, Options{Command: "report", Help: true}},
		{[]string{"apps", "--json"}, Options{Command: "apps", JSON: true}},
		{[]string{"uninstall", "Visual", "Studio", "Code", "--dry-run"}, Options{Command: "uninstall", Target: "Visual Studio Code", DryRun: true}},
		{[]string{"--dry-run", "uninstall", "disk"}, Options{Command: "uninstall", Target: "disk", DryRun: true}},
	}
	for _, tt := range tests {
		got, err := Parse(tt.args)
		if err != nil {
			t.Errorf("Parse(%q): %v", tt.args, err)
			continue
		}
		want := tt.want
		if want.MinFree == "" {
			want.MinFree = "10%"
		}
		if want.LargeMB == 0 {
			want.LargeMB = 500
		}
		if want.OlderThan == 0 && want.Command != "purge" {
			want.OlderThan = 30
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("Parse(%q) =\n %+v\nwant\n %+v", tt.args, got, want)
		}
	}
}

func TestParseUsageErrors(t *testing.T) {
	for _, args := range [][]string{
		{"bogus"},
		{"clean", "purge"},
		{"--yes"},
		{"report", "--dry-run"},
		{"clean", "--json"},
		{"purge", "--only", "safe"},
		{"check", "--min-free", "lots"},
		{"--large"},
		{"--large", "0"},
		{"--older-than", "-1"},
		{"--unknown"},
		{"--json=yes"},
		{"uninstall"},
		{"uninstall", "Slack", "--yes"},
		{"uninstall", "Slack", "--json"},
		{"apps", "--dry-run"},
	} {
		_, err := Parse(args)
		if !errors.As(err, new(UsageError)) {
			t.Errorf("Parse(%q) = %v, want a usage error", args, err)
		}
	}
}

func TestMinFreeBytes(t *testing.T) {
	tests := []struct {
		spec   string
		binary bool
		want   int64
	}{
		{"10%", false, 100},
		{"1G", false, 1_000_000_000},
		{"1G", true, 1 << 30},
		{"1.5gb", true, 3 << 29},
		{"500M", false, 500_000_000},
		{"2048", false, 2048},
	}
	for _, tt := range tests {
		if got := minFreeBytes(tt.spec, 1000, tt.binary); got != tt.want {
			t.Errorf("minFreeBytes(%q, %v) = %d, want %d", tt.spec, tt.binary, got, tt.want)
		}
	}
}
