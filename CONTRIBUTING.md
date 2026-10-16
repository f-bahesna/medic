# Contributing

medic is a Go program with no dependencies outside the Go project's own `golang.org/x/sys` and `golang.org/x/term`.
Medic.app, the Mac menu bar app, is a Swift package in `macos/` with no dependencies, which ships the same `medic` program inside it.

## Layout

| Path | What |
| --- | --- |
| `cmd/medic` | The program's entry point |
| `internal/app` | Commands, options, text and JSON output |
| `internal/items` | The known locations: `mac.go` and `windows.go` hold the lists, `collect_*.go` the system calls and cleanup |
| `internal/scan` | Breakdowns, dev folders, large files and purge |
| `internal/apps` | Installed apps and what they leave behind, for apps and uninstall |
| `internal/sysinfo` | Disks, memory and the computer's name, per system |
| `internal/fsx` | Measuring and deleting without following links |
| `internal/ui` | Colors, sizes and the numbered picker |
| `install.sh`, `install.ps1` | Installers |
| `tools/dist.sh` | Builds the release archives and `SHA256SUMS` |
| `macos/Sources/MedicBarCore` | Medic.app's readings of CPU, memory, disk and processes, and installing the `medic` command, without AppKit |
| `macos/Sources/MedicBar` | Medic.app's menu bar item and menu |
| `macos/Art/draw.swift` | Draws the app icon and the DMG window, so there are no image files to keep in sync |
| `tools/macapp-screenshots.sh` | Draws the README screenshots of Medic's menu and the DMG window, with sample data |
| `tools/macapp.sh` | Builds `Medic.dmg`: the app and `medic` for Apple silicon and Intel, signed, in a DMG |
| `tools/screenshot`, `docs/make-screenshots.py` | Draw the README screenshots from the real rendering, with sample data |
| `tests/` | End-to-end tests run by CI |

To use your checkout as the `medic` command: `go build -o ~/.local/bin/medic ./cmd/medic`.

To run the menu bar app from your checkout: `swift run --package-path macos`.
To build the DMG: `tools/macapp.sh dist`, which writes `dist/Medic.dmg`.
It needs Swift from Xcode or the Command Line Tools (`xcode-select --install`), and Go.

## Medic.app

Medic.app reads the same counters as `medic memory` with system calls instead of commands, so the numbers match and it costs almost nothing while it runs.
It only reads every process while its menu is open.
Memory per app is the physical footprint, as in Activity Monitor, of the apps your user runs; `medic memory` also shows the footprint of system processes, which it reads from `top`.

Releases are signed ad hoc unless the release workflow has a Developer ID, see `.github/workflows/release.yml`.
Without one, people click Open Anyway once, and Medic clears the quarantine flag of the `medic` inside it when it starts, so that copy runs from Terminal too.

## Adding a location

1. Add it to `MacItems` (`internal/items/mac.go`) or `WindowsItems` (`internal/items/windows.go`).
2. If it is cleaned by emptying a folder, add the exact path to `macCleanableDirs` or `winCleanableDirs`.
   If the tool has its own cleanup command, add it to `macToolCommand` or `winToolCommand`, and a case to `Clean` in `collect_darwin.go` or `collect_windows.go`.
3. Keep the printed delete commands in sync: `DescribeMac` and `DescribeWindows` mirror `Clean`.

## Adding a purge folder kind

Add the folder name to `PurgeNames` and the file that proves what it is to `PurgeKind`, both in `internal/scan/purge.go`.

## Uninstall rules

An uninstall only offers paths it can explain: the app itself, entries named after its bundle id (Mac), its install folder (Windows), or folders with its exact name in a short list of app data folders.
Anything new must keep that bar, and `apps.Allowed` checks every path again right before it moves.
Everything goes to the Trash or Recycle Bin, never deleted directly.

## Before a pull request

- `gofmt -l .` prints nothing, and `go vet ./...` passes with and without `GOOS=windows`.
- `go test ./...`, then the end-to-end tests in `tests/` for your system.
- `shellcheck install.sh tools/*.sh macos/test.sh tests/*.sh`, and `Invoke-ScriptAnalyzer` on the `.ps1` files with `-Settings PSScriptAnalyzerSettings.psd1`.
- If you changed `macos/`: `macos/test.sh`, then `tests/macos-app.sh`, which builds the DMG and installs the app from it.
- If you changed Medic's menu, the icon or the DMG window: `tools/macapp-screenshots.sh`.
  Keep the `.ps1` files ASCII only, Windows PowerShell 5.1 misreads other characters.
- If the report changed: `python3 docs/make-screenshots.py`.

Commands, options, exit codes and the JSON shape are the same on both systems.
JSON fields are only ever added, never renamed or removed.
CI runs all of this on macOS and Windows.

## Releasing

Merge, then push a tag: `git tag v0.5.0 && git push origin v0.5.0`.
The tag is the version medic reports.
The release workflow builds the archives with `tools/dist.sh` and `Medic.dmg` with `tools/macapp.sh`, and publishes them with the installers and `SHA256SUMS`.
