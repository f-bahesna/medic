"""Draw the README screenshots from the real output of both scripts, with made-up data.

macOS: medic.sh runs unmodified, installed as "medic" on PATH. The system commands it reads from (df, du,
vm_stat, sysctl, ps, ...) are replaced by fakes earlier on PATH, and HOME points at a
throwaway folder.
Windows: screenshot-data-windows.ps1 runs the real script functions in PowerShell 7
and only replaces the ones that read the system.

Both run in a pseudo terminal so the colors are real, and the ANSI output is turned
into SVG. Run on a Mac with PowerShell 7 installed (or PWSH=/path/to/pwsh):

    python3 docs/make-screenshots.py
"""
import getpass
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

DOCS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DOCS)

FONT = 13
LINE = 18
CHAR = 8.0      # advance width of a 13px monospace glyph, with a little slack
PAD_X = 20
MAX_COLS = 124  # longer lines wrap, like they would in a terminal window

KB_PER_GB = 1e6 / 1.024  # the macOS script shows decimal units, like Finder


# ---------------------------------------------------------------- macOS ----

def gb(value):
    return int(value * KB_PER_GB)


MAC_SIZES = {  # path under HOME -> size in KB, as `du -sk` would report it
    "Pictures/Photos Library.photoslibrary": gb(24.3),
    "Library/Caches": gb(14.8),
    "Library/Containers/com.docker.docker/Data/vms": gb(9.6),
    "Library/Developer/Xcode/DerivedData": gb(7.2),
    "Library/Application Support/MobileSync/Backup": gb(5.1),
    ".npm/_cacache": gb(2.4),
}
MAC_INSTALLERS = {  # file in ~/Downloads -> size in MB
    "Docker.dmg": 610, "UTM.dmg": 430, "LibreOffice_25.8.1_MacOS_aarch64.dmg": 330,
    "googlechrome.dmg": 230, "Slack-4.46.99-macOS.dmg": 180, "Zoom.pkg": 120,
}
MAC_APPS = [  # (executable, processes, total MB)
    ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 24, 3174),
    ("/Applications/Slack.app/Contents/MacOS/Slack", 6, 1229),
    ("/Applications/Visual Studio Code.app/Contents/MacOS/Electron", 9, 1126),
    ("/Applications/Docker.app/Contents/MacOS/com.docker.backend", 4, 842),
    ("/Applications/Spotify.app/Contents/MacOS/Spotify", 3, 612),
    ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 1, 214),
    ("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", 1, 176),
    ("/usr/libexec/trustd", 1, 38),
]

PAGE = 16384
PAGES_PER_GB = (1 << 30) // PAGE


def pages(value_gb):
    return int(value_gb * PAGES_PER_GB)


MAC_FAKES = {
    "df": """#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on"
case "$2" in
  /) echo "/dev/disk3s1s1 482812500 11523438 61718750 16% 0 0 0% /" ;;
  *) echo "/dev/disk3s5 482812500 393164063 61718750 87% 0 0 0% /System/Volumes/Data" ;;
esac
""",
    "du": """#!/bin/bash
shift
for p in "$@"; do
  kb=$(awk -F'\\t' -v p="$p" '$1 == p { print $2 }' "$FAKE_SIZES")
  printf '%s\\t%s\\n' "${kb:-4}" "$p"
done
""",
    "vm_stat": f"""#!/bin/bash
cat <<EOF
Mach Virtual Memory Statistics: (page size of {PAGE} bytes)
Pages free:                               {int(712 * 1024 * 1024 / PAGE)}.
Pages wired down:                         {pages(2.3)}.
Pages purgeable:                          {pages(0.2)}.
File-backed pages:                        {pages(3.7)}.
Anonymous pages:                          {pages(6.3)}.
Pages occupied by compressor:             {pages(3.0)}.
EOF
""",
    "sysctl": """#!/bin/bash
case "$2" in
  hw.memsize) echo 17179869184 ;;
  kern.memorystatus_vm_pressure_level) echo 1 ;;
  vm.swapusage) echo "total = 2048.00M  used = 1228.80M  free = 819.20M  (encrypted)" ;;
esac
""",
    "memory_pressure": "#!/bin/bash\necho 'System-wide memory free percentage: 52%'\n",
    "ps": "#!/bin/bash\ncat \"$FAKE_PS\"\n",
    "scutil": "#!/bin/bash\necho 'MacBook Air'\n",
    "sw_vers": "#!/bin/bash\necho 15.5\n",
    "tmutil": "#!/bin/bash\necho com.apple.TimeMachine.2026-10-10-093012.local\n",
    "npm": "#!/bin/bash\n",
    "docker": "#!/bin/bash\n",
}


