#!/usr/bin/env bash
# Draws docs/screenshot-menubar.png from Medic.app's real menu views, with
# sample data, like the other README screenshots. Runs on macOS with Swift.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# One module: the views without their import of the core, and the script as main.
sed '/^import MedicBarCore/d' "$root/macos/Sources/MedicBar/Views.swift" >"$work/Views.swift"
cp "$root/macos/Art/screenshot.swift" "$work/main.swift"
swiftc -o "$work/shot" -module-name Shot "$root"/macos/Sources/MedicBarCore/*.swift "$work/Views.swift" "$work/main.swift"
"$work/shot" "$root/docs"
