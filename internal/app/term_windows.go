package app

import (
	"io"
	"os"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

func preflight() error { return nil }

// enableColor turns on ANSI colors in the Windows console, and reports
// whether f is a console that shows them.
func enableColor(f *os.File) bool {
	h := windows.Handle(f.Fd())
	var mode uint32
	if windows.GetConsoleMode(h, &mode) != nil {
		return false
	}
	return windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == nil
}

// openTTY uses stdin when it is the console.
func openTTY() (io.Reader, bool) {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return nil, false
	}
	return os.Stdin, true
}
