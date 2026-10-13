#!/usr/bin/env bash
# Builds the release files: medic for macOS and Windows on Apple silicon/ARM
# and Intel, the installers, and the SHA256SUMS file the installers check.
# Used by the release workflow and by CI.
#
# Usage: tools/dist.sh OUTDIR [VERSION]
set -euo pipefail

out=${1:?usage: tools/dist.sh OUTDIR [VERSION]}
version=${2:-dev}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for target in macos/arm64 macos/amd64 windows/amd64 windows/arm64; do
  os=${target%/*} arch=${target#*/}
  goos=$os bin=medic
  [ "$os" = macos ] && goos=darwin
  [ "$os" = windows ] && bin=medic.exe
  dir="$work/medic_${os}_${arch}"
  mkdir -p "$dir"
  (cd "$root" && CGO_ENABLED=0 GOOS=$goos GOARCH=$arch \
    go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$dir/$bin" ./cmd/medic)
  cp "$root/LICENSE" "$root/README.md" "$dir/"
  if [ "$os" = windows ]; then
    (cd "$dir" && zip -q -X "$out/medic_${os}_${arch}.zip" "$bin" LICENSE README.md)
  else
    tar -C "$dir" -czf "$out/medic_${os}_${arch}.tar.gz" "$bin" LICENSE README.md
  fi
done
cp "$root/install.sh" "$root/install.ps1" "$out/"

cd "$out"
files=(medic_*.tar.gz medic_*.zip install.sh install.ps1)
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${files[@]}" >SHA256SUMS
else
  shasum -a 256 "${files[@]}" >SHA256SUMS
fi
