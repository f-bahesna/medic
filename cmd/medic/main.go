// Command medic shows what is filling up your computer and what is safe to
// clean. See https://github.com/f-bahesna/medic.
package main

import (
	"os"

	"github.com/f-bahesna/medic/internal/app"
)

// version is set at build time: go build -ldflags "-X main.version=0.5.0".
var version = "dev"

func main() {
	os.Exit(app.Run(version, os.Args[1:], os.Stdout, os.Stderr))
}
