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
| `medic disk` | `medic disk` | The storage part of the report: space hogs, dev folders, large files |
| `medic memory` | `medic memory` | Memory only: usage, pressure, top apps |
| `medic clean` | `medic clean` | Pick SAFE and CAUTION items to clean |
| `medic purge` | `medic purge` | Pick `node_modules`, venvs and build folders of projects untouched for 30 days |
| `medic check` | `medic check` | Exit 1 when free space is under 10% or memory pressure is critical |
| `medic --help` | `medic -?` | Show all options |

`clean` and `purge` list what they found with numbers.
Answer `1,3`, `2-5`, `all` or `safe`, then confirm once.

| Option (Mac / Windows) | Works with | What it does |
| --- | --- | --- |
| `--dry-run` / `-DryRun` | clean, purge | Show what would happen, change nothing |
| `--yes` / `-Yes` | clean, purge | Do not ask. Without `--only`, `clean` takes SAFE items only |
| `--only safe,npm` / `-Only safe,npm` | clean | Limit to these levels or item ids |
| `--older-than 90` / `-OlderThan 90` | purge | Project age in days, `0` for all projects |
| `--min-free 20G` / `-MinFree 20G` | check | Free space needed, as a size or a percentage |
| `--json` / `-Json` | report, disk, memory, purge, check | Machine-readable output, sizes in bytes |
| `--quick` / `-Quick` | report, disk | Skip the slow scans |
| `--dev-dir ~/work` / `-DevDir C:\work` | report, disk, purge | Also scan this project folder |
| `--large 2000` / `-LargeMB 2000` | report, disk | List files bigger than 2000 MB |

Exit codes: `0` ok, `1` error or failed check, `2` wrong usage.

### Automation

```sh
medic check --min-free 20G || echo "Disk almost full"   # in cron or CI
medic clean --yes --only safe                             # clean SAFE items without asking
medic report --json | jq '.summary'                       # use the numbers elsewhere
```

On Windows the same lines work with `-MinFree`, `-Yes -Only safe` and `-Json`.

## What it reports

- **Disk**: capacity, used and free space.
- **Memory**: RAM in use, swap or page file, memory pressure, top apps by memory.
- **Space hogs**: known cache and data locations, with size, safety level and a one-line explanation.
- **Breakdown**: the biggest folders in `~/Library` (Mac) or `AppData` (Windows).
- **Dev dependencies**: `node_modules` and Python venvs in your project folders (`~/dev`, `~/Projects`, `~/code` and similar).
- **Delete commands**: the exact command to clean each SAFE and CAUTION item by hand.
- **Large files**: the biggest files in your home folder.
- **Managed by the system**: Time Machine snapshots, `pagefile.sys`, `WinSxS`, and how to reduce them safely.

## Safety levels

| Level | Meaning | Cleaned by medic? |
| --- | --- | --- |
| `SAFE` | Regenerated automatically: caches, logs, temp files, build output | Yes, after you confirm |
| `CAUTION` | Regenerable, but you lose more than a cache: stopped Docker containers, local Maven artifacts | Yes, after you confirm |
| `REVIEW` | May contain your data: Downloads, phone backups, Photos, virtual machines | Never |

How `clean` and `purge` stay safe:

- A tool's own cleanup command is used when it has one (`npm cache clean`, `go clean -modcache`, `docker system prune`).
- Otherwise only the contents of folders on a fixed allowlist are deleted.
- `purge` only deletes a folder when the file that proves what it is sits next to it (`package.json`, `Cargo.toml`, `pom.xml`, `build.gradle`) or inside it (`pyvenv.cfg`).
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
