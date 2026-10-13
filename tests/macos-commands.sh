#!/usr/bin/env bash
# Runs the medic commands in a throwaway HOME: JSON output parses, exit codes
# follow the contract, clean --yes only touches what --only picks, and purge
# only deletes dependency folders of inactive projects, never through a symlink.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
home="$root/home"
medic="$root/medic"
(cd "$repo" && go build -o "$medic" ./cmd/medic)

fail() { echo "FAIL: $*"; exit 1; }
blob() { mkdir -p "$(dirname "$1")" && head -c 2000000 /dev/urandom >"$1"; }
run() { HOME="$home" "$medic" --no-color "$@" </dev/null; }
json() { python3 -c 'import json, sys; json.load(sys.stdin)' || fail "medic $* did not print valid JSON"; }

blob "$home/Library/Caches/app/blob"
blob "$home/Library/Logs/app.log"
blob "$home/dev/old-web/node_modules/pkg/index.js"
echo '{}' >"$home/dev/old-web/package.json"
blob "$home/dev/new-web/node_modules/pkg/index.js"
echo '{}' >"$home/dev/new-web/package.json"
blob "$home/dev/old-rust/target/debug/app"
touch "$home/dev/old-rust/Cargo.toml"
blob "$home/dev/no-marker/node_modules/pkg/index.js"
mkdir -p "$root/outside" && echo keep >"$root/outside/keep.txt"
ln -s "$root/outside" "$home/dev/old-rust/build"
ln -s "$root/outside" "$home/dev/old-web/node_modules/linked"
touch -t 202401010000 "$home/dev/old-web/package.json" "$home/dev/old-rust/Cargo.toml"

for cmd in "report --quick" disk memory "purge" "check --min-free 1M"; do
  # shellcheck disable=SC2086 # split the command and its options
  run $cmd --json | json "$cmd"
done

folders=$(run purge --json | python3 -c 'import json, sys; print(" ".join(sorted(f["kind"] for f in json.load(sys.stdin)["purge"]["folders"])))')
[ "$folders" = "Rust build node_modules" ] || fail "purge --json listed '$folders' instead of the two inactive projects"

run check --min-free 1M >/dev/null || fail "check failed with a 1 MB minimum"
if run check --min-free 100% >/dev/null; then fail "check passed with a 100% minimum"; fi
for bad in "bogus" "--yes" "clean --json" "check --min-free lots" "purge --only safe" "--large"; do
  set +e
  # shellcheck disable=SC2086 # split the command and its options
  run $bad >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "medic $bad exited with $status instead of 2"
done
if run clean >/dev/null 2>&1; then fail "clean without a terminal or --yes did not fail"; fi

run clean --dry-run --yes --only user_logs >/dev/null
[ -f "$home/Library/Logs/app.log" ] || fail "clean --dry-run deleted a file"
run clean --yes --only user_logs >/dev/null
[ ! -e "$home/Library/Logs/app.log" ] || fail "clean --yes --only user_logs did not clean the logs"
[ -f "$home/Library/Caches/app/blob" ] || fail "clean --only user_logs also cleaned the caches"

run purge --yes >/dev/null
[ ! -e "$home/dev/old-web/node_modules" ] || fail "purge kept node_modules of an inactive project"
[ ! -e "$home/dev/old-rust/target" ] || fail "purge kept target of an inactive Rust project"
[ -d "$home/dev/new-web/node_modules" ] || fail "purge deleted node_modules of an active project"
[ -d "$home/dev/no-marker/node_modules" ] || fail "purge deleted node_modules without a package.json"
[ -f "$root/outside/keep.txt" ] || fail "purge followed a symlink"
[ -f "$home/dev/old-web/package.json" ] || fail "purge deleted project files"

run purge --yes --older-than 0 >/dev/null
[ ! -e "$home/dev/new-web/node_modules" ] || fail "purge --older-than 0 kept node_modules of an active project"

echo "OK: JSON parses, exit codes match, clean and purge only touch what they should"
