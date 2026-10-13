// Package ui prints medic's text output: colors, sizes, sections and the
// numbered picker used by clean and purge.
package ui

import (
	"fmt"
	"io"
	"math"
	"strings"
)

// Units picks how sizes are shown: decimal like Finder, binary like Explorer
// and like macOS shows RAM.
type Units int

const (
	Decimal Units = iota
	Binary
)

// Printer writes text output, with ANSI colors when enabled.
type Printer struct {
	W io.Writer
	// Escape sequences, empty without color.
	Bold, Gray, Red, Green, Yellow, Cyan, Reset string
}

// NewPrinter returns a Printer writing to w.
func NewPrinter(w io.Writer, color bool) *Printer {
	p := &Printer{W: w}
	if color {
		p.Bold, p.Gray, p.Red, p.Green, p.Yellow, p.Cyan, p.Reset =
			"\033[1m", "\033[90m", "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[0m"
	}
	return p
}

// Printf writes formatted text as is.
func (p *Printer) Printf(format string, a ...any) { fmt.Fprintf(p.W, format, a...) }

// Section starts a titled block.
func (p *Printer) Section(title string) {
	p.Printf("\n%s%s%s%s\n%s%s%s\n", p.Bold, p.Cyan, title, p.Reset, p.Gray, strings.Repeat("-", 60), p.Reset)
}

// Note writes an indented gray line.
func (p *Printer) Note(format string, a ...any) {
	p.Printf("  %s%s%s\n", p.Gray, fmt.Sprintf(format, a...), p.Reset)
}

// Warn writes an indented yellow line starting with "!".
func (p *Printer) Warn(format string, a ...any) {
	p.Printf("  %s! %s%s\n", p.Yellow, fmt.Sprintf(format, a...), p.Reset)
}

// B wraps s in bold.
func (p *Printer) B(s string) string { return p.Bold + s + p.Reset }

// G wraps s in gray.
func (p *Printer) G(s string) string { return p.Gray + s + p.Reset }

// Badge is a safety level padded to 7 columns, in its color.
func (p *Printer) Badge(level string) string {
	color := map[string]string{"SAFE": p.Green, "CAUTION": p.Yellow, "REVIEW": p.Red}[level]
	return fmt.Sprintf("%s%-7s%s", color, level, p.Reset)
}

// Bar is a 30 column usage bar, colored by how full it is.
func (p *Printer) Bar(pct int) string {
	pct = max(0, min(pct, 100))
	filled := pct * 30 / 100
	color := p.Green
	if pct >= 90 {
		color = p.Red
	} else if pct >= 75 {
		color = p.Yellow
	}
	return color + "[" + strings.Repeat("#", filled) + strings.Repeat(".", 30-filled) + "]" + p.Reset
}

// Size formats bytes. Decimal starts at KB, like Finder and the macOS scripts
// before; binary starts at B. GB and TB get one decimal.
func Size(bytes int64, u Units) string {
	if u == Decimal {
		v := float64(bytes) / 1000
		units := []string{"KB", "MB", "GB", "TB"}
		i := 0
		for v >= 1000 && i < len(units)-1 {
			v /= 1000
			i++
		}
		return format(v, units[i], i >= 2)
	}
	v := float64(bytes)
	units := []string{"B", "KB", "MB", "GB", "TB"}
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	return format(v, units[i], i >= 3)
}

func format(v float64, unit string, decimals bool) string {
	if decimals {
		return fmt.Sprintf("%.1f %s", v, unit)
	}
	return fmt.Sprintf("%.0f %s", math.Round(v), unit)
}

// Pad pads s to width columns, ignoring the color codes in it.
func Pad(s string, width int) string {
	n := VisibleLen(s)
	if n >= width {
		return s
	}
	return s + strings.Repeat(" ", width-n)
}

// VisibleLen is the length of s without ANSI escape sequences.
func VisibleLen(s string) int {
	n, esc := 0, false
	for _, r := range s {
		switch {
		case esc:
			if r >= '@' && r <= '~' && r != '[' {
				esc = false
			}
		case r == '\033':
			esc = true
		default:
			n++
		}
	}
	return n
}

// Tilde shortens a path inside home to start with "~".
func Tilde(path, home string) string {
	home = strings.TrimRight(home, `/\`)
	if home == "" || len(path) < len(home) || !strings.EqualFold(path[:len(home)], home) {
		return path
	}
	if len(path) == len(home) {
		return "~"
	}
	if c := path[len(home)]; c == '/' || c == '\\' {
		return "~" + path[len(home):]
	}
	return path
}
