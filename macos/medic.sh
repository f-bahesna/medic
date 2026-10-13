#!/usr/bin/env bash
#
# medic for macOS - find out what is filling up your Mac and what is safe to clean.
# The Windows version lives in windows/medic.ps1.
#
# Read-only by default: nothing is deleted unless you pass --clean and
# confirm every single item. Only SAFE and CAUTION items can ever be cleaned.
# REVIEW items (your personal data) are reported, never touched.
#
# Runs on the stock macOS bash 3.2, no dependencies.
#
# License: MIT

set -o pipefail

VERSION="0.3.0"

QUICK=0
CLEAN=0
DRY_RUN=0
LARGE_MB=500
USE_COLOR=1
DEV_DIRS=()

# How to run medic again: "medic" when it is installed on PATH, otherwise the
# way it was started (bash macos/medic.sh).
PROG="bash $0"
[ "$(command -v "${0##*/}" 2>/dev/null)" = "$0" ] && PROG=${0##*/}

usage() {
  cat <<EOF
medic $VERSION (macOS) - see what is filling up your Mac and what is safe to clean.

Usage: $PROG [options]

Options:
  --clean          Clean SAFE and CAUTION items, asking before each one
  --dry-run        Like --clean, but only shows what would be done
  --quick          Skip the slow scans (large files, dev projects, breakdowns)
  --large MB       Report files bigger than MB megabytes (default: $LARGE_MB)
  --dev-dir DIR    Extra folder to scan for node_modules and venvs (repeatable)
  --no-color       Disable colored output (NO_COLOR is honored too)
  -h, --help       Show this help
  -v, --version    Show version

Safety levels:
  SAFE       Regenerated automatically. No data loss.
  CAUTION    Regenerable, but you lose more than a cache (stopped containers,
             locally installed artifacts) or it costs a long rebuild.
  REVIEW     May contain personal data. Reported only, never deleted.
EOF
}

die() {
  printf 'medic: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --clean) CLEAN=1 ;;
    --dry-run) CLEAN=1; DRY_RUN=1 ;;
    --quick) QUICK=1 ;;
    --large)
      shift
      case "$1" in '' | *[!0-9]*) die "--large needs a number of megabytes" ;; esac
      LARGE_MB=$1
      ;;
    --dev-dir)
      shift
      [ -d "$1" ] || die "--dev-dir: '$1' is not a directory"
      DEV_DIRS+=("$1")
      ;;
    --no-color) USE_COLOR=0 ;;
    -h | --help) usage; exit 0 ;;
    -v | --version) echo "medic $VERSION"; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "this is the macOS version. On Windows, run windows/medic.ps1 from PowerShell instead"
[ "$(id -u)" -ne 0 ] || die "do not run with sudo; medic only looks at your own user files"
if [ -z "$HOME" ] || [ "$HOME" = "/" ] || [ ! -d "$HOME" ]; then
  die "HOME is not set to a valid directory"
fi

if [ "$USE_COLOR" -eq 1 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' CYN=$'\033[36m' N=$'\033[0m'
else
  B='' D='' RED='' GRN='' YEL='' CYN='' N=''
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/medic.XXXXXX") || die "cannot create a temp directory"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has() { command -v "$1" >/dev/null 2>&1; }

# human KB [bin] - format kilobytes. Disk sizes use decimal units like Finder
# does; pass "bin" for RAM, which macOS reports in binary units.
human() {
  awk -v k="${1:-0}" -v mode="${2:-dec}" 'BEGIN {
    split("KB MB GB TB", u, " ")
    if (mode == "bin") { base = 1024; v = k } else { base = 1000; v = k * 1.024 }
    i = 1
    while (v >= base && i < 4) { v /= base; i++ }
    if (i <= 2) printf "%.0f %s", v, u[i]; else printf "%.1f %s", v, u[i]
  }'
}

tilde() {
  case "$1" in
    "$HOME"*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

path_kb() { du -sk "$1" 2>/dev/null | awk 'END { print $1 + 0 }'; }

progress() { [ -t 2 ] && printf '\r\033[K%s  scanning %s ...%s' "$D" "$1" "$N" >&2; }
progress_done() { [ -t 2 ] && printf '\r\033[K' >&2; }

section() { printf '\n%s%s%s\n%s%s%s\n' "$B$CYN" "$1" "$N" "$D" "------------------------------------------------------------" "$N"; }
warn() { printf '  %s! %s%s\n' "$YEL" "$*" "$N"; }
note() { printf '  %s%s%s\n' "$D" "$*" "$N"; }

# bar PERCENT - a 30 column usage bar, colored by how full it is.
bar() {
  local pct=$1 filled color
  filled=$((pct * 30 / 100))
  if [ "$pct" -ge 90 ]; then color=$RED; elif [ "$pct" -ge 75 ]; then color=$YEL; else color=$GRN; fi
  printf '%s[' "$color"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' $((30 - filled)) '' | tr ' ' '.'
  printf ']%s' "$N"
}

badge() {
  case "$1" in
    SAFE) printf '%s%-7s%s' "$GRN" SAFE "$N" ;;
    CAUTION) printf '%s%-7s%s' "$YEL" CAUTION "$N" ;;
    REVIEW) printf '%s%-7s%s' "$RED" REVIEW "$N" ;;
  esac
}

