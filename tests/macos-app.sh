#!/usr/bin/env bash
# Installs Medic.app from the DMG the way people do: a downloaded (so
# quarantined) DMG, opened, the app copied out of it. Then checks the bundle,
# that the medic command inside it runs, and that the app starts, stays up in
# the menu bar and clears the quarantine flag of its own command line tool.
# Pass a folder with Medic.dmg (from tools/macapp.sh) to test that instead.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
mnt="$root/mnt"
pid=""
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  hdiutil detach -quiet "$mnt" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT
if [ -n "${1:-}" ]; then
  dist=$(cd "$1" && pwd)
else
  dist="$root/dist"
  "$repo/tools/macapp.sh" "$dist" >/dev/null
fi

fail() { echo "FAIL: $*"; exit 1; }

# As a browser leaves a download.
cp "$dist/Medic.dmg" "$root/Medic.dmg"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$root/Medic.dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$root/Medic.dmg"
[ -d "$mnt/Medic.app" ] || fail "the DMG has no Medic.app"
[ "$(readlink "$mnt/Applications")" = /Applications ] || fail "the DMG has no link to Applications to drag onto"
[ -f "$mnt/.DS_Store" ] && [ -f "$mnt/.background.tiff" ] || fail "the DMG window has no layout or background"

mkdir -p "$root/Applications"
ditto "$mnt/Medic.app" "$root/Applications/Medic.app"
app="$root/Applications/Medic.app"
cli="$app/Contents/Helpers/medic"

codesign --verify --strict --deep "$app" || fail "Medic.app's signature does not verify"
for bin in "$app/Contents/MacOS/Medic" "$cli"; do
  archs=$(lipo -archs "$bin")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$(basename "$bin") is not for Apple silicon and Intel: $archs"
done
plist="$app/Contents/Info.plist"
[ "$(plutil -extract LSUIElement raw "$plist")" = true ] || fail "Medic shows a Dock icon, it should live in the menu bar only"
[ "$(plutil -extract LSMinimumSystemVersion raw "$plist")" = 11.0 ] || fail "Medic should run on macOS 11 like medic"
[ -f "$app/Contents/Resources/$(plutil -extract CFBundleIconFile raw "$plist").icns" ] || fail "Medic.app has no icon"

# macOS kills a quarantined program that Apple has not notarized as soon as
# it runs from a shell, which is why Medic clears the flag of its own copy.
[ -n "$(xattr -p com.apple.quarantine "$cli" 2>/dev/null)" ] || fail "the test needs a quarantined copy to start from"
# Opening the app is when the person says they trust it (Open Anyway for an
# app signed ad hoc). This stands in for that, for everything but the tool.
find "$app" -path "$cli" -prune -o -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
"$app/Contents/MacOS/Medic" &
pid=$!
sleep 4
kill -0 "$pid" 2>/dev/null || fail "Medic quit or crashed right after starting"
if xattr -p com.apple.quarantine "$cli" >/dev/null 2>&1; then
  fail "Medic did not clear the quarantine flag of its medic command"
fi
kill "$pid"
wait "$pid" 2>/dev/null || true
pid=""

version=$("$cli" --version) || fail "the bundled medic does not run after Medic was opened"
case "$version" in "medic "*) ;; *) fail "the bundled medic --version printed '$version'" ;; esac
"$cli" memory --json | python3 -c 'import json, sys; m = json.load(sys.stdin)["memory"]; assert m["total_bytes"] > 0' ||
  fail "the bundled medic memory --json is not valid"

echo "PASS: Medic.app installs from the DMG, its medic command runs, and it starts in the menu bar"
