# medic

> Formerly **storage-doctor**.
> Old links to this repository redirect here.

See what is filling up your computer, how big it is, and what is actually safe to delete.
Also shows how your memory (RAM) is doing and which apps use the most.

It is **read-only by default**: nothing is deleted unless you ask for a cleanup and confirm every item.
No dependencies: one script, installed as the `medic` command so you can run it from any folder.

## Which one do I need?

There are two versions.
Pick the one for your computer, they do not work on the other system.

| Your computer | Script | Installer | Run it in |
| --- | --- | --- | --- |
| **Mac** (macOS 11 or newer) | [`macos/medic.sh`](macos/medic.sh) | [`install.sh`](install.sh) | the **Terminal** app |
| **Windows** 10 or 11 | [`windows/medic.ps1`](windows/medic.ps1) | [`install.ps1`](install.ps1) | **PowerShell** or **Windows Terminal** |

Not sure what you have?

- If the top-left corner of your screen has an Apple logo menu, you have a **Mac**.
- If you have a Start button with the Windows logo, you have **Windows**.

> [!WARNING]
> Do not run the Mac script on Windows (not even in Git Bash or WSL), and do not run the Windows script on a Mac.
> Each script and installer checks this and stops with a message telling you which one to use instead.

---

## Mac

![Example output of medic on a Mac](docs/screenshot-macos.svg)

<sub>Example output with sample data.</sub>

### 1. Install

Open **Terminal** (press `Cmd + Space`, type `Terminal`, press Enter) and paste:

```sh
curl -fsSL https://github.com/f-bahesna/medic/releases/latest/download/install.sh | bash
```

Then open a new Terminal window and run `medic`, from any folder.

What the installer does:

- Downloads `medic.sh` from the latest release and checks it against the release's `SHA256SUMS`, it refuses to install a file that does not match.
- Puts it in `~/.local/bin/medic`, for your user only, no `sudo`.
- If `~/.local/bin` is not on your PATH yet, adds one line to `~/.zshrc` (or `~/.bash_profile` for bash).
  Pass `--no-modify-path` to add it yourself instead.

Like any script from the internet, you can read the installer first: download it with `curl -fsSLO <the same URL>` and open it with `less install.sh` (press `q` to quit).

| Command | What it does |
| --- | --- |
| `curl -fsSL .../install.sh \| bash` | Install, or update to the latest release |
| `curl -fsSL .../install.sh \| bash -s -- --version v0.3.0` | Install a specific release |
| `curl -fsSL .../install.sh \| bash -s -- --uninstall` | Remove medic |

Prefer not to install anything?
Download the script and run it in place, the options below work the same:

```sh
curl -fsSLO https://github.com/f-bahesna/medic/releases/latest/download/medic.sh
bash medic.sh
```

### 2. Options

| Command | What it does |
| --- | --- |
| `medic` | Full report (up to a minute) |
| `medic --quick` | Skip the slow scans (a few seconds) |
| `medic --dry-run` | Walk through the cleanup and show what would happen, change nothing |
| `medic --clean` | Clean SAFE and CAUTION items, asking `[y/N]` for each one |
| `medic --large 2000` | Only list files bigger than 2000 MB |
| `medic --dev-dir ~/work` | Also scan `~/work` for `node_modules` and Python venvs |
| `medic --help` | Show all options |

### 3. Permissions

macOS may ask whether Terminal can access Desktop, Documents, Downloads or data from other apps.
Allowing it gives complete results, declining just leaves those locations out.
Without **Full Disk Access** the Trash and Mail sizes show up empty, and the script tells you so.
You can grant it in System Settings > Privacy & Security > Full Disk Access > Terminal.

Do **not** run it with `sudo`, it refuses to, because it only needs your own files.

---

## Windows

![Example output of medic on Windows](docs/screenshot-windows.svg)

<sub>Example output with sample data.</sub>

### 1. Install

Open **PowerShell** (press the Windows key, type `PowerShell`, press Enter) and paste:

```powershell
irm https://github.com/f-bahesna/medic/releases/latest/download/install.ps1 | iex
```

Then open a new PowerShell window and run `medic`, from any folder.

What the installer does:

- Downloads `medic.ps1` from the latest release and checks it against the release's `SHA256SUMS`, it refuses to install a file that does not match.
- Puts it in `%LOCALAPPDATA%\Programs\medic`, for your user only, no administrator rights needed.
- Adds a small `medic.cmd` launcher in its `bin` folder to your user PATH.

Windows blocks downloaded scripts by default.
The launcher runs medic with `-ExecutionPolicy Bypass`, which allows **only that one run**, it does not change any setting on your PC.

Like any script from the internet, you can read the installer first: save it with `irm <the same URL> -OutFile install.ps1` and open it with `notepad install.ps1`.

| Command | What it does |
| --- | --- |
| `irm .../install.ps1 \| iex` | Install, or update to the latest release |
| `& ([scriptblock]::Create((irm .../install.ps1))) -Version v0.3.0` | Install a specific release |
| `& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall` | Remove medic and its PATH entry |

Prefer not to install anything?
Download the script and run it in place, with the same options as below:

```powershell
irm https://github.com/f-bahesna/medic/releases/latest/download/medic.ps1 -OutFile medic.ps1
powershell -ExecutionPolicy Bypass -File .\medic.ps1
```

