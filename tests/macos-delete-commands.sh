#!/usr/bin/env bash
# Runs a "Delete commands" line that medic prints, in a throwaway HOME and
# in zsh (the default macOS shell), and checks that it empties the cache without
# touching what a symlink inside it points to.
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
home="$root/home"
mkdir -p "$home/Library/Caches/app/sub" "$root/outside"
head -c 2000000 /dev/urandom >"$home/Library/Caches/app/sub/blob"
echo keep >"$root/outside/keep.txt"
ln -s "$root/outside" "$home/Library/Caches/link"

script="$(cd "$(dirname "$0")/.." && pwd)/macos/medic.sh"
# Read the whole report first: grep -m1 on a pipe would stop the script early (SIGPIPE).
report=$(HOME="$home" /bin/bash "$script" --quick --no-color)
# shellcheck disable=SC2016 # the literal text medic prints
cmd=$(grep -m1 -F 'rm -rf "$HOME/Library/Caches"/*' <<<"$report" | sed 's/^ *//')
[ -n "$cmd" ] || { echo "FAIL: no delete command printed for the cache"; exit 1; }
echo "running: $cmd"

HOME="$home" zsh -c "$cmd"
[ -z "$(ls -A "$home/Library/Caches")" ] || { echo "FAIL: cache not emptied"; exit 1; }
[ -f "$root/outside/keep.txt" ] || { echo "FAIL: symlink target was deleted"; exit 1; }
echo "OK: cache emptied, symlink target kept"