# ---------------------------------------------------------------------------
# Disk overview
# ---------------------------------------------------------------------------

show_disk() {
  local total avail system data used other pct
  read -r total system avail <<<"$(df -k / | awk 'NR == 2 { print $2, $3, $4 }')"
  data=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $3 + 0 }')
  used=$((total - avail))
  pct=$((used * 100 / total))
  other=$((used - system - ${data:-0}))
  [ "$other" -lt 0 ] && other=0

  section "Disk"
  printf '  %-22s %s\n' "Capacity" "$(human "$total")"
  printf '  %-22s %-10s %s %s%%\n' "Used" "$(human "$used")" "$(bar "$pct")" "$pct"
  printf '  %-22s %s%s%s\n' "Free" "$B" "$(human "$avail")" "$N"
  printf '  %-22s %s\n' "  macOS (read-only)" "$(human "$system")"
  printf '  %-22s %s\n' "  Your data volume" "$(human "${data:-0}")"
  printf '  %-22s %s %s\n' "  Other volumes" "$(human "$other")" "${D}(swap, recovery, updates)${N}"
  note "Finder may show more free space: it also counts 'purgeable' space macOS can free on its own."
  if [ "$pct" -ge 90 ]; then
    warn "Disk is almost full. macOS slows down and updates fail below ~10% free."
  fi
}

# ---------------------------------------------------------------------------
# Memory (RAM) overview
# ---------------------------------------------------------------------------

vm_pages() { printf '%s\n' "$1" | awk -F: -v k="$2" '$1 == k { gsub(/[^0-9]/, "", $2); print $2 + 0 }'; }

