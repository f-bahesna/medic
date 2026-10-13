#!/usr/bin/env bash
# Installs medic the way the README tells people to (piped into bash), in a
# throwaway HOME, from release files built by tools/dist.sh. Then checks that
# a new zsh finds "medic" from any folder, that a tampered download is refused,
# that an install of the script medic was before 0.5 is replaced, and that
# --uninstall works. Pass a folder of release files to test those instead.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
home="$root/home"
mkdir -p "$home"
if [ -n "${1:-}" ]; then
  dist=$(cd "$1" && pwd)
else
  dist="$root/dist"
  "$repo/tools/dist.sh" "$dist" >/dev/null
fi

fail() { echo "FAIL: $*"; exit 1; }
# A clean login environment, as a new Terminal window would have it.
in_home() { env -i HOME="$home" SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$root" "$@"; }

# An install from before 0.5: the script, linked from a checkout.
mkdir -p "$home/.local/bin" "$root/old"
printf '#!/usr/bin/env bash\n#\n# medic for macOS - old script\n' >"$root/old/medic.sh"
ln -s "$root/old/medic.sh" "$home/.local/bin/medic"

in_home bash -s -- --from "$dist" <"$repo/install.sh" >"$root/out" || { cat "$root/out"; fail "install failed"; }
[ ! -L "$home/.local/bin/medic" ] || fail "the old linked script was not replaced"
[ -f "$root/old/medic.sh" ] || fail "the old script itself was deleted"
[ -x "$home/.local/bin/medic" ] || fail "medic not installed into ~/.local/bin"
# shellcheck disable=SC2016 # the literal line the installer writes
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$home/.zshrc" || fail "PATH line not added to ~/.zshrc"

version=$(in_home zsh -c 'source ~/.zshrc; cd /; medic --version')
case "$version" in "medic "*) ;; *) fail "medic --version from / printed '$version'" ;; esac
report=$(in_home zsh -c 'source ~/.zshrc; cd /; medic --quick --no-color')
grep -q 'Run medic clean' <<<"$report" || fail "the report does not tell people to run 'medic clean'"

in_home bash "$repo/install.sh" --from "$dist" >/dev/null || fail "reinstall failed"
[ "$(grep -c 'Added by the medic installer' "$home/.zshrc")" -eq 1 ] || fail "PATH line added twice"

cp -R "$dist" "$root/tampered"
for f in "$root"/tampered/medic_macos_*.tar.gz; do echo pwned >>"$f"; done
if in_home bash "$repo/install.sh" --from "$root/tampered" --dir "$root/other" 2>"$root/err"; then
  fail "a tampered download was installed"
fi
grep -q 'checksum mismatch' "$root/err" || fail "unexpected error for a tampered download: $(cat "$root/err")"
[ ! -e "$root/other/medic" ] || fail "a tampered download was written"

echo '#!/bin/sh' >"$root/not-medic"
mkdir -p "$root/taken" && cp "$root/not-medic" "$root/taken/medic"
if in_home bash "$repo/install.sh" --from "$dist" --dir "$root/taken" 2>/dev/null; then
  fail "an unrelated 'medic' command was overwritten"
fi
cmp -s "$root/not-medic" "$root/taken/medic" || fail "an unrelated 'medic' command was changed"

in_home bash "$repo/install.sh" --uninstall >/dev/null || fail "uninstall failed"
[ ! -e "$home/.local/bin/medic" ] && [ ! -L "$home/.local/bin/medic" ] || fail "medic still installed after --uninstall"

echo "OK: installed from a pipe over an old install, runs from any folder, refuses tampered files, uninstalls"
