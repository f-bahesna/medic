package app

import (
	"fmt"
	"io"
	"os"

	"golang.org/x/term"
)

// preflight refuses to run as root: medic only needs the user's own files,
// and as root it would measure and clean root's home instead.
func preflight() error {
	if os.Geteuid() == 0 {
		return fmt.Errorf("do not run with sudo; medic only looks at your own user files")
	}
	return nil
}

// enableColor reports whether f is a terminal that shows colors.
func enableColor(f *os.File) bool { return term.IsTerminal(int(f.Fd())) }

// openTTY opens the terminal to ask questions, even when stdin is a pipe.
func openTTY() (io.Reader, bool) {
	f, err := os.Open("/dev/tty")
	if err != nil {
		return nil, false
	}
	return f, true
}