show_memory() {
  local vm page total_kb free wired comp purg file anon app used cached pct level free_pct swap_used swap_total
  vm=$(vm_stat)
  page=$(printf '%s\n' "$vm" | awk '/page size of/ { print $8 }')
  page=${page:-16384}
  total_kb=$(($(sysctl -n hw.memsize) / 1024))
  wired=$(($(vm_pages "$vm" "Pages wired down") * page / 1024))
  comp=$(($(vm_pages "$vm" "Pages occupied by compressor") * page / 1024))
  purg=$(($(vm_pages "$vm" "Pages purgeable") * page / 1024))
  file=$(($(vm_pages "$vm" "File-backed pages") * page / 1024))
  anon=$(($(vm_pages "$vm" "Anonymous pages") * page / 1024))
  free=$(($(vm_pages "$vm" "Pages free") * page / 1024))
  app=$((anon - purg))
  [ "$app" -lt 0 ] && app=0
  used=$((app + wired + comp))
  cached=$((file + purg))
  pct=$((used * 100 / total_kb))

  level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  free_pct=$(memory_pressure -Q 2>/dev/null | awk -F: '/free percentage/ { gsub(/[ %]/, "", $2); print $2 }')
  read -r swap_total swap_used <<<"$(sysctl -n vm.swapusage 2>/dev/null |
    awk '{ t = $3; u = $6; sub(/M/, "", t); sub(/M/, "", u); printf "%d %d", t * 1024, u * 1024 }')"

  section "Memory (RAM)"
  printf '  %-22s %s\n' "Physical memory" "$(human "$total_kb" bin)"
  printf '  %-22s %-10s %s %s%%\n' "Used" "$(human "$used" bin)" "$(bar "$pct")" "$pct"
  printf '  %-22s %s\n' "  App memory" "$(human "$app" bin)"
  printf '  %-22s %s %s\n' "  Wired" "$(human "$wired" bin)" "${D}(kernel, cannot be freed)${N}"
  printf '  %-22s %s\n' "  Compressed" "$(human "$comp" bin)"
  printf '  %-22s %s %s\n' "Cached files" "$(human "$cached" bin)" "${D}(freed instantly when apps need it)${N}"
  printf '  %-22s %s\n' "Free" "$(human "$free" bin)"
  printf '  %-22s %s of %s\n' "Swap used" "$(human "${swap_used:-0}" bin)" "$(human "${swap_total:-0}" bin)"

  case "$level" in
    1) printf '  %-22s %sNormal%s' "Memory pressure" "$GRN" "$N" ;;
    2) printf '  %-22s %sWarning%s' "Memory pressure" "$YEL" "$N" ;;
    4) printf '  %-22s %sCritical%s' "Memory pressure" "$RED" "$N" ;;
    *) printf '  %-22s unknown' "Memory pressure" ;;
  esac
  [ -n "$free_pct" ] && printf ' %s(%s%% available)%s' "$D" "$free_pct" "$N"
  printf '\n'

  printf '\n  %sTop apps by memory%s %s(resident memory, approximate)%s\n' "$B" "$N" "$D" "$N"
  # Group helper processes under their app: everything inside "Foo.app/" counts as Foo.
  ps -axo rss=,comm= | awk '{
    rss = $1; $1 = ""; sub(/^ +/, ""); p = $0
    if (match(p, /[^\/]+\.app\//)) name = substr(p, RSTART, RLENGTH - 5)
    else { n = split(p, a, "/"); name = a[n] }
    sum[name] += rss; cnt[name]++
  } END { for (k in sum) printf "%d\t%d\t%s\n", sum[k], cnt[k], k }' |
    sort -nr | head -8 |
    while IFS=$'\t' read -r kb count name; do
      if [ "$count" -gt 1 ]; then
        printf '    %-10s %s %s(%s processes)%s\n' "$(human "$kb" bin)" "$name" "$D" "$count" "$N"
      else
        printf '    %-10s %s\n' "$(human "$kb" bin)" "$name"
      fi
    done

  if [ "$level" = "2" ] || [ "$level" = "4" ]; then
    warn "Your Mac is short on memory. Quit apps at the top of this list, or restart to clear swap."
  else
    note "High 'used' memory is normal on macOS. Only memory pressure tells you if RAM is a problem."
  fi
}

# ---------------------------------------------------------------------------
# Space hogs
# ---------------------------------------------------------------------------

ITEM_ID=()
ITEM_SAFETY=()
ITEM_LABEL=()
ITEM_NOTE=()
ITEM_CLEAN=()
ITEM_PATHS=()
ITEM_KB=()

# add_item ID SAFETY LABEL NOTE CLEANABLE PATH...
add_item() {
  local id=$1 safety=$2 label=$3 item_note=$4 clean=$5 joined="" p
  shift 5
  for p in "$@"; do joined="${joined:+$joined:}$p"; done
  ITEM_ID+=("$id")
  ITEM_SAFETY+=("$safety")
  ITEM_LABEL+=("$label")
  ITEM_NOTE+=("$item_note")
  ITEM_CLEAN+=("$clean")
  ITEM_PATHS+=("$joined")
  ITEM_KB+=("")
}

yes_if_has() { has "$1" && echo yes; }

