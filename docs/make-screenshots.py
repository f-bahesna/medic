"""Render the README screenshots: terminal-style SVGs of storage-doctor output.

All data is made up. Keep the layout in sync with the scripts when their output
changes, then run:  python3 docs/make-screenshots.py
"""
import os
import sys
from xml.sax.saxutils import escape

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

FONT = 13
LINE = 18
CHAR = 8.0  # advance width of a 13px monospace glyph, with a little slack
PAD_X = 20


def row(label, value, hint=None, hint_style="dim"):
    segs = [(f"  {label:<22} {value}", None)]
    if hint:
        segs.append((" " + hint, hint_style))
    return segs


def bar_row(label, value, pct, color):
    filled = pct * 30 // 100
    return [(f"  {label:<22} {value:<10} ", None),
            ("[" + "#" * filled + "." * (30 - filled) + "]", color), (f" {pct}%", None)]


def section(title, line_style):
    return [[], [(title, line_style)], [("-" * 60, "dim")]]


def item(size, safety, color, label, note, path, indent):
    lines = [[(f"  {size:<10} ", None), (f"{safety:<7}", color), ("  " + label, "bold")]]
    lines.append([(" " * indent + note, "dim")])
    if path:
        lines.append([(" " * indent + path, "dim")])
    return lines


def summary(rows, colors):
    out = []
    for safety, size, text in rows:
        out.append([("  ", None), (f"{safety:<7}", colors[safety]), (f"  {size:<10}", "bold"), (" " + text, None)])
    return out


def render(name, prompt, lines, theme):
    fixed = [l for l in lines if not isinstance(l, tuple)]
    width_chars = max(sum(len(t) for t, _ in l) for l in fixed + [[(theme["prompt_prefix"] + prompt, None)]])
    # A ("wrap", text) line is longer than the window, so it wraps like it would in a terminal.
    wrapped = []
    for l in lines:
        if isinstance(l, tuple):
            text = l[1]
            wrapped += [[(text[k:k + width_chars], None)] for k in range(0, len(text), width_chars)]
        else:
            wrapped.append(l)
    lines = wrapped
    width = int(PAD_X * 2 + width_chars * CHAR) + 10
    top = 44
    height = top + 16 + (len(lines) + 2) * LINE + 14
    p = theme["palette"]
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(theme["aria"])}">',
           f'<rect width="{width}" height="{height}" rx="{theme["radius"]}" fill="{p["bg"]}"/>',
           f'<rect width="{width}" height="34" rx="{theme["radius"]}" fill="{p["bar"]}"/>',
           f'<rect y="{34 - theme["radius"]}" width="{width}" height="{theme["radius"]}" fill="{p["bar"]}"/>']
    svg += theme["chrome"](width)
    svg.append(f'<text font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, \'Cascadia Mono\', monospace" font-size="{FONT}" fill="{p["fg"]}" xml:space="preserve">')
    y = top + 14
    svg.append(f'<tspan x="{PAD_X}" y="{y}"><tspan fill="{p["prompt"]}">{escape(theme["prompt_prefix"])}</tspan>{escape(prompt)}</tspan>')
    y += LINE * 2
    for l in lines:
        parts = []
        for text, style in l:
            t = escape(text)
            if style is None:
                parts.append(t)
            elif style == "bold":
                parts.append(f'<tspan font-weight="{p.get("weight", "bold")}" fill="{p["bold"]}">{t}</tspan>')
            elif style.endswith("+bold"):
                parts.append(f'<tspan font-weight="bold" fill="{p[style[:-5]]}">{t}</tspan>')
            else:
                parts.append(f'<tspan fill="{p[style]}">{t}</tspan>')
        if parts:
            svg.append(f'<tspan x="{PAD_X}" y="{y}">{"".join(parts)}</tspan>')
        y += LINE
    svg.append("</text></svg>")
    with open(f"{OUT}/{name}", "w") as f:
        f.write("\n".join(svg) + "\n")


# ---------------------------------------------------------------- macOS ----

mac_palette = {"bg": "#1e1f22", "bar": "#2b2d31", "fg": "#d7dae0", "bold": "#ffffff", "dim": "#7f848e",
               "green": "#98c379", "yellow": "#e5c07b", "red": "#e06c75", "cyan": "#56b6c2", "prompt": "#98c379"}


