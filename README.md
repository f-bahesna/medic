# medic

See what fills your disk and memory, and clean what is safe to delete.
For macOS and Windows.

- **Read-only by default.** Nothing is deleted unless you run a cleanup and confirm each item.
- **No dependencies.** One script per system, installed as the `medic` command.

Formerly `storage-doctor`.

![Example output of medic on a Mac](docs/screenshot-macos.svg)

<details>
<summary>Windows example</summary>

![Example output of medic on Windows](docs/screenshot-windows.svg)

</details>

<sub>Example output with sample data.</sub>

## Install

**Mac** (macOS 11 or newer), in Terminal:

```sh
curl -fsSL https://github.com/f-bahesna/medic/releases/latest/download/install.sh | bash
```

**Windows** (10 or 11), in PowerShell:

```powershell
irm https://github.com/f-bahesna/medic/releases/latest/download/install.ps1 | iex
```

Open a new terminal window and run `medic`.

The installer:

- verifies the download against the release's `SHA256SUMS`,
- installs for your user only, without `sudo` or administrator rights,
- adds medic to your PATH (Mac: `~/.local/bin`, Windows: `%LOCALAPPDATA%\Programs\medic\bin`).

| To | Mac | Windows |
| --- | --- | --- |
| Update | Run the install command again | Run the install command again |
| Install a specific version | `... \| bash -s -- --version v0.3.0` | `& ([scriptblock]::Create((irm .../install.ps1))) -Version v0.3.0` |
| Uninstall | `... \| bash -s -- --uninstall` | `& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall` |
| Run without installing | Download `medic.sh` from the [latest release](https://github.com/f-bahesna/medic/releases/latest), run `bash medic.sh` | Download `medic.ps1`, run `powershell -ExecutionPolicy Bypass -File .\medic.ps1` |

## Usage

| Mac | Windows | What it does |
| --- | --- | --- |
| `medic` | `medic` | Full report |
| `medic --quick` | `medic -Quick` | Skip the slow scans |
| `medic --dry-run` | `medic -DryRun` | Show what a cleanup would do, change nothing |
| `medic --clean` | `medic -Clean` | Clean SAFE and CAUTION items, asking for each one |
| `medic --large 2000` | `medic -LargeMB 2000` | List files bigger than 2000 MB |
| `medic --dev-dir ~/work` | `medic -DevDir C:\work` | Also scan this folder for `node_modules` and Python venvs |
| `medic --help` | `medic -?` | Show all options |

## What it reports

- **Disk**: capacity, used and free space.
- **Memory**: RAM in use, swap or page file, memory pressure, top apps by memory.
- **Space hogs**: known cache and data locations, with size, safety level and a one-line explanation.
- **Breakdown**: the biggest folders in `~/Library` (Mac) or `AppData` (Windows).
- **Dev dependencies**: `node_modules` and Python venvs in common project folders.
- **Delete commands**: the exact command to clean each SAFE and CAUTION item by hand.
- **Large files**: the biggest files in your home folder.
- **Managed by the system**: Time Machine snapshots, `pagefile.sys`, `WinSxS`, and how to reduce them safely.

## Safety levels

| Level | Meaning | Cleaned by medic? |
| --- | --- | --- |
| `SAFE` | Regenerated automatically: caches, logs, temp files, build output | Yes, after you confirm |
| `CAUTION` | Regenerable, but you lose more than a cache: stopped Docker containers, local Maven artifacts | Yes, after you confirm |
| `REVIEW` | May contain your data: Downloads, phone backups, Photos, virtual machines | Never |

How cleanup stays safe:

- A tool's own cleanup command is used when it has one (`npm cache clean`, `go clean -modcache`, `docker system prune`).
- Otherwise only the contents of folders on a fixed allowlist are deleted.
- Symlinks and junctions are never followed.
- Installers in Downloads go to the Trash or Recycle Bin, so you can restore them.

## Notes

- **Mac permissions:** grant Terminal Full Disk Access (System Settings > Privacy & Security) to include Trash and Mail.
  Do not use `sudo`, medic refuses it.
- **Windows administrator:** run `medic` in **Terminal (Admin)** to also include system caches (Windows Update, crash dumps, `Windows.old`).
  These items are marked `[admin]`.
- **Sizes** use the same units as Finder (decimal) and Explorer (binary).
  Finder may show more free space, because it counts purgeable space.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