collect_items() {
  local L="$HOME/Library" AS="$HOME/Library/Application Support" lib conda_pkgs=()

  add_item user_caches SAFE "User app caches" \
    "Apps rebuild these on demand. Quit apps before cleaning." yes "$L/Caches"
  add_item user_logs SAFE "User logs" \
    "Diagnostic logs, only useful when debugging a problem." yes "$L/Logs"
  add_item trash SAFE "Trash" \
    "Things you already deleted. Emptying the Trash is permanent." yes "$HOME/.Trash"
  add_item mail_downloads SAFE "Mail attachment copies" \
    "Copies of attachments you opened. Originals stay in your mailbox." yes \
    "$L/Containers/com.apple.mail/Data/Library/Mail Downloads"
  add_item electron_caches SAFE "Desktop app web caches (VS Code, Cursor, Slack, Discord)" \
    "Quit these apps before cleaning." yes \
    "$AS/Code/Cache" "$AS/Code/CachedData" "$AS/Code/CachedExtensionVSIXs" \
    "$AS/Cursor/Cache" "$AS/Cursor/CachedData" \
    "$AS/Slack/Cache" "$AS/Slack/Service Worker/CacheStorage" "$AS/discord/Cache"

  add_item xcode_derived SAFE "Xcode DerivedData" \
    "Build intermediates. The next build is slower, nothing is lost." yes \
    "$L/Developer/Xcode/DerivedData"
  add_item xcode_device_support SAFE "Xcode iOS DeviceSupport" \
    "Debug symbols per iOS version, copied again when a device connects." yes \
    "$L/Developer/Xcode/iOS DeviceSupport"
  add_item sim_caches SAFE "iOS Simulator caches" "Regenerated by the simulator." yes \
    "$L/Developer/CoreSimulator/Caches"
  add_item sim_devices CAUTION "iOS Simulator devices" \
    "Clean only deletes simulators whose iOS runtime is no longer installed." \
    "$(yes_if_has xcrun)" "$L/Developer/CoreSimulator/Devices"
  add_item xcode_archives REVIEW "Xcode Archives" \
    "Needed to symbolicate crash reports. Delete old ones in Xcode > Organizer." "" \
    "$L/Developer/Xcode/Archives"

  add_item npm SAFE "npm cache" "Packages are downloaded again when needed." \
    "$(yes_if_has npm)" "$HOME/.npm/_cacache"
  add_item pnpm SAFE "pnpm store" \
    "Clean runs 'pnpm store prune', which only drops packages no project uses." \
    "$(yes_if_has pnpm)" "$L/pnpm/store"
  add_item yarn SAFE "Yarn Berry cache" "Packages are downloaded again when needed." yes \
    "$HOME/.yarn/berry/cache"
  add_item bun SAFE "Bun cache" "Packages are downloaded again when needed." yes \
    "$HOME/.bun/install/cache"
  add_item go_mod SAFE "Go module cache" "Modules are downloaded again when needed." \
    "$(yes_if_has go)" "$HOME/go/pkg/mod"
  add_item cargo SAFE "Cargo registry cache" "Crates are downloaded again when needed." yes \
    "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src"
  add_item gradle SAFE "Gradle caches" "Dependencies are downloaded again. Stop Gradle daemons first." yes \
    "$HOME/.gradle/caches"
  for lib in "$HOME/miniconda3/pkgs" "$HOME/anaconda3/pkgs" "$HOME/miniforge3/pkgs" "$HOME/opt/anaconda3/pkgs"; do
    [ -d "$lib" ] && conda_pkgs+=("$lib")
  done
  if [ ${#conda_pkgs[@]} -gt 0 ]; then
    add_item conda SAFE "Conda package cache" "Clean runs 'conda clean --all', environments are kept." \
      "$(yes_if_has conda)" "${conda_pkgs[@]}"
  fi
  add_item maven CAUTION "Maven local repository" \
    "Also holds artifacts you built with 'mvn install', which are not re-downloadable." yes \
    "$HOME/.m2/repository"
  add_item docker CAUTION "Docker Desktop disk image" \
    "Clean runs 'docker system prune': stopped containers, dangling images, build cache. Volumes are kept." \
    "$(yes_if_has docker)" "$L/Containers/com.docker.docker/Data/vms"

  add_item podman REVIEW "Podman machine (VM disk)" \
    "Holds your images and volumes. Run 'podman system prune', or 'podman machine rm' if unused." "" \
    "$HOME/.local/share/containers/podman/machine"
  add_item colima REVIEW "Colima VM" \
    "Holds your images and volumes. Run 'docker system prune', or 'colima delete' if unused." "" \
    "$HOME/.colima"
  add_item android_avd REVIEW "Android emulators" \
    "Delete emulators you no longer use in Android Studio > Device Manager." "" "$HOME/.android/avd"
  add_item android_images REVIEW "Android system images" \
    "Uninstall unused API levels in Android Studio > SDK Manager." "" "$L/Android/sdk/system-images"

  add_item downloads REVIEW "Downloads folder" \
    "Your files. Sort by size in Finder and remove what you no longer need." "" "$HOME/Downloads"
  add_item ios_backups REVIEW "iPhone / iPad backups" \
    "Delete old backups in Finder > your device > Manage Backups, never by hand." "" \
    "$AS/MobileSync/Backup"
  add_item messages REVIEW "Messages attachments" \
    "Review in System Settings > General > Storage > Messages." "" "$L/Messages/Attachments"
  for lib in "$HOME"/Pictures/*.photoslibrary; do
    [ -d "$lib" ] || continue
    add_item photos REVIEW "Photos library ($(basename "$lib"))" \
      "Never delete files inside it. Use the Photos app or iCloud 'Optimize Mac Storage'." "" "$lib"
  done

  collect_installers
}

# Installer images are measured file by file, so they get a precomputed size.
collect_installers() {
  local list="$WORK/installers" count kb
  progress "installers in Downloads and Desktop"
  find "$HOME/Downloads" "$HOME/Desktop" -maxdepth 3 -type f \
    \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.xip' -o -iname '*.iso' \) -print 2>/dev/null >"$list"
  count=$(awk 'END { print NR }' "$list")
  [ "$count" -gt 0 ] || return 0
  kb=$(tr '\n' '\0' <"$list" | xargs -0 du -k 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
  add_item installers CAUTION "Installer files ($count .dmg/.pkg/.xip/.iso)" \
    "Rarely needed after installing. Clean moves them to the Trash, so it can be undone." yes
  ITEM_KB[${#ITEM_KB[@]} - 1]=$kb
}

measure_items() {
  local i p total arr
  for ((i = 0; i < ${#ITEM_ID[@]}; i++)); do
    [ -n "${ITEM_KB[i]}" ] && continue
    progress "${ITEM_LABEL[i]}"
    total=0
    IFS=: read -r -a arr <<<"${ITEM_PATHS[i]}"
    for p in "${arr[@]}"; do
      [ -e "$p" ] && total=$((total + $(path_kb "$p")))
    done
    ITEM_KB[i]=$total
  done
  progress_done
}

# Item indexes, biggest first, skipping anything under 1 MB.
sorted_items() {
  local i
  for ((i = 0; i < ${#ITEM_ID[@]}; i++)); do
    [ "${ITEM_KB[i]:-0}" -ge 1024 ] && printf '%s %s\n' "${ITEM_KB[i]}" "$i"
  done | sort -nr | awk '{ print $2 }'
}

show_items() {
  local i first
  section "Space hogs"
  printf '  %s%-10s %-7s  %s%s\n' "$D" "SIZE" "SAFETY" "WHAT" "$N"
  for i in $(sorted_items); do
    first=${ITEM_PATHS[i]%%:*}
    printf '  %-10s %s  %s%s%s\n' "$(human "${ITEM_KB[i]}")" "$(badge "${ITEM_SAFETY[i]}")" "$B" "${ITEM_LABEL[i]}" "$N"
    printf '  %-10s %-7s  %s%s%s\n' "" "" "$D" "${ITEM_NOTE[i]}" "$N"
    [ -n "$first" ] && printf '  %-10s %-7s  %s%s%s\n' "" "" "$D" "$(tilde "$first")" "$N"
  done
}

# item_commands I - the commands that clean item I by hand, one per line.
# Mirrors clean_item; for folders only allowlisted ones that exist are listed.
item_commands() {
  local i=$1 p d arr
  case "${ITEM_ID[i]}" in
    trash) echo "osascript -e 'tell application \"Finder\" to empty trash'" ;;
    sim_devices) echo "xcrun simctl delete unavailable" ;;
    npm) echo "npm cache clean --force" ;;
    pnpm) echo "pnpm store prune" ;;
    go_mod) echo "go clean -modcache" ;;
    conda) echo "conda clean --all --yes" ;;
    docker) echo "docker system prune --force" ;;
    installers) ;; # a list of single files, moved to the Trash by --clean only
    *)
      IFS=: read -r -a arr <<<"${ITEM_PATHS[i]}"
      for p in "${arr[@]}"; do
        # Skip empty folders: zsh, the default macOS shell, errors on a glob with no matches.
        [ -n "$(ls -A "$p" 2>/dev/null)" ] || continue
        for d in "${CLEANABLE_DIRS[@]}"; do
          # shellcheck disable=SC2016 # $HOME is meant to be printed, not expanded
          [ "$p" = "$d" ] && printf 'rm -rf "$HOME%s"/*\n' "${p#"$HOME"}" && break
        done
      done
      ;;
  esac
}

show_commands() {
  local i cmds shown=0
  for i in $(sorted_items); do
    [ "${ITEM_CLEAN[i]}" = "yes" ] || continue
    case "${ITEM_SAFETY[i]}" in SAFE | CAUTION) ;; *) continue ;; esac
    cmds=$(item_commands "$i")
    [ -n "$cmds" ] || continue
    if [ "$shown" -eq 0 ]; then
      section "Delete commands"
      note "Prefer --clean: it asks per item and only touches allowlisted folders."
      note "To clean by hand, quit the related apps and copy the command under an item."
      shown=1
    fi
    printf '\n  %s  %s%s%s %s(%s)%s\n' "$(badge "${ITEM_SAFETY[i]}")" "$B" "${ITEM_LABEL[i]}" "$N" "$D" "$(human "${ITEM_KB[i]}")" "$N"
    printf '%s\n' "$cmds" | sed 's/^/    /'
  done
}

# ---------------------------------------------------------------------------
# Detailed scans (skipped with --quick)
# ---------------------------------------------------------------------------

cache_hint() {
  case "$1" in
    Homebrew) echo "brew cleanup --prune=all" ;;
    pip) echo "pip cache purge" ;;
    CocoaPods) echo "pod cache clean --all" ;;
    Yarn) echo "yarn cache clean" ;;
    go-build) echo "go clean -cache" ;;
    JetBrains) echo "folders of old IDE versions can go" ;;
    com.apple.dt.Xcode) echo "Xcode cache, safe" ;;
    com.spotify.client) echo "Spotify offline cache, re-downloads" ;;
    ms-playwright) echo "browsers for Playwright, 'npx playwright install' restores them" ;;
    colima) echo "downloaded VM images" ;;
  esac
}

# show_breakdown DIR COUNT - biggest children of DIR.
show_breakdown() {
  local dir=$1 count=$2 kb p name hint
  [ -d "$dir" ] || return 0
  progress "$(tilde "$dir")"
  du -sk "$dir"/* 2>/dev/null | sort -nr | head -n "$count" >"$WORK/breakdown"
  progress_done
  printf '\n  %s%s%s\n' "$B" "$(tilde "$dir")" "$N"
  while IFS=$'\t' read -r kb p; do
    name=$(basename "$p")
    hint=$(cache_hint "$name")
    printf '    %-10s %s%s\n' "$(human "$kb")" "$name" "${hint:+ $D($hint)$N}"
  done <"$WORK/breakdown"
}

show_breakdowns() {
  section "Where the space inside your Library goes"
  show_breakdown "$HOME/Library/Caches" 8
  show_breakdown "$HOME/Library/Application Support" 8
  note "Application Support holds app data (settings, databases). Folders of apps you already"
  note "uninstalled can be removed, but check first. medic never cleans this folder."
}

scan_dev_projects() {
  local roots=() seen="" r id total=0 count=0
  for r in "$HOME/dev" "$HOME/Developer" "$HOME/Projects" "$HOME/code" "$HOME/workspace" \
    "$HOME/src" "$HOME/git" "$HOME/Documents/GitHub" "${DEV_DIRS[@]}"; do
    [ -d "$r" ] || continue
    # The default file system is case-insensitive, so ~/code and ~/Code can be the same folder.
    id=$(stat -f '%d:%i' "$r")
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    roots+=("$r")
  done
  [ ${#roots[@]} -gt 0 ] || return 0

  progress "node_modules and Python virtualenvs"
  find "${roots[@]}" \( -name node_modules -o -name .venv -o -name venv \) -type d -prune -print 2>/dev/null |
    sort -u |
    while IFS= read -r p; do
      case "$(basename "$p")" in .venv | venv) [ -f "$p/pyvenv.cfg" ] || continue ;; esac
      printf '%s\t%s\n' "$(path_kb "$p")" "$p"
    done | sort -nr >"$WORK/dev"
  progress_done

  read -r total count <<<"$(awk -F'\t' '{ s += $1 } END { print s + 0, NR }' "$WORK/dev")"
  [ "$count" -gt 0 ] || return 0

  section "Dev project dependencies"
  printf '  %s%s%s in %s folders %s(node_modules, Python venvs)%s\n' "$B" "$(human "$total")" "$N" "$count" "$D" "$N"
  head -8 "$WORK/dev" | while IFS=$'\t' read -r kb p; do
    printf '    %-10s %s\n' "$(human "$kb")" "$(tilde "$p")"
  done
  note "REVIEW: reinstallable with 'npm install' / 'pip install -r ...', but only remove them for"
  note "projects you are not working on. 'npx npkill' lets you pick them interactively."
}

scan_large_files() {
  local p kb
  progress "files larger than $LARGE_MB MB in your home folder"
  find "$HOME" -xdev \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -name '*.photoslibrary' \
    -o -name node_modules -o -name .git \) -prune -o -type f -size +"${LARGE_MB}"M -print 2>/dev/null |
    while IFS= read -r p; do
      printf '%s\t%s\t%s\n' "$(du -k "$p" 2>/dev/null | awk '{ print $1 }')" \
        "$(stat -f '%Sm' -t '%Y-%m-%d' "$p" 2>/dev/null)" "$p"
    done | sort -nr | head -15 >"$WORK/large"
  progress_done
  [ -s "$WORK/large" ] || return 0

  section "Large files (> $LARGE_MB MB)"
  printf '  %s%-10s %-11s %s%s\n' "$D" "SIZE" "MODIFIED" "FILE" "$N"
  while IFS=$'\t' read -r kb mtime p; do
    printf '  %-10s %-11s %s\n' "$(human "$kb")" "$mtime" "$(tilde "$p")"
  done <"$WORK/large"
  note "REVIEW: these are your files. Old videos, disk images and archives are the usual suspects."
}

# ---------------------------------------------------------------------------
# Things macOS manages itself
# ---------------------------------------------------------------------------

show_system_info() {
  local snaps
  section "Managed by macOS (do not delete by hand)"
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple')
  printf '  %-26s %s\n' "Time Machine snapshots" "${snaps:-0} local snapshot(s)"
  note "Removed automatically when space runs low. Counted as 'purgeable' in Finder."
  printf '  %-26s %s\n' "System Data" "caches, swap, logs and snapshots owned by macOS"
  note "Shrinks after a restart. Never delete files in /System, /Library or /private/var by hand."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

show_summary() {
  local i safe=0 caution=0 review=0
  for ((i = 0; i < ${#ITEM_ID[@]}; i++)); do
    [ "${ITEM_KB[i]:-0}" -ge 1024 ] || continue
    case "${ITEM_SAFETY[i]}" in
      SAFE) safe=$((safe + ITEM_KB[i])) ;;
      CAUTION) caution=$((caution + ITEM_KB[i])) ;;
      REVIEW) review=$((review + ITEM_KB[i])) ;;
    esac
  done

  section "Summary"
  printf '  %s  %s%-10s%s regenerated automatically, no data loss\n' "$(badge SAFE)" "$B" "$(human "$safe")" "$N"
  printf '  %s  %s%-10s%s regenerable, read the note first\n' "$(badge CAUTION)" "$B" "$(human "$caution")" "$N"
  printf '  %s  %s%-10s%s your data, check by hand (never cleaned by medic)\n' "$(badge REVIEW)" "$B" "$(human "$review")" "$N"
  if [ "$CLEAN" -eq 0 ]; then
    printf '\n  Run %s%s --clean%s to clean SAFE and CAUTION items (asks for each one),\n' "$B" "$PROG" "$N"
    printf '  or %s%s --dry-run%s to preview without changing anything.\n' "$B" "$PROG" "$N"
  fi
}

# ---------------------------------------------------------------------------
# Cleaning
# ---------------------------------------------------------------------------

# The only folders whose contents medic will ever delete. Exact matches only.
CLEANABLE_DIRS=(
  "$HOME/Library/Caches"
  "$HOME/Library/Logs"
  "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  "$HOME/Library/Application Support/Code/Cache"
  "$HOME/Library/Application Support/Code/CachedData"
  "$HOME/Library/Application Support/Code/CachedExtensionVSIXs"
  "$HOME/Library/Application Support/Cursor/Cache"
  "$HOME/Library/Application Support/Cursor/CachedData"
  "$HOME/Library/Application Support/Slack/Cache"
  "$HOME/Library/Application Support/Slack/Service Worker/CacheStorage"
  "$HOME/Library/Application Support/discord/Cache"
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  "$HOME/Library/Developer/CoreSimulator/Caches"
  "$HOME/.yarn/berry/cache"
  "$HOME/.bun/install/cache"
  "$HOME/.cargo/registry/cache"
  "$HOME/.cargo/registry/src"
  "$HOME/.gradle/caches"
  "$HOME/.m2/repository"
)

# empty_dir DIR - delete the contents of DIR (not DIR itself), only if DIR is
# on the allowlist above. Symlinks inside are removed, never followed.
empty_dir() {
  local dir=$1 allowed=0 d
  for d in "${CLEANABLE_DIRS[@]}"; do
    [ "$dir" = "$d" ] && allowed=1 && break
  done
  if [ "$allowed" -ne 1 ]; then
    warn "refusing to touch $dir (not on the allowlist)"
    return 1
  fi
  [ -d "$dir" ] || return 0
  if [ -L "$dir" ]; then
    warn "refusing to touch $dir (it is a symlink)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    note "would delete the contents of $(tilde "$dir")"
    return 0
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  return 0
}

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    note "would run: $*"
    return 0
  fi
  "$@" </dev/null
}

# Move every file listed in $1 to the Trash through Finder, so it can be put back.
trash_files() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      note "would move to Trash: $(tilde "$f")"
      continue
    fi
    osascript -e 'on run argv' -e 'set f to POSIX file (item 1 of argv) as alias' \
      -e 'tell application "Finder" to delete f' -e 'end run' "$f" </dev/null >/dev/null 2>&1 ||
      warn "could not move $(tilde "$f") to the Trash"
  done <"$1"
}

clean_item() {
  local i=$1 d arr
  case "${ITEM_ID[i]}" in
    trash) run_cmd osascript -e 'tell application "Finder" to empty trash' ;;
    sim_devices) run_cmd xcrun simctl delete unavailable ;;
    npm) run_cmd npm cache clean --force ;;
    pnpm) run_cmd pnpm store prune ;;
    go_mod) run_cmd go clean -modcache ;;
    conda) run_cmd conda clean --all --yes ;;
    docker)
      if ! docker info >/dev/null 2>&1; then
        warn "Docker is not running. Start Docker Desktop and try again."
        return 1
      fi
      run_cmd docker system prune --force
      ;;
    installers) trash_files "$WORK/installers" ;;
    *)
      IFS=: read -r -a arr <<<"${ITEM_PATHS[i]}"
      for d in "${arr[@]}"; do empty_dir "$d"; done
      ;;
  esac
}

ask() {
  local answer
  printf '%s' "$1"
  read -r answer </dev/tty || return 1
  case "$answer" in y | Y | yes | YES) return 0 ;; esac
  return 1
}

run_clean() {
  local i before after cleaned=0
  section "Clean up"
  if ! { : </dev/tty; } 2>/dev/null; then
    warn "--clean needs an interactive terminal to ask for confirmation."
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: nothing will be changed."
  else
    note "Quit the apps whose caches you clean. Answer y to clean an item, anything else skips it."
  fi

  before=$(df -k / | awk 'NR == 2 { print $4 }')
  for i in $(sorted_items); do
    [ "${ITEM_CLEAN[i]}" = "yes" ] || continue
    case "${ITEM_SAFETY[i]}" in SAFE | CAUTION) ;; *) continue ;; esac
    printf '\n  %s  %s%s%s (%s)\n' "$(badge "${ITEM_SAFETY[i]}")" "$B" "${ITEM_LABEL[i]}" "$N" "$(human "${ITEM_KB[i]}")"
    note "${ITEM_NOTE[i]}"
    if ask "  Clean it? [y/N] "; then
      clean_item "$i" && cleaned=$((cleaned + 1))
    fi
  done

  [ "$DRY_RUN" -eq 1 ] && return 0
  after=$(df -k / | awk 'NR == 2 { print $4 }')
  printf '\n  Cleaned %s item(s). Free space went from %s to %s%s%s.\n' \
    "$cleaned" "$(human "$before")" "$B" "$(human "$after")" "$N"
  note "APFS can take a minute to report freed space. Time Machine snapshots may hold it until they expire."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf '%smedic %s%s %s- %s, macOS %s%s\n' "$B" "$VERSION" "$N" "$D" "$(scutil --get ComputerName 2>/dev/null || hostname)" "$(sw_vers -productVersion)" "$N"
note "Read-only scan. Nothing is deleted unless you run --clean and confirm."
if [ -d "$HOME/Library/Safari" ] && ! ls "$HOME/Library/Safari" >/dev/null 2>&1; then
  warn "Your terminal has no Full Disk Access, so Trash and Mail sizes may show as empty."
  note "Grant it in System Settings > Privacy & Security > Full Disk Access for complete results."
fi

show_disk
show_memory
collect_items
measure_items
show_items
show_commands
if [ "$QUICK" -eq 0 ]; then
  show_breakdowns
  scan_dev_projects
  scan_large_files
fi
show_system_info
show_summary
[ "$CLEAN" -eq 1 ] && run_clean
exit 0
