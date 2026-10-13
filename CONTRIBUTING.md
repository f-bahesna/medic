# Contributing

medic is a Go program with no dependencies outside the Go project's own `golang.org/x/sys` and `golang.org/x/term`.

## Layout

| Path | What |
| --- | --- |
| `cmd/medic` | The program's entry point |
| `internal/app` | Commands, options, text and JSON output |
| `internal/items` | The known locations: `mac.go` and `windows.go` hold the lists, `collect_*.go` the system calls and cleanup |
| `internal/scan` | Breakdowns, dev folders, large files and purge |
| `internal/sysinfo` | Disks, memory and the computer's name, per system |
| `internal/fsx` | Measuring and deleting without following links |
| `internal/ui` | Colors, sizes and the numbered picker |
| `install.sh`, `install.ps1` | Installers |
| `tools/dist.sh` | Builds the release archives and `SHA256SUMS` |
| `tools/screenshot`, `docs/make-screenshots.py` | Draw the README screenshots from the real rendering, with sample data |
| `tests/` | End-to-end tests run by CI |

To use your checkout as the `medic` command: `go build -o ~/.local/bin/medic ./cmd/medic`.

## Adding a location

1. Add it to `MacItems` (`internal/items/mac.go`) or `WindowsItems` (`internal/items/windows.go`).
2. If it is cleaned by emptying a folder, add the exact path to `macCleanableDirs` or `winCleanableDirs`.
   If the tool has its own cleanup command, add it to `macToolCommand` or `winToolCommand`, and a case to `Clean` in `collect_darwin.go` or `collect_windows.go`.
3. Keep the printed delete commands in sync: `DescribeMac` and `DescribeWindows` mirror `Clean`.

## Adding a purge folder kind

Add the folder name to `PurgeNames` and the file that proves what it is to `PurgeKind`, both in `internal/scan/purge.go`.

## Before a pull request

- `gofmt -l .` prints nothing, and `go vet ./...` passes with and without `GOOS=windows`.
- `go test ./...`, then the end-to-end tests in `tests/` for your system.
- `shellcheck install.sh tools/dist.sh tests/*.sh`, and `Invoke-ScriptAnalyzer` on the `.ps1` files with `-Settings PSScriptAnalyzerSettings.psd1`.
  Keep the `.ps1` files ASCII only, Windows PowerShell 5.1 misreads other characters.
- If the report changed: `python3 docs/make-screenshots.py`.

Commands, options, exit codes and the JSON shape are the same on both systems.
JSON fields are only ever added, never renamed or removed.
CI runs all of this on macOS and Windows.

## Releasing

Merge, then push a tag: `git tag v0.5.0 && git push origin v0.5.0`.
The tag is the version medic reports.
The release workflow builds the archives with `tools/dist.sh` and publishes them with the installers and `SHA256SUMS`.