### 2. Options

| Command | What it does |
| --- | --- |
| `medic` | Full report (can take a few minutes) |
| `medic -Quick` | Skip the slow scans |
| `medic -DryRun` | Walk through the cleanup and show what would happen, change nothing |
| `medic -Clean` | Clean SAFE and CAUTION items, asking `[y/N]` for each one |
| `medic -LargeMB 2000` | Only list files bigger than 2000 MB |
| `medic -DevDir C:\work` | Also scan `C:\work` for `node_modules` and Python venvs |
| `medic -?` | Show all options |

Note that Windows options start with a single dash and a capital letter (`-Clean`), Mac options with two dashes (`--clean`).

### 3. Administrator mode (optional)

As a normal user the script covers your own files.
To also measure and clean system caches (Windows Update downloads, system temp files, crash dumps, `Windows.old`), run it as administrator.
Right-click the Start button, choose **Terminal (Admin)** or **Windows PowerShell (Admin)** and run `medic` there.
Items that need administrator rights are marked `[admin]` in the report.

---

## What it reports

Both versions show the same sections:

- **Disk**: capacity, used and free space.
- **Memory (RAM)**: memory in use, cache, swap or page file, memory pressure, and the apps using the most memory.
- **Space hogs**: known cache and data locations, each with a size, a safety level and a one-line explanation.
- **Library / AppData breakdown**: the biggest folders inside `~/Library` (Mac) or `AppData` (Windows).
- **Dev dependencies**: `node_modules` and Python virtualenvs in common project folders.
- **Delete commands**: for every SAFE and CAUTION item, the exact command to clean it by hand, if you prefer that over the interactive cleanup.
- **Large files**: the biggest files in your home folder with their last modified date.
- **Managed by the system**: things like Time Machine snapshots, `pagefile.sys` or `WinSxS`, and what to do instead of deleting them by hand.

## Safety levels

| Level | Meaning | Can the cleanup touch it? |
| --- | --- | --- |
| `SAFE` | Regenerated automatically, no data loss (caches, logs, temp files, build output) | Yes, after you confirm |
| `CAUTION` | Regenerable, but you lose more than a cache (stopped Docker containers, locally installed Maven artifacts) | Yes, after you confirm |
| `REVIEW` | May contain your data (Downloads, phone backups, Photos, virtual machines) | **Never**, you get advice instead |

How the cleanup stays safe:

- When a tool has its own cleanup command, that command is used (`npm cache clean`, `go clean -modcache`, `docker system prune`, ...).
- Otherwise only the **contents** of folders on a hard-coded allowlist are deleted, matched exactly.
- Links (symlinks, junctions) are never followed, so a cleanup can never reach outside the allowed folder.
- Installer files are moved to the Trash / Recycle Bin, so you can put them back.
- System folders (`/System` on Mac, `C:\Windows\WinSxS` on Windows) are never touched.

## Good to know

- Sizes match what your system shows: decimal units on Mac (like Finder), binary units on Windows (like Explorer).
- On a Mac, Finder may show more free space, because it counts "purgeable" space macOS frees on its own.
- After a cleanup, the free space can take a minute to update.

## Contributing

Each version keeps its list of locations in one function: `collect_items` in the Mac script, `Initialize-Item` in the Windows script.
Adding a location is usually one line there.
If it can be cleaned by emptying a folder, also add the exact path to the allowlist (`CLEANABLE_DIRS` on Mac, `$cleanable` on Windows).
If the tool has its own cleanup command, add a case to `clean_item` (Mac) or `Invoke-ItemClean` (Windows) instead.
Keep the printed delete commands in sync: `item_commands` (Mac) and `Get-ItemCommand` (Windows) mirror the cleanup functions.
The README screenshots are drawn from the real output of both scripts with made-up data: after changing the report, run `python3 docs/make-screenshots.py` on a Mac with PowerShell 7 installed (CI checks they are up to date).

To try your changes as the `medic` command on a Mac, run `bash install.sh --link` in your checkout: it links `~/.local/bin/medic` to `macos/medic.sh`.

Before opening a pull request:

- Mac: `shellcheck macos/medic.sh install.sh tools/dist.sh tests/*.sh`, test with the built-in `/bin/bash` (version 3.2), and run `tests/macos-install.sh`.
- Windows: `Invoke-ScriptAnalyzer` on `windows/medic.ps1` and `install.ps1` with `-Settings windows/PSScriptAnalyzerSettings.psd1`, and test with the built-in Windows PowerShell 5.1.
  Keep both files ASCII only, Windows PowerShell 5.1 misreads other characters.

CI runs all of this on real macOS and Windows machines for every push.

### Releasing

1. Set the same version in `VERSION` (`macos/medic.sh`) and `$ScriptVersion` (`windows/medic.ps1`), and regenerate the screenshots.
2. Push a tag for it, for example `git tag v0.3.0 && git push origin v0.3.0`.

The release workflow checks that the tag matches both scripts, then publishes `medic.sh`, `medic.ps1`, both installers and `SHA256SUMS`, built by `tools/dist.sh`.
The installers always download from the latest release, so users get the new version by running the install command again.

## License

[MIT](LICENSE)
