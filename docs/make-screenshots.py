"""Draw the README screenshots from medic's real rendering, with made-up data.

tools/screenshot prints the report the way medic does, using the real lists of
locations, with sample sizes and system data. This turns its colored output
into SVG. Run from anywhere with Go installed:

    python3 docs/make-screenshots.py
"""
import os
import re
import subprocess
from xml.sax.saxutils import escape

DOCS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DOCS)

FONT = 13
LINE = 18
CHAR = 8.0      # advance width of a 13px monospace glyph, with a little slack
PAD_X = 20
MAX_COLS = 124  # longer lines wrap, like they would in a terminal window


def sample_output(system):
    return subprocess.run(["go", "run", "./tools/screenshot", system], cwd=ROOT,
                          stdout=subprocess.PIPE, check=True).stdout.decode()


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
    render("screenshot-macos.svg", "medic --quick", parse_ansi(sample_output("macos")), MAC_THEME)
    render("screenshot-windows.svg", "medic --quick", parse_ansi(sample_output("windows")), WIN_THEME)
