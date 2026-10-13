#!/usr/bin/env bash
# Uninstalls a made-up app from a throwaway HOME the way a person would: review
# the list, pick, confirm. Checks that only the app's own data is listed (not
# that of another app with a longer bundle id), that nothing moves before the
# confirmation, and that the picked parts end up in the Trash, nothing else.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
home="$root/home"
medic="$root/medic"
(cd "$repo" && go build -o "$medic" ./cmd/medic)

fail() { echo "FAIL: $*"; exit 1; }
blob() { mkdir -p "$(dirname "$1")" && head -c 1000000 /dev/urandom >"$1"; }
app() { # app NAME BUNDLE_ID
  mkdir -p "$home/Applications/$1.app/Contents/MacOS"
  cat >"$home/Applications/$1.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
</dict></plist>
EOF
  blob "$home/Applications/$1.app/Contents/MacOS/$1"
}
run() { HOME="$home" "$medic" --no-color "$@" </dev/null; }
L="$home/Library"

app MedicTestApp com.example.medictest
app "MedicTestApp Pro" com.example.medictest.pro
blob "$L/Application Support/com.example.medictest/data"
blob "$L/Caches/MedicTestApp/cache"
blob "$L/Containers/com.example.medictest.helper/data"
blob "$L/Preferences/com.example.medictest.plist"
blob "$L/Preferences/com.example.medictest.pro.plist"
blob "$L/Application Support/Unrelated/data"

run apps --json | python3 -c '
import json, sys
names = {a["name"]: a for a in json.load(sys.stdin)["apps"]}
assert names["MedicTestApp"]["id"] == "com.example.medictest", names
assert names["MedicTestApp"]["version"] == "1.2.3", names
' || fail "medic apps --json does not list the test apps"

review=$(run uninstall medictestapp --dry-run)
for want in "MedicTestApp.app" "Application Support/com.example.medictest" "Caches/MedicTestApp" \
  "Containers/com.example.medictest.helper" "Preferences/com.example.medictest.plist"; do
  grep -qF "$want" <<<"$review" || fail "the review does not list $want:
$review"
done
grep -qF "medictest.pro" <<<"$review" && fail "the review lists data of the other app:
$review"
grep -qF "Unrelated" <<<"$review" && fail "the review lists an unrelated folder"

set +e
run uninstall MedicTest --dry-run >/dev/null; several=$?
run uninstall NoSuchApp >/dev/null; missing=$?
run uninstall >/dev/null 2>&1; noname=$?
run uninstall MedicTestApp --yes >/dev/null 2>&1; yes=$?
set -e
[ "$several" -eq 1 ] || fail "several matching apps exited with $several, want 1"
[ "$missing" -eq 1 ] || fail "an unknown app exited with $missing, want 1"
[ "$noname" -eq 2 ] || fail "uninstall without a name exited with $noname, want 2"
[ "$yes" -eq 2 ] || fail "uninstall --yes exited with $yes, want 2"

# answer PICK CONFIRM - run "medic uninstall MedicTestApp" in a terminal and
# answer its two questions. An empty PICK cancels at the list.
answer() {
  cat >"$root/answer.exp" <<'EOF'
set timeout 30
lassign $argv medic pick confirm
spawn $medic uninstall MedicTestApp --no-color
expect -ex "Which ones?" { send "$pick\r" } timeout { exit 2 }
if {$pick eq ""} {
  expect -ex "Nothing cleaned up." {} timeout { exit 3 }
} else {
  expect -ex {[y/N]} { send "$confirm\r" } timeout { exit 4 }
  if {$confirm eq "y"} { expect -ex "Moved 2 item(s) to the Trash." {} timeout { exit 5 } }
}
expect eof
catch wait result
exit [lindex $result 3]
EOF
  HOME="$home" expect "$root/answer.exp" "$medic" "$1" "$2" >"$root/out" 2>&1 ||
    { cat "$root/out"; fail "the review did not go as expected for '$1' '$2'"; }
}

# Cancel at the list, then say no at the confirmation: nothing moves.
answer "" ""
answer "1,2" "n"
[ -d "$home/Applications/MedicTestApp.app" ] || fail "the app moved without a yes"

# Pick the app and its Application Support folder, and confirm.
answer "1,2" "y"

[ -d "$home/.Trash/MedicTestApp.app" ] || fail "the app is not in the Trash"
[ -d "$home/.Trash/com.example.medictest" ] || fail "its Application Support folder is not in the Trash"
[ ! -e "$home/Applications/MedicTestApp.app" ] || fail "the app is still installed"
for keep in "Caches/MedicTestApp" "Containers/com.example.medictest.helper" \
  "Preferences/com.example.medictest.plist" "Preferences/com.example.medictest.pro.plist" "Application Support/Unrelated"; do
  [ -e "$L/$keep" ] || fail "$keep was not picked but is gone"
done
[ -d "$home/Applications/MedicTestApp Pro.app" ] || fail "the other app is gone"

echo "OK: reviews only the app's own data, asks first, moves only what was picked to the Trash"