def mac_chrome(width):
    return ['<circle cx="20" cy="17" r="6" fill="#ff5f57"/>', '<circle cx="40" cy="17" r="6" fill="#febc2e"/>',
            '<circle cx="60" cy="17" r="6" fill="#28c840"/>',
            f'<text x="{width / 2}" y="22" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', sans-serif" font-size="13" fill="#9da1a8">Terminal - storage-doctor.sh</text>']


C = {"SAFE": "green", "CAUTION": "yellow", "REVIEW": "red"}
mac = [[("storage-doctor 0.2.0", "bold"), (" - MacBook Air, macOS 15.5", "dim")],
       [("  Read-only scan. Nothing is deleted unless you run --clean and confirm.", "dim")]]
mac += section("Disk", "cyan+bold")
mac += [row("Capacity", "494.4 GB"), bar_row("Used", "431.2 GB", 87, "yellow"),
        [(f"  {'Free':<22} ", None), ("63.2 GB", "bold")],
        row("  macOS (read-only)", "11.8 GB"), row("  Your data volume", "402.6 GB"),
        row("  Other volumes", "16.8 GB", "(swap, recovery, updates)"),
        [("  Finder may show more free space: it also counts 'purgeable' space macOS can free on its own.", "dim")]]
mac += section("Memory (RAM)", "cyan+bold")
mac += [row("Physical memory", "16.0 GB"), bar_row("Used", "11.4 GB", 71, "green"),
        row("  App memory", "6.1 GB"), row("  Wired", "2.3 GB", "(kernel, cannot be freed)"),
        row("  Compressed", "3.0 GB"), row("Cached files", "3.9 GB", "(freed instantly when apps need it)"),
        row("Free", "712 MB"), row("Swap used", "1.2 GB of 2.0 GB"),
        [(f"  {'Memory pressure':<22} ", None), ("Normal", "green"), (" (52% available)", "dim")], [],
        [("  Top apps by memory", "bold"), (" (resident memory, approximate)", "dim")]]
for size, app, n in [("3.1 GB", "Google Chrome", 24), ("1.2 GB", "Slack", 6), ("1.1 GB", "Code", 9),
                     ("842 MB", "Docker Desktop", 4), ("612 MB", "Spotify", 3), ("214 MB", "Finder", 1)]:
    mac.append([(f"    {size:<10} {app}", None)] + ([(f" ({n} processes)", "dim")] if n > 1 else []))
mac.append([("  High 'used' memory is normal on macOS. Only memory pressure tells you if RAM is a problem.", "dim")])
mac += section("Space hogs", "cyan+bold")
mac.append([(f"  {'SIZE':<10} {'SAFETY':<7}  WHAT", "dim")])
for size, s, label, note, path in [
    ("24.3 GB", "REVIEW", "Photos library (Photos Library.photoslibrary)",
     "Never delete files inside it. Use the Photos app or iCloud 'Optimize Mac Storage'.", "~/Pictures/Photos Library.photoslibrary"),
    ("14.8 GB", "SAFE", "User app caches", "Apps rebuild these on demand. Quit apps before cleaning.", "~/Library/Caches"),
    ("9.6 GB", "CAUTION", "Docker Desktop disk image",
     "Clean runs 'docker system prune': stopped containers, dangling images, build cache. Volumes are kept.",
     "~/Library/Containers/com.docker.docker/Data/vms"),
    ("7.2 GB", "SAFE", "Xcode DerivedData", "Build intermediates. The next build is slower, nothing is lost.",
     "~/Library/Developer/Xcode/DerivedData"),
    ("5.1 GB", "REVIEW", "iPhone / iPad backups",
     "Delete old backups in Finder > your device > Manage Backups, never by hand.", "~/Library/Application Support/MobileSync/Backup"),
    ("2.4 GB", "SAFE", "npm cache", "Packages are downloaded again when needed.", "~/.npm/_cacache"),
    ("1.9 GB", "CAUTION", "Installer files (6 .dmg/.pkg/.xip/.iso)",
     "Rarely needed after installing. Clean moves them to the Trash, so it can be undone.", None),
]:
    mac += item(size, s, C[s], label, note, path, 22)
mac += section("Delete commands", "cyan+bold")
mac += [[("  Prefer --clean: it asks per item and only touches allowlisted folders.", "dim")],
        [("  To clean by hand, quit the related apps and copy the command under an item.", "dim")]]
for s_, label, size, cmds in [
    ("SAFE", "User app caches", "14.8 GB", ['rm -rf "$HOME/Library/Caches"/*']),
    ("CAUTION", "Docker Desktop disk image", "9.6 GB", ["docker system prune --force"]),
    ("SAFE", "Xcode DerivedData", "7.2 GB", ['rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*']),
    ("SAFE", "npm cache", "2.4 GB", ["npm cache clean --force"]),
]:
    mac += [[], [("  ", None), (f"{s_:<7}", C[s_]), ("  " + label, "bold"), (f" ({size})", "dim")]]
    mac += [[("    " + c, None)] for c in cmds]
mac += section("Summary", "cyan+bold")
mac += summary([("SAFE", "24.4 GB", "regenerated automatically, no data loss"),
                ("CAUTION", "11.5 GB", "regenerable, read the note first"),
                ("REVIEW", "29.4 GB", "your data, check by hand (never cleaned by storage-doctor)")], C)
mac += [[], [("  Run ", None), ("storage-doctor.sh --clean", "bold"), (" to clean SAFE and CAUTION items (asks for each one),", None)],
        [("  or ", None), ("storage-doctor.sh --dry-run", "bold"), (" to preview without changing anything.", None)]]

render("screenshot-macos.svg", "bash storage-doctor.sh", mac,
       {"palette": mac_palette, "radius": 10, "chrome": mac_chrome, "prompt_prefix": "~ $ ",
        "aria": "Example storage-doctor output on macOS, with sample data"})

# -------------------------------------------------------------- Windows ----

win_palette = {"bg": "#0c0c0c", "bar": "#202020", "fg": "#cccccc", "bold": "#cccccc", "dim": "#767676",
               "green": "#16c60c", "yellow": "#c19c00", "red": "#e74856", "cyan": "#3a96dd", "prompt": "#cccccc", "weight": "normal"}


def win_chrome(width):
    return ['<rect x="8" y="6" width="190" height="28" rx="6" fill="#0c0c0c"/>',
            '<rect x="18" y="14" width="12" height="12" rx="2" fill="none" stroke="#3a96dd" stroke-width="1.5"/>',
            '<path d="M21 17 l3 3 -3 3" fill="none" stroke="#3a96dd" stroke-width="1.5"/>',
            '<text x="38" y="24" font-family="\'Segoe UI\', -apple-system, sans-serif" font-size="12" fill="#ffffff">Windows PowerShell</text>',
            f'<path d="M{width - 116} 17 h10" stroke="#cccccc" stroke-width="1"/>',
            f'<rect x="{width - 71}" y="12" width="10" height="10" fill="none" stroke="#cccccc" stroke-width="1"/>',
            f'<path d="M{width - 26} 12 l10 10 M{width - 16} 12 l-10 10" stroke="#cccccc" stroke-width="1"/>']


win = [[("storage-doctor 0.2.0", None), (" - DESKTOP-7K2M4QX, Microsoft Windows 11 Pro 10.0.26100", "dim")],
       [("  Read-only scan. Nothing is deleted unless you run -Clean and confirm.", "dim")]]
win += section("Disk", "cyan")
win += [[("  C: (system drive)", None)], row("  Capacity", "475.8 GB"), bar_row("  Used", "412.3 GB", 86, "yellow"),
        row("  Free", "63.5 GB"),
        [("  D: Data", None)], row("  Capacity", "931.5 GB"), bar_row("  Used", "288.1 GB", 30, "green"),
        row("  Free", "643.4 GB")]
win += section("Memory (RAM)", "cyan")
win += [row("Physical memory", "16.0 GB"), bar_row("In use", "10.9 GB", 68, "green"),
        row("  Compressed", "1.4 GB"), row("Cached", "4.2 GB", "(freed instantly when apps need it)"),
        row("Available", "5.1 GB"), row("Committed", "14.6 GB of 34.9 GB", "(41%, RAM + page file)"),
        row("Page file used", "1.1 GB of 18.9 GB"),
        [(f"  {'Memory pressure':<22} ", None), ("Normal", "green"), (" (31% available)", "dim")], [],
        [("  Top apps by memory", None), (" (working set, approximate)", "dim")]]
for size, app, n in [("2.7 GB", "chrome", 31), ("1.3 GB", "Code", 11), ("1.1 GB", "svchost", 94),
                     ("986 MB", "ms-teams", 4), ("604 MB", "explorer", 1), ("433 MB", "Discord", 6)]:
    win.append([(f"    {size:<10} {app}", None)] + ([(f" ({n} processes)", "dim")] if n > 1 else []))
win.append([('  High "in use" memory is normal. Only memory pressure tells you if RAM is a problem.', "dim")])
win += section("Space hogs", "cyan")
win.append([(f"  {'SIZE':<10} {'SAFETY':<7}  WHAT", "dim")])
for size, s, label, note, path in [
    ("41.2 GB", "REVIEW", "WSL Linux distros",
     "Your Linux files. 'wsl --unregister <name>' removes an unused distro and everything in it.",
     "~\\AppData\\Local\\Packages\\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\\LocalState\\ext4.vhdx"),
    ("12.6 GB", "SAFE", "Browser caches (Chrome, Edge, Brave, Firefox)",
     "Web page caches. Close the browser before cleaning.", "~\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache"),
    ("8.4 GB", "SAFE", "Temporary files", "Leftovers from installers and apps. Files still in use are skipped.",
     "~\\AppData\\Local\\Temp"),
    ("6.9 GB", "CAUTION", "Docker Desktop data",
     "Clean runs 'docker system prune': stopped containers, dangling images, build cache. Volumes are kept.",
     "~\\AppData\\Local\\Docker\\wsl"),
    ("3.8 GB", "REVIEW", "Downloads folder", "Your files. Sort by size in Explorer and remove what you no longer need.",
     "~\\Downloads"),
    ("2.2 GB", "SAFE", "npm cache", "Packages are downloaded again when needed.", "~\\AppData\\Local\\npm-cache"),
    ("1.7 GB", "CAUTION", "Installer files (9 .msi/.iso/setup.exe)",
     "Rarely needed after installing. Clean moves them to the Recycle Bin, so it can be undone.", None),
]:
    win += item(size, s, C[s], label, note, path, 22)
win.append([("  Run as administrator to also measure system caches (Windows Update, crash dumps, Windows.old).", "dim")])
win += section("Delete commands", "cyan")
win += [[("  Prefer -Clean: it asks per item and only touches allowlisted folders.", "dim")],
        [("  To clean by hand, close the related apps and copy the commands under an item.", "dim")], [],
        [("  Paste this helper once per PowerShell window. It empties a folder without following links:", "dim")],
        ("wrap", "    function Clear-Folder($Path) { Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue"
                 " | ForEach-Object { if ($_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint))"
                 ' { cmd /c rd "$($_.FullName)" } elseif ($_.PSIsContainer) { cmd /c rd /s /q "$($_.FullName)" 2>$null }'
                 " else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } } }")]
for s_, label, size, cmds in [
    ("SAFE", "Browser caches (Chrome, Edge, Brave, Firefox)", "12.6 GB",
     ['Clear-Folder "$env:LOCALAPPDATA\\Google\\Chrome\\User Data\\Default\\Cache"',
      'Clear-Folder "$env:LOCALAPPDATA\\Google\\Chrome\\User Data\\Default\\Code Cache"',
      'Clear-Folder "$env:LOCALAPPDATA\\Microsoft\\Edge\\User Data\\Default\\Cache"']),
    ("SAFE", "Temporary files", "8.4 GB", ['Clear-Folder "$env:LOCALAPPDATA\\Temp"']),
    ("CAUTION", "Docker Desktop data", "6.9 GB", ["docker system prune --force"]),
    ("SAFE", "npm cache", "2.2 GB", ["npm cache clean --force"]),
]:
    win += [[], [("  ", None), (f"{s_:<7}", C[s_]), ("  " + label, None), (f" ({size})", "dim")]]
    win += [[("    " + c, None)] for c in cmds]
win += section("Summary", "cyan")
win += summary([("SAFE", "23.2 GB", "regenerated automatically, no data loss"),
                ("CAUTION", "8.6 GB", "regenerable, read the note first"),
                ("REVIEW", "45.0 GB", "your data, check by hand (never cleaned by storage-doctor)")], C)
win += [[], [("  Run again with -Clean to clean SAFE and CAUTION items (asks for each one),", None)],
        [("  or with -DryRun to preview without changing anything.", None)]]

render("screenshot-windows.svg", "powershell -ExecutionPolicy Bypass -File .\\storage-doctor.ps1", win,
       {"palette": win_palette, "radius": 8, "chrome": win_chrome, "prompt_prefix": "PS C:\\Users\\alex> ",
        "aria": "Example storage-doctor output on Windows, with sample data"})
