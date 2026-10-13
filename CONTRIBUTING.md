# Contributing

## Layout

| Path | What |
| --- | --- |
| `macos/medic.sh` | Mac version, bash 3.2 |
| `windows/medic.ps1` | Windows version, PowerShell 5.1 and 7, ASCII only |
| `install.sh`, `install.ps1` | Installers |
| `tools/dist.sh` | Builds the release files and `SHA256SUMS` |
| `tests/` | Tests run by CI |
| `docs/make-screenshots.py` | Draws the README screenshots from the real output, with sample data |

## Adding a location

1. Add it to `collect_items` (Mac) or `Initialize-Item` (Windows).
2. If it is cleaned by emptying a folder, add the exact path to `CLEANABLE_DIRS` (Mac) or `$cleanable` (Windows).
   If the tool has its own cleanup command, add a case to `clean_item` (Mac) or `Invoke-ItemClean` (Windows) instead.
3. Keep the printed delete commands in sync: `item_commands` (Mac), `Get-ItemCommand` (Windows).

Run `bash install.sh --link` to use your checkout as the `medic` command.

## Before a pull request

- Mac: `shellcheck macos/medic.sh install.sh tools/dist.sh tests/*.sh`, then run the tests in `tests/` with `/bin/bash`.
- Windows: `Invoke-ScriptAnalyzer` on every `.ps1` file with `-Settings windows/PSScriptAnalyzerSettings.psd1`, and test with Windows PowerShell 5.1.
- If the report changed: `python3 docs/make-screenshots.py` on a Mac with PowerShell 7.

CI runs all of this on macOS and Windows.

## Releasing

1. Set the same version in `VERSION` (`macos/medic.sh`) and `$ScriptVersion` (`windows/medic.ps1`), then regenerate the screenshots.
2. Merge, then push a tag: `git tag v0.4.0 && git push origin v0.4.0`.

The release workflow checks the tag against both scripts and publishes the files built by `tools/dist.sh`.
