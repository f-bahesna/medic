#!/usr/bin/env bash
# Builds Medic.dmg: the Medic menu bar app with the medic command line tool
# inside, for Apple silicon and Intel in one file. Runs on macOS with Swift
# (Xcode or the Command Line Tools) and Go.
#
# Usage: tools/macapp.sh OUTDIR [VERSION]
#
# VERSION defaults to the checkout's tag, like 0.6.0, or 0.6.0-3-gabc1234 a
# few commits after it, so a local build says which version it is.
#
# Signing: with MEDIC_SIGN_IDENTITY set to a "Developer ID Application"
# identity in the keychain, the app and DMG are signed with it. With
# APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD also set, the DMG is
# notarized and stapled, and opens without any warning. Without them, the app
# is signed ad hoc, and the first open needs Open Anyway in System Settings.
#
# When OUTDIR has a SHA256SUMS, the DMG's line is added to it.
set -euo pipefail

out=${1:?usage: tools/macapp.sh OUTDIR [VERSION]}
root=$(cd "$(dirname "$0")/.." && pwd)
version=${2:-$(git -C "$root" describe --tags --dirty --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')}
version=${version:-dev}
identity=${MEDIC_SIGN_IDENTITY:-}
[ "$(uname -s)" = Darwin ] || { echo "tools/macapp.sh: builds on macOS only" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Info.plist versions must be numbers: 0.6.0-3-gabc1234 is 0.6.0 there.
bundle_version=0.0.0
[[ "$version" =~ ^[0-9]+(\.[0-9]+)* ]] && bundle_version=${BASH_REMATCH[0]}

app="$work/Medic.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
sed "s/@VERSION@/$bundle_version/g" "$root/macos/Resources/Info.plist" >"$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"

echo "Building the medic command line tool"
for arch in arm64 amd64; do
  (cd "$root" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch \
    go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$work/medic-$arch" ./cmd/medic)
done
lipo -create -output "$app/Contents/Helpers/medic" "$work/medic-arm64" "$work/medic-amd64"

echo "Building the menu bar app"
for arch in arm64 x86_64; do
  swift build --package-path "$root/macos" -c release --triple "$arch-apple-macosx11.0" --product MedicBar
done
lipo -create -output "$app/Contents/MacOS/Medic" \
  "$root/macos/.build/arm64-apple-macosx/release/MedicBar" \
  "$root/macos/.build/x86_64-apple-macosx/release/MedicBar"

echo "Drawing the icon and the DMG window"
art_flags=()
[ -n "$identity" ] && [ -n "${APPLE_ID:-}" ] || art_flags=(--unsigned)
swift "$root/macos/Art/draw.swift" "$work/art" ${art_flags[@]+"${art_flags[@]}"}
iconutil -c icns -o "$app/Contents/Resources/Medic.icns" "$work/art/Medic.iconset"
tiffutil -cathidpicheck "$work/art/background.png" "$work/art/background@2x.png" -out "$work/art/background.tiff" >/dev/null

echo "Signing"
# Inside out: the tool first, then the app that seals it.
if [ -n "$identity" ]; then
  sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
  sign=(codesign --force --sign -)
fi
"${sign[@]}" --identifier io.github.f-bahesna.medic.cli "$app/Contents/Helpers/medic"
"${sign[@]}" "$app"
codesign --verify --strict --deep "$app"
"$app/Contents/Helpers/medic" --version

echo "Making the DMG"
# The system Python, which every Mac with developer tools has.
/usr/bin/python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.5
dmg="$out/Medic.dmg"
rm -f "$dmg"
"$work/venv/bin/dmgbuild" -s "$root/macos/Resources/dmg-settings.py" \
  -D app="$app" -D background="$work/art/background.tiff" Medic "$dmg"

if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
  if [ -n "${APPLE_ID:-}" ]; then
    echo "Notarizing"
    xcrun notarytool submit "$dmg" --wait \
      --apple-id "$APPLE_ID" --team-id "${APPLE_TEAM_ID:?}" --password "${APPLE_APP_PASSWORD:?}"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
  fi
fi

if [ -f "$out/SHA256SUMS" ]; then
  (cd "$out" && grep -v ' Medic\.dmg$' SHA256SUMS >"$work/sums" || true)
  (cd "$out" && shasum -a 256 Medic.dmg >>"$work/sums" && mv "$work/sums" SHA256SUMS)
fi
echo "Built $dmg"
