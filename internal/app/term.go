package app

import (
	"fmt"
	"os"
	"strings"

	"github.com/f-bahesna/medic/internal/fsx"
	"golang.org/x/term"
)

// progress shows what is being scanned on one line of stderr, only when
// stderr is a terminal.
type progress struct {
	f  *os.File
	on bool
}

func newProgress(f *os.File) *progress {
	return &progress{f: f, on: term.IsTerminal(int(f.Fd())) && enableColor(f)}
}

// Show replaces the line with "scanning what ...".
func (pr *progress) Show(what string) {
	if !pr.on {
		return
	}
	if len(what) > 70 {
		what = "..." + what[len(what)-67:]
	}
	fmt.Fprintf(pr.f, "\r\033[K\033[90m  scanning %s ...\033[0m", strings.ReplaceAll(what, "\n", " "))
}

// Done clears the line.
func (pr *progress) Done() {
	if pr.on {
		fmt.Fprint(pr.f, "\r\033[K")
	}
}

func removeTree(path string) { fsx.RemoveTree(path) }
