#!/usr/bin/env bash
# Draws the README screenshots of Medic.app, like the other README
# screenshots, from the real code with sample data. Runs on macOS with Swift.
#
#   docs/screenshot-menubar.png  the menu, from Medic.app's real menu views
#   docs/screenshot-dmg.png      the window Medic.dmg opens in
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# One module: the views without their import of the core, and the script as main.
sed '/^import MedicBarCore/d' "$root/macos/Sources/MedicBar/Views.swift" >"$work/Views.swift"
cp "$root/macos/Art/screenshot.swift" "$work/main.swift"
swiftc -o "$work/shot" -module-name Shot "$root"/macos/Sources/MedicBarCore/*.swift "$work/Views.swift" "$work/main.swift"
"$work/shot" "$root/docs"
# As released: not notarized, so the DMG window says how to open Medic.
swift "$root/macos/Art/draw.swift" "$work/art" --unsigned
swift "$root/macos/Art/dmg-screenshot.swift" "$work/art" "$root/docs"
