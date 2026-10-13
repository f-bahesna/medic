#!/usr/bin/env bash
# Collects the release files into one folder, with the SHA256SUMS file the
# installers check. Used by the release workflow and by the install tests.
set -euo pipefail

out=${1:?usage: tools/dist.sh OUTDIR}
root=$(cd "$(dirname "$0")/.." && pwd)
files=(medic.sh medic.ps1 install.sh install.ps1)

mkdir -p "$out"
cp "$root/macos/medic.sh" "$root/windows/medic.ps1" "$root/install.sh" "$root/install.ps1" "$out/"
cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${files[@]}" >SHA256SUMS
else
  shasum -a 256 "${files[@]}" >SHA256SUMS
fi