def mac_output():
    tmp = tempfile.mkdtemp(prefix="medic-shot.")
    try:
        home, bin_dir = os.path.join(tmp, "home"), os.path.join(tmp, "bin")
        os.makedirs(bin_dir)
        for name, body in MAC_FAKES.items():
            path = os.path.join(bin_dir, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        os.symlink(os.path.join(ROOT, "macos", "medic.sh"), os.path.join(bin_dir, "medic"))  # like install.sh --link

        sizes = []
        for rel, kb in MAC_SIZES.items():
            os.makedirs(os.path.join(home, rel))
            open(os.path.join(home, rel, "data"), "w").close()  # not empty
            sizes.append(f"{os.path.join(home, rel)}\t{kb}")
        os.makedirs(os.path.join(home, "Downloads"))
        for name, mb in MAC_INSTALLERS.items():
            path = os.path.join(home, "Downloads", name)
            open(path, "w").close()
            sizes.append(f"{path}\t{int(mb * 1000 / 1.024)}")
        with open(os.path.join(tmp, "sizes"), "w") as f:
            f.write("\n".join(sizes) + "\n")

        with open(os.path.join(tmp, "ps"), "w") as f:
            for path, count, total_mb in MAC_APPS:
                helper = path.replace("/Contents/MacOS/", "/Contents/Frameworks/Helper.app/Contents/MacOS/")
                for i in range(count):
                    f.write(f"{total_mb * 1024 // count} {path if i == 0 else helper}\n")

        env = {"HOME": home, "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
               "TMPDIR": tmp, "FAKE_SIZES": os.path.join(tmp, "sizes"), "FAKE_PS": os.path.join(tmp, "ps")}
        return run_in_pty(["/bin/bash", "-c", "exec medic --quick 2>/dev/null"], cwd=home, env=env)
    finally:
        shutil.rmtree(tmp)


# -------------------------------------------------------------- Windows ----

def windows_output():
    pwsh = os.environ.get("PWSH") or shutil.which("pwsh")
    if not pwsh:
        sys.exit("PowerShell 7 is needed for the Windows screenshot: install it or set PWSH=/path/to/pwsh")
    env = {"HOME": tempfile.gettempdir(), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"}
    return run_in_pty([pwsh, "-NoProfile", "-NoLogo", "-File", os.path.join(DOCS, "screenshot-data-windows.ps1")],
                      cwd=DOCS, env=env)


# ------------------------------------------------------------ rendering ----

def run_in_pty(cmd, cwd, env):
    """Run cmd with a terminal as stdout, so the script prints its colors."""
    out = subprocess.run(["script", "-q", "/dev/null"] + cmd, cwd=cwd, env=env,
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, check=True).stdout.decode()
    # The screenshots are published: never let anything from this machine end up in them.
    for private in {os.path.expanduser("~"), getpass.getuser(), os.uname().nodename.split(".")[0]}:
        if private and private.lower() in out.lower():
            sys.exit(f"refusing to write screenshots: the output contains {private!r} from this machine:\n{out}")
    for marker in ("Exception", "Error:", "Line |", "command not found"):
        if marker in out:
            sys.exit(f"refusing to write screenshots: the script printed an error:\n{out}")
    return out


SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_ESCAPES = re.compile(r"\x1b\[[0-9;?]*[A-Za-ln-z]|\x1b[=>]|\x1b\][^\x07]*\x07|\^D\x08\x08")


def parse_ansi(text):
    """Split ANSI output into lines of (text, fg_code, bold, dim) segments."""
    text = OTHER_ESCAPES.sub("", text).replace("\r", "")
    fg, bold, dim = None, False, False
    lines = []
    for raw in text.rstrip("\n").split("\n"):
        segments, pos = [], 0
        for m in SGR.finditer(raw):
            if m.start() > pos:
                segments.append((raw[pos:m.start()], fg, bold, dim))
            for code in (int(c) for c in (m.group(1) or "0").split(";")):
                if code == 0:
                    fg, bold, dim = None, False, False
                elif code == 1:
                    bold = True
                elif code == 2:
                    dim = True
                elif code == 22:
                    bold = dim = False
                elif code == 39:
                    fg = None
                elif 30 <= code <= 37 or 90 <= code <= 97:
                    fg = code
            pos = m.end()
        if pos < len(raw):
            segments.append((raw[pos:], fg, bold, dim))
        lines.append(segments)
    return lines


def wrap(lines, cols):
    out = []
    for segs in lines:
        current, used = [], 0
        for text, *style in segs:
            while used + len(text) > cols:
                cut = cols - used
                current.append((text[:cut], *style))
                out.append(current)
                current, used, text = [], 0, text[cut:]
            if text:
                current.append((text, *style))
                used += len(text)
        out.append(current)
    return out


def render(name, prompt, lines, theme):
    p = theme["palette"]
    widths = [sum(len(s[0]) for s in l) for l in lines]
    cols = min(MAX_COLS, max([w for w in widths if w <= MAX_COLS] + [len(theme["prompt_prefix"] + prompt)]))
    lines = wrap(lines, cols)
    width = int(PAD_X * 2 + cols * CHAR) + 10
    top = 44
    height = top + 16 + (len(lines) + 2) * LINE + 14
    r = theme["radius"]
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(theme["aria"])}">',
           f'<rect width="{width}" height="{height}" rx="{r}" fill="{p["bg"]}"/>',
           f'<rect width="{width}" height="34" rx="{r}" fill="{p["bar"]}"/>',
           f'<rect y="{34 - r}" width="{width}" height="{r}" fill="{p["bar"]}"/>']
    svg += theme["chrome"](width)
    svg.append(f'<text font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, \'Cascadia Mono\', monospace" font-size="{FONT}" fill="{p["fg"]}" xml:space="preserve">')
    y = top + 14
    svg.append(f'<tspan x="{PAD_X}" y="{y}"><tspan fill="{p["prompt"]}">{escape(theme["prompt_prefix"])}</tspan>{escape(prompt)}</tspan>')
    y += LINE * 2
    for segs in lines:
        parts = []
        for text, fg, bold, dim in segs:
            if not text:
                continue
            attrs = []
            if fg is not None:
                attrs.append(f'fill="{p["ansi"][fg]}"')
            elif dim:
                attrs.append(f'fill="{p["dim"]}"')
            elif bold:
                attrs.append(f'fill="{p["bold"]}"')
            if bold:
                attrs.append('font-weight="bold"')
            parts.append(f'<tspan {" ".join(attrs)}>{escape(text)}</tspan>' if attrs else escape(text))
        if parts:
            svg.append(f'<tspan x="{PAD_X}" y="{y}">{"".join(parts)}</tspan>')
        y += LINE
    svg.append("</text></svg>")
    with open(os.path.join(DOCS, name), "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote docs/{name} ({len(lines)} lines)")


