package ui

import (
	"reflect"
	"testing"
)

func TestParseSelection(t *testing.T) {
	levels := []string{"SAFE", "CAUTION", "SAFE", "CAUTION"}
	tests := []struct {
		answer string
		want   []int
		ok     bool
	}{
		{"1,3", []int{0, 2}, true},
		{"2-4, 1", []int{0, 1, 2, 3}, true},
		{"3 1 3", []int{0, 2}, true},
		{"all", []int{0, 1, 2, 3}, true},
		{"SAFE", []int{0, 2}, true},
		{"caution,1", []int{0, 1, 3}, true},
		{"5", nil, false},
		{"0", nil, false},
		{"3-2", nil, false},
		{"2-9", nil, false},
		{"x", nil, false},
		{"", nil, false},
		{",", nil, false},
	}
	for _, tt := range tests {
		got, ok := ParseSelection(tt.answer, 4, levels)
		if ok != tt.ok || !reflect.DeepEqual(got, tt.want) {
			t.Errorf("ParseSelection(%q) = %v, %v; want %v, %v", tt.answer, got, ok, tt.want, tt.ok)
		}
	}
	if _, ok := ParseSelection("safe", 4, nil); ok {
		t.Error(`"safe" without levels should not be valid`)
	}
}

func TestSize(t *testing.T) {
	tests := []struct {
		bytes int64
		units Units
		want  string
	}{
		{0, Decimal, "0 KB"},
		{999_000, Decimal, "999 KB"},
		{1_500_000, Decimal, "2 MB"},
		{245_100_000_000, Decimal, "245.1 GB"},
		{1_200_000_000_000, Decimal, "1.2 TB"},
		{512, Binary, "512 B"},
		{1023 << 20, Binary, "1023 MB"},
		{16 << 30, Binary, "16.0 GB"},
	}
	for _, tt := range tests {
		if got := Size(tt.bytes, tt.units); got != tt.want {
			t.Errorf("Size(%d, %d) = %q, want %q", tt.bytes, tt.units, got, tt.want)
		}
	}
}

func TestTilde(t *testing.T) {
	tests := []struct{ path, home, want string }{
		{"/Users/alex/Library/Caches", "/Users/alex", "~/Library/Caches"},
		{"/Users/alex", "/Users/alex/", "~"},
		{"/Users/alexander/x", "/Users/alex", "/Users/alexander/x"},
		{`C:\Users\alex\AppData`, `C:\Users\Alex`, `~\AppData`},
		{"/tmp/x", "/Users/alex", "/tmp/x"},
	}
	for _, tt := range tests {
		if got := Tilde(tt.path, tt.home); got != tt.want {
			t.Errorf("Tilde(%q, %q) = %q, want %q", tt.path, tt.home, got, tt.want)
		}
	}
}

func TestBarAndBadgeWithoutColor(t *testing.T) {
	p := NewPrinter(nil, false)
	if got := p.Bar(50); got != "[###############...............]" {
		t.Errorf("Bar(50) = %q", got)
	}
	if got := p.Bar(150); got != "[##############################]" {
		t.Errorf("Bar(150) = %q", got)
	}
	if got := p.Badge("SAFE"); got != "SAFE   " {
		t.Errorf("Badge(SAFE) = %q", got)
	}
	if got := VisibleLen("\033[1mbold\033[0m"); got != 4 {
		t.Errorf("VisibleLen = %d", got)
	}
}