def mac_chrome(width):
    return ['<circle cx="20" cy="17" r="6" fill="#ff5f57"/>', '<circle cx="40" cy="17" r="6" fill="#febc2e"/>',
            '<circle cx="60" cy="17" r="6" fill="#28c840"/>',
            f'<text x="{width / 2}" y="22" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', sans-serif" font-size="13" fill="#9da1a8">Terminal - medic</text>']


def win_chrome(width):
    return ['<rect x="8" y="6" width="190" height="28" rx="6" fill="#0c0c0c"/>',
            '<rect x="18" y="14" width="12" height="12" rx="2" fill="none" stroke="#3a96dd" stroke-width="1.5"/>',
            '<path d="M21 17 l3 3 -3 3" fill="none" stroke="#3a96dd" stroke-width="1.5"/>',
            '<text x="38" y="24" font-family="\'Segoe UI\', -apple-system, sans-serif" font-size="12" fill="#ffffff">Windows PowerShell</text>',
            f'<path d="M{width - 116} 17 h10" stroke="#cccccc" stroke-width="1"/>',
            f'<rect x="{width - 71}" y="12" width="10" height="10" fill="none" stroke="#cccccc" stroke-width="1"/>',
            f'<path d="M{width - 26} 12 l10 10 M{width - 16} 12 l-10 10" stroke="#cccccc" stroke-width="1"/>']


MAC_THEME = {  # One Dark-like colors for macOS Terminal
    "palette": {"bg": "#1e1f22", "bar": "#2b2d31", "fg": "#d7dae0", "bold": "#ffffff", "dim": "#7f848e",
                "prompt": "#98c379",
                "ansi": {31: "#e06c75", 32: "#98c379", 33: "#e5c07b", 36: "#56b6c2", 90: "#7f848e"}},
    "radius": 10, "chrome": mac_chrome, "prompt_prefix": "~ $ ",
    "aria": "Example medic output on macOS, with sample data",
}
WIN_THEME = {  # Windows Terminal "Campbell" colors
    "palette": {"bg": "#0c0c0c", "bar": "#202020", "fg": "#cccccc", "bold": "#cccccc", "dim": "#767676",
                "prompt": "#cccccc",
                "ansi": {31: "#c50f1f", 32: "#13a10e", 33: "#c19c00", 36: "#3a96dd", 37: "#cccccc",
                         90: "#767676", 91: "#e74856", 92: "#16c60c", 93: "#f9f1a5", 96: "#61d6d6", 97: "#f2f2f2"}},
    "radius": 8, "chrome": win_chrome, "prompt_prefix": "PS C:\\Users\\alex> ",
    "aria": "Example medic output on Windows, with sample data",
}


if __name__ == "__main__":
    render("screenshot-macos.svg", "medic --quick", parse_ansi(mac_output()), MAC_THEME)
    render("screenshot-windows.svg", "medic -Quick", parse_ansi(windows_output()), WIN_THEME)
