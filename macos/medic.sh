#!/usr/bin/env bash
#
# medic for macOS - find out what is filling up your Mac and what is safe to clean.
# The Windows version lives in windows/medic.ps1.
#
# Read-only by default: nothing is deleted unless you run "medic clean" and
# confirm every single item. Only SAFE and CAUTION items can ever be cleaned.
# REVIEW items (your personal data) are reported, never touched.
#
# Runs on the stock macOS bash 3.2, no dependencies.
#
# License: MIT

set -o pipefail

VERSION="0.4.0"

COMMAND=""
QUICK=0
DRY_RUN=0
JSON=0
YES=0
ONLY=""
OLDER_THAN=30
MIN_FREE="10%"
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

Usage: $PROG [command] [options]

Commands:
  report           Full report (default)
  disk             Disk, space hogs, delete commands, dev folders and large files
  memory           Memory use and the apps using the most
  clean            Pick SAFE and CAUTION items to clean
  purge            Pick dependency and build folders of inactive projects to delete
  check            Exit with 1 when the disk is almost full or memory is critical

Options:
  --json           Print JSON instead of text (report, disk, memory, purge, check)
  --quick          Skip the slow scans: breakdowns, dev folders, large files
  --large MB       Report files bigger than MB megabytes (default: $LARGE_MB)
  --dev-dir DIR    Extra project folder to scan (repeatable)
  --dry-run        clean, purge: show what would happen, change nothing
  --yes            clean, purge: do not ask, take every listed item
  --only LIST      clean: only these levels (safe, caution) or item ids, comma-separated.
                   With --yes the default is safe.
  --older-than N   purge: only projects with no file changed in N days (default: $OLDER_THAN, 0 for all)
  --min-free SIZE  check: free space needed, like 20G, 500M or 10% (default: $MIN_FREE)
  --no-color       Disable colored output (NO_COLOR is honored too)
  -h, --help       Show this help
  -v, --version    Show version

Safety levels:
  SAFE       Regenerated automatically. No data loss.
  CAUTION    Regenerable, but you lose more than a cache (stopped containers,
             locally installed artifacts) or it costs a long rebuild.
  REVIEW     May contain personal data. Reported only, never deleted.

Exit codes: 0 ok, 1 error or failed check, 2 wrong usage.
EOF
}

die() {
  printf 'medic: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'medic: %s\nRun "%s --help" for usage.\n' "$*" "$PROG" >&2
  exit 2
}

# need_value OPTION VALUE - options that take a value must get one.
need_value() { [ -n "$2" ] && [ "${2#--}" = "$2" ] || usage_error "$1 needs a value"; }

LEGACY_CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    report | disk | memory | clean | purge | check | ram)
      [ -z "$COMMAND" ] || usage_error "only one command at a time ('$COMMAND' and '$1')"
      COMMAND=$1
      [ "$COMMAND" = "ram" ] && COMMAND="memory"
      ;;
    --clean) LEGACY_CLEAN=1 ;; # before 0.4: same as "clean"
    --dry-run) DRY_RUN=1 ;;
    --json) JSON=1 ;;
    --yes) YES=1 ;;
    --quick) QUICK=1 ;;
    --only) need_value "$1" "${2:-}"; shift; ONLY=$1 ;;
    --older-than)
      need_value "$1" "${2:-}"; shift
      case "$1" in *[!0-9]*) usage_error "--older-than needs a number of days" ;; esac
      OLDER_THAN=$1
      ;;
    --min-free) need_value "$1" "${2:-}"; shift; MIN_FREE=$1 ;;
    --large)
      need_value "$1" "${2:-}"; shift
      case "$1" in *[!0-9]*) usage_error "--large needs a number of megabytes" ;; esac
      LARGE_MB=$1
      ;;
    --dev-dir)
      need_value "$1" "${2:-}"; shift
      [ -d "$1" ] || usage_error "--dev-dir: '$1' is not a directory"
      DEV_DIRS+=("$1")
      ;;
    --no-color) USE_COLOR=0 ;;
    -h | --help) usage; exit 0 ;;
    -v | --version) echo "medic $VERSION"; exit 0 ;;
    -*) usage_error "unknown option: $1" ;;
    *) usage_error "unknown command: $1" ;;
  esac
  shift
done

# Before 0.4 cleaning was "--clean" or "--dry-run" on the report.
if [ -z "$COMMAND" ] && { [ "$LEGACY_CLEAN" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; }; then COMMAND="clean"; fi
COMMAND=${COMMAND:-report}

case "$COMMAND" in clean | purge) ;; *)
  [ "$DRY_RUN" -eq 0 ] || usage_error "--dry-run only works with clean and purge"
  [ "$YES" -eq 0 ] || usage_error "--yes only works with clean and purge"
  ;;
esac
[ "$COMMAND" = "clean" ] && [ "$JSON" -eq 1 ] && usage_error "clean has no JSON output; 'medic report --json' lists the items"
[ -z "$ONLY" ] || [ "$COMMAND" = "clean" ] || usage_error "--only only works with clean"
case "$MIN_FREE" in
  *%) case "${MIN_FREE%\%}" in '' | *[!0-9]*) usage_error "--min-free: '$MIN_FREE' is not a size like 20G, 500M or 10%" ;; esac ;;
  *) printf '%s' "$MIN_FREE" | grep -Eqi '^[0-9]+(\.[0-9]+)?([KMGT]B?)?$' ||
    usage_error "--min-free: '$MIN_FREE' is not a size like 20G, 500M or 10%" ;;
esac

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

# read_disk - fills the DISK_* values, in KB.
read_disk() {
  read -r DISK_TOTAL DISK_SYSTEM DISK_FREE <<<"$(df -k / | awk 'NR == 2 { print $2, $3, $4 }')"
  DISK_DATA=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $3 + 0 }')
  DISK_DATA=${DISK_DATA:-0}
  DISK_USED=$((DISK_TOTAL - DISK_FREE))
  DISK_PCT=$((DISK_USED * 100 / DISK_TOTAL))
}

show_disk() {
  local other=$((DISK_USED - DISK_SYSTEM - DISK_DATA)) pct=$DISK_PCT
  [ "$other" -lt 0 ] && other=0

  section "Disk"
  printf '  %-22s %s\n' "Capacity" "$(human "$DISK_TOTAL")"
  printf '  %-22s %-10s %s %s%%\n' "Used" "$(human "$DISK_USED")" "$(bar "$pct")" "$pct"
  printf '  %-22s %s%s%s\n' "Free" "$B" "$(human "$DISK_FREE")" "$N"
  printf '  %-22s %s\n' "  macOS (read-only)" "$(human "$DISK_SYSTEM")"
  printf '  %-22s %s\n' "  Your data volume" "$(human "$DISK_DATA")"
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

# read_memory - fills the MEM_* values in KB, MEM_PRESSURE (normal, warning,
# critical or unknown), and $WORK/apps with the top apps: KB, processes, name.
read_memory() {
  local vm page purg file anon
  vm=$(vm_stat)
  page=$(printf '%s\n' "$vm" | awk '/page size of/ { print $8 }')
  page=${page:-16384}
  MEM_TOTAL=$(($(sysctl -n hw.memsize) / 1024))
  MEM_WIRED=$(($(vm_pages "$vm" "Pages wired down") * page / 1024))
  MEM_COMPRESSED=$(($(vm_pages "$vm" "Pages occupied by compressor") * page / 1024))
  purg=$(($(vm_pages "$vm" "Pages purgeable") * page / 1024))
  file=$(($(vm_pages "$vm" "File-backed pages") * page / 1024))
  anon=$(($(vm_pages "$vm" "Anonymous pages") * page / 1024))
  MEM_FREE=$(($(vm_pages "$vm" "Pages free") * page / 1024))
  MEM_APP=$((anon - purg))
  [ "$MEM_APP" -lt 0 ] && MEM_APP=0
  MEM_USED=$((MEM_APP + MEM_WIRED + MEM_COMPRESSED))
  MEM_CACHED=$((file + purg))

  case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
    1) MEM_PRESSURE="normal" ;;
    2) MEM_PRESSURE="warning" ;;
    4) MEM_PRESSURE="critical" ;;
    *) MEM_PRESSURE="unknown" ;;
  esac
  MEM_AVAILABLE_PCT=$(memory_pressure -Q 2>/dev/null | awk -F: '/free percentage/ { gsub(/[ %]/, "", $2); print $2 }')
  read -r MEM_SWAP_TOTAL MEM_SWAP_USED <<<"$(sysctl -n vm.swapusage 2>/dev/null |
    awk '{ t = $3; u = $6; sub(/M/, "", t); sub(/M/, "", u); printf "%d %d", t * 1024, u * 1024 }')"
  MEM_SWAP_TOTAL=${MEM_SWAP_TOTAL:-0}
  MEM_SWAP_USED=${MEM_SWAP_USED:-0}

  # Group helper processes under their app: everything inside "Foo.app/" counts as Foo.
  ps -axo rss=,comm= | awk '{
    rss = $1; $1 = ""; sub(/^ +/, ""); p = $0
    if (match(p, /[^\/]+\.app\//)) name = substr(p, RSTART, RLENGTH - 5)
    else { n = split(p, a, "/"); name = a[n] }
    sum[name] += rss; cnt[name]++
  } END { for (k in sum) printf "%d\t%d\t%s\n", sum[k], cnt[k], k }' |
    sort -nr | head -8 >"$WORK/apps"
}

show_memory() {
  local pct=$((MEM_USED * 100 / MEM_TOTAL)) kb count name
  section "Memory (RAM)"
  printf '  %-22s %s\n' "Physical memory" "$(human "$MEM_TOTAL" bin)"
  printf '  %-22s %-10s %s %s%%\n' "Used" "$(human "$MEM_USED" bin)" "$(bar "$pct")" "$pct"
  printf '  %-22s %s\n' "  App memory" "$(human "$MEM_APP" bin)"
  printf '  %-22s %s %s\n' "  Wired" "$(human "$MEM_WIRED" bin)" "${D}(kernel, cannot be freed)${N}"
  printf '  %-22s %s\n' "  Compressed" "$(human "$MEM_COMPRESSED" bin)"
  printf '  %-22s %s %s\n' "Cached files" "$(human "$MEM_CACHED" bin)" "${D}(freed instantly when apps need it)${N}"
  printf '  %-22s %s\n' "Free" "$(human "$MEM_FREE" bin)"
  printf '  %-22s %s of %s\n' "Swap used" "$(human "$MEM_SWAP_USED" bin)" "$(human "$MEM_SWAP_TOTAL" bin)"

  case "$MEM_PRESSURE" in
    normal) printf '  %-22s %sNormal%s' "Memory pressure" "$GRN" "$N" ;;
    warning) printf '  %-22s %sWarning%s' "Memory pressure" "$YEL" "$N" ;;
    critical) printf '  %-22s %sCritical%s' "Memory pressure" "$RED" "$N" ;;
    *) printf '  %-22s unknown' "Memory pressure" ;;
  esac
  [ -n "$MEM_AVAILABLE_PCT" ] && printf ' %s(%s%% available)%s' "$D" "$MEM_AVAILABLE_PCT" "$N"
  printf '\n'

  printf '\n  %sTop apps by memory%s %s(resident memory, approximate)%s\n' "$B" "$N" "$D" "$N"
  while IFS=$'\t' read -r kb count name; do
    if [ "$count" -gt 1 ]; then
      printf '    %-10s %s %s(%s processes)%s\n' "$(human "$kb" bin)" "$name" "$D" "$count" "$N"
    else
      printf '    %-10s %s\n' "$(human "$kb" bin)" "$name"
    fi
  done <"$WORK/apps"

  if [ "$MEM_PRESSURE" = "warning" ] || [ "$MEM_PRESSURE" = "critical" ]; then
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
    installers) ;; # a list of single files, moved to the Trash by clean only
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
      note "Prefer '$PROG clean': it asks first and only touches allowlisted folders."
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

# dev_roots - fills DEV_ROOTS with the project folders that exist, each once.
dev_roots() {
  local seen="" r id
  DEV_ROOTS=()
  for r in "$HOME/dev" "$HOME/Developer" "$HOME/Projects" "$HOME/code" "$HOME/workspace" \
    "$HOME/src" "$HOME/git" "$HOME/Documents/GitHub" "${DEV_DIRS[@]}"; do
    [ -d "$r" ] || continue
    # The default file system is case-insensitive, so ~/code and ~/Code can be the same folder.
    id=$(stat -f '%d:%i' "$r")
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    DEV_ROOTS+=("$(cd "$r" && pwd -P)")
  done
}

# find_dev_folders - $WORK/dev: KB and path of node_modules and Python venvs, biggest first.
find_dev_folders() {
  : >"$WORK/dev"
  dev_roots
  [ ${#DEV_ROOTS[@]} -gt 0 ] || return 0
  progress "node_modules and Python virtualenvs"
  find "${DEV_ROOTS[@]}" \( -name node_modules -o -name .venv -o -name venv \) -type d -prune -print 2>/dev/null |
    sort -u |
    while IFS= read -r p; do
      case "$(basename "$p")" in .venv | venv) [ -f "$p/pyvenv.cfg" ] || continue ;; esac
      printf '%s\t%s\n' "$(path_kb "$p")" "$p"
    done | sort -nr >"$WORK/dev"
  progress_done
}

show_dev_folders() {
  local total count kb p
  read -r total count <<<"$(awk -F'\t' '{ s += $1 } END { print s + 0, NR }' "$WORK/dev")"
  [ "$count" -gt 0 ] || return 0

  section "Dev project dependencies"
  printf '  %s%s%s in %s folders %s(node_modules, Python venvs)%s\n' "$B" "$(human "$total")" "$N" "$count" "$D" "$N"
  head -8 "$WORK/dev" | while IFS=$'\t' read -r kb p; do
    printf '    %-10s %s\n' "$(human "$kb")" "$(tilde "$p")"
  done
  note "REVIEW: reinstallable, but only remove them for projects you are not working on."
  note "Run '$PROG purge' to pick the ones of projects untouched for $OLDER_THAN days."
}

# find_large_files - $WORK/large: KB, modified date and path, biggest first.
find_large_files() {
  local p
  progress "files larger than $LARGE_MB MB in your home folder"
  find "$HOME" -xdev \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -name '*.photoslibrary' \
    -o -name node_modules -o -name .git \) -prune -o -type f -size +"${LARGE_MB}"M -print 2>/dev/null |
    while IFS= read -r p; do
      printf '%s\t%s\t%s\n' "$(du -k "$p" 2>/dev/null | awk '{ print $1 }')" \
        "$(stat -f '%Sm' -t '%Y-%m-%d' "$p" 2>/dev/null)" "$p"
    done | sort -nr | head -15 >"$WORK/large"
  progress_done
}

show_large_files() {
  local kb mtime p
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
  printf '\n  Run %s%s clean%s to pick SAFE and CAUTION items to clean,\n' "$B" "$PROG" "$N"
  printf '  or %s%s clean --dry-run%s to preview without changing anything.\n' "$B" "$PROG" "$N"
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

# ---------------------------------------------------------------------------
# Picking items: numbered list, then "1,3", "2-5", "all" or a safety level
# ---------------------------------------------------------------------------

has_tty() { { : </dev/tty; } 2>/dev/null; }

# select_numbers ANSWER COUNT [LEVEL...] - print the picked numbers (1-based),
# one per line. LEVELs are the safety level of each row, for "safe"/"caution".
select_numbers() {
  local answer=$1 count=$2 token from to n i
  shift 2
  local levels=("$@")
  for token in $(printf '%s' "$answer" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    case "$token" in
      all) seq 1 "$count" ;;
      safe | caution)
        [ ${#levels[@]} -gt 0 ] || return 1
        for ((i = 0; i < count; i++)); do
          [ "$(printf '%s' "${levels[i]}" | tr '[:upper:]' '[:lower:]')" = "$token" ] && echo $((i + 1))
        done
        ;;
      *-*)
        from=${token%-*} to=${token#*-}
        case "$from$to" in '' | *[!0-9]*) return 1 ;; esac
        [ "$from" -ge 1 ] && [ "$to" -le "$count" ] && [ "$from" -le "$to" ] || return 1
        seq "$from" "$to"
        ;;
      *)
        case "$token" in '' | *[!0-9]*) return 1 ;; esac
        n=$token
        [ "$n" -ge 1 ] && [ "$n" -le "$count" ] || return 1
        echo "$n"
        ;;
    esac
  done
}

# pick COUNT HINT [LEVEL...] - ask which rows to take, sets PICKED (0-based
# indexes, sorted, unique). Returns 1 when the user picks nothing.
pick() {
  local count=$1 hint=$2 answer picked
  shift 2
  PICKED=()
  while true; do
    printf '\n  Which ones? %s%s, Enter to cancel:%s ' "$D" "$hint" "$N"
    read -r answer </dev/tty || return 1
    [ -n "$answer" ] || return 1
    if picked=$(select_numbers "$answer" "$count" "$@") && [ -n "$picked" ]; then
      break
    fi
    warn "'$answer' is not a valid choice."
  done
  while read -r n; do PICKED+=($((n - 1))); done < <(printf '%s\n' "$picked" | sort -nu)
}

# confirm QUESTION - y/yes continues, anything else stops.
confirm() {
  local answer
  printf '  %s [y/N] ' "$1"
  read -r answer </dev/tty || return 1
  case "$answer" in y | Y | yes | YES) return 0 ;; esac
  return 1
}

free_kb() { df -k / | awk 'NR == 2 { print $4 }'; }

report_freed() {
  local before=$1 after
  [ "$DRY_RUN" -eq 1 ] && return 0
  after=$(free_kb)
  printf '\n  Free space went from %s to %s%s%s.\n' "$(human "$before")" "$B" "$(human "$after")" "$N"
  note "APFS can take a minute to report freed space. Time Machine snapshots may hold it until they expire."
}

# ---------------------------------------------------------------------------
# medic clean
# ---------------------------------------------------------------------------

# only_matches I - does item I pass --only (default: everything, or SAFE with --yes)?
only_matches() {
  local i=$1 only=$ONLY token
  [ -z "$only" ] && [ "$YES" -eq 1 ] && only="safe"
  [ -z "$only" ] && return 0
  for token in $(printf '%s' "$only" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    case "$token" in
      safe) [ "${ITEM_SAFETY[i]}" = "SAFE" ] && return 0 ;;
      caution) [ "${ITEM_SAFETY[i]}" = "CAUTION" ] && return 0 ;;
      *) [ "${ITEM_ID[i]}" = "$token" ] && return 0 ;;
    esac
  done
  return 1
}

check_only() {
  local token i known
  for token in $(printf '%s' "$ONLY" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    case "$token" in safe | caution) continue ;; esac
    known=0
    for ((i = 0; i < ${#ITEM_ID[@]}; i++)); do
      if [ "${ITEM_ID[i]}" = "$token" ] && [ "${ITEM_CLEAN[i]}" = "yes" ] && [ "${ITEM_SAFETY[i]}" != "REVIEW" ]; then known=1; fi
    done
    [ "$known" -eq 1 ] || usage_error "--only: '$token' is not a level (safe, caution) or a cleanable item id. 'medic report --json' lists the ids."
  done
}

run_clean() {
  local rows=() levels=() i n total=0 before cleaned=0
  for i in $(sorted_items); do
    [ "${ITEM_CLEAN[i]}" = "yes" ] || continue
    case "${ITEM_SAFETY[i]}" in SAFE | CAUTION) ;; *) continue ;; esac
    only_matches "$i" || continue
    rows+=("$i")
    levels+=("${ITEM_SAFETY[i]}")
  done

  section "Clean up"
  if [ ${#rows[@]} -eq 0 ]; then
    note "Nothing to clean."
    return 0
  fi
  printf '  %s%-3s %-10s %-7s  %s%s\n' "$D" "#" "SIZE" "SAFETY" "WHAT" "$N"
  for ((n = 0; n < ${#rows[@]}; n++)); do
    i=${rows[n]}
    printf '  %-3s %-10s %s  %s%s%s\n' "$((n + 1))" "$(human "${ITEM_KB[i]}")" "$(badge "${ITEM_SAFETY[i]}")" "$B" "${ITEM_LABEL[i]}" "$N"
    printf '  %-3s %-10s %-7s  %s%s%s\n' "" "" "" "$D" "${ITEM_NOTE[i]}" "$N"
  done

  if [ "$YES" -eq 1 ]; then
    PICKED=()
    for ((n = 0; n < ${#rows[@]}; n++)); do PICKED+=("$n"); done
  else
    if ! has_tty; then
      warn "clean needs a terminal to ask which items to clean. Pass --yes to clean without asking."
      return 1
    fi
    pick ${#rows[@]} "numbers like 1,3 or 2-5, 'safe', 'all'" "${levels[@]}" || { note "Nothing cleaned."; return 0; }
    for n in "${PICKED[@]}"; do total=$((total + ITEM_KB[rows[n]])); done
    if [ "$DRY_RUN" -eq 0 ]; then
      note "Quit the apps whose caches you clean."
      confirm "Clean ${#PICKED[@]} item(s), $(human "$total")?" || { note "Nothing cleaned."; return 0; }
    fi
  fi

  [ "$DRY_RUN" -eq 1 ] && note "Dry run: nothing will be changed."
  before=$(free_kb)
  for n in "${PICKED[@]}"; do
    i=${rows[n]}
    printf '  %s%s%s\n' "$B" "${ITEM_LABEL[i]}" "$N"
    clean_item "$i" && cleaned=$((cleaned + 1))
  done
  [ "$DRY_RUN" -eq 1 ] || printf '\n  Cleaned %s item(s).' "$cleaned"
  report_freed "$before"
}

# ---------------------------------------------------------------------------
# medic purge: dependency and build folders of projects nobody touched lately
# ---------------------------------------------------------------------------

# The folder names purge looks for, and the file next to them (or in them, for
# venvs) that proves what they are.
PURGE_NAMES=(node_modules .next .venv venv target build)

# purge_kind DIR - what DIR is, or nothing when it is not a purgeable folder.
purge_kind() {
  local dir=$1 parent=${1%/*}
  [ -d "$dir" ] && ! [ -L "$dir" ] || return 0
  case "${dir##*/}" in
    node_modules) [ -f "$parent/package.json" ] && echo "node_modules" ;;
    .next) [ -f "$parent/package.json" ] && echo "Next.js build" ;;
    .venv | venv) [ -f "$dir/pyvenv.cfg" ] && echo "Python venv" ;;
    target)
      if [ -f "$parent/Cargo.toml" ]; then echo "Rust build"; elif [ -f "$parent/pom.xml" ]; then echo "Maven build"; fi
      ;;
    build) { [ -f "$parent/build.gradle" ] || [ -f "$parent/build.gradle.kts" ]; } && echo "Gradle build" ;;
  esac
}

# project_active DIR - did any file in DIR change in the last OLDER_THAN days?
# Purgeable folders and .git are skipped: installs and fetches are not work.
project_active() {
  [ "$OLDER_THAN" -gt 0 ] || return 1
  [ -n "$(find "$1" \( -name .git -o -name node_modules -o -name .next -o -name .venv -o -name venv \
    -o -name target -o -name build \) -prune -o -type f -mtime -"$OLDER_THAN" -print -quit 2>/dev/null)" ]
}

# find_purge_folders - $WORK/purge: KB, kind and path of each candidate, biggest first.
find_purge_folders() {
  local p kind name_args=() name
  : >"$WORK/purge"
  dev_roots
  [ ${#DEV_ROOTS[@]} -gt 0 ] || return 0
  for name in "${PURGE_NAMES[@]}"; do name_args+=(-o -name "$name"); done
  progress "dependency and build folders"
  find "${DEV_ROOTS[@]}" -name .git -prune -o -type d \( "${name_args[@]:1}" \) -print -prune 2>/dev/null |
    while IFS= read -r p; do
      kind=$(purge_kind "$p")
      [ -n "$kind" ] || continue
      project_active "${p%/*}" && continue
      progress "$(tilde "$p")"
      printf '%s\t%s\t%s\n' "$(path_kb "$p")" "$kind" "$p"
    done | sort -nr >"$WORK/purge"
  progress_done
}

# purge_dir DIR - delete DIR itself, after checking again that it is a purgeable
# folder inside one of the project roots. Symlinks are never followed.
purge_dir() {
  local dir=$1 root inside=0
  for root in "${DEV_ROOTS[@]}"; do
    case "$dir" in "$root"/*) inside=1 ;; esac
  done
  if [ "$inside" -ne 1 ] || [ -z "$(purge_kind "$dir")" ]; then
    warn "refusing to touch $(tilde "$dir") (not a dependency or build folder in a project folder)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    note "would delete $(tilde "$dir")"
    return 0
  fi
  rm -rf "$dir" 2>/dev/null || warn "could not delete everything in $(tilde "$dir")"
}

show_purge_roots() {
  local r list=""
  for r in "${DEV_ROOTS[@]}"; do list="${list:+$list, }$(tilde "$r")"; done
  note "Looked in: ${list:-no project folders found}. Add more with --dev-dir DIR."
}

run_purge() {
  local rows=() kb kind p n total=0 before deleted=0
  find_purge_folders
  while IFS= read -r p; do rows+=("$p"); done <"$WORK/purge"

  section "Purge"
  if [ "$OLDER_THAN" -gt 0 ]; then
    note "Dependency and build folders of projects with no file changed in $OLDER_THAN days."
  else
    note "Dependency and build folders of all projects."
  fi
  show_purge_roots
  if [ ${#rows[@]} -eq 0 ]; then
    note "Nothing to purge."
    return 0
  fi
  printf '\n  %s%-3s %-10s %-13s %s%s\n' "$D" "#" "SIZE" "KIND" "FOLDER" "$N"
  for ((n = 0; n < ${#rows[@]}; n++)); do
    IFS=$'\t' read -r kb kind p <<<"${rows[n]}"
    printf '  %-3s %-10s %-13s %s\n' "$((n + 1))" "$(human "$kb")" "$kind" "$(tilde "$p")"
  done
  note "Reinstall with 'npm install', 'pip install -r requirements.txt' or a new build when you need them."

  if [ "$YES" -eq 1 ]; then
    PICKED=()
    for ((n = 0; n < ${#rows[@]}; n++)); do PICKED+=("$n"); done
  else
    if ! has_tty; then
      warn "purge needs a terminal to ask which folders to delete. Pass --yes to delete without asking."
      return 1
    fi
    pick ${#rows[@]} "numbers like 1,3 or 2-5, 'all'" || { note "Nothing deleted."; return 0; }
    for n in "${PICKED[@]}"; do total=$((total + ${rows[n]%%$'\t'*})); done
    if [ "$DRY_RUN" -eq 0 ]; then
      confirm "Delete ${#PICKED[@]} folder(s), $(human "$total")?" || { note "Nothing deleted."; return 0; }
    fi
  fi

  [ "$DRY_RUN" -eq 1 ] && note "Dry run: nothing will be changed."
  before=$(free_kb)
  for n in "${PICKED[@]}"; do
    purge_dir "${rows[n]##*$'\t'}" && deleted=$((deleted + 1))
  done
  [ "$DRY_RUN" -eq 1 ] || printf '\n  Deleted %s folder(s).' "$deleted"
  report_freed "$before"
}

# ---------------------------------------------------------------------------
# medic check
# ---------------------------------------------------------------------------

# min_free_kb - --min-free in KB. Units are decimal, like the sizes medic shows.
min_free_kb() {
  case "$MIN_FREE" in
    *%) echo $((DISK_TOTAL * ${MIN_FREE%\%} / 100)) ;;
    *)
      awk -v v="$MIN_FREE" 'BEGIN {
        u = toupper(v); sub(/B$/, "", u); n = u + 0; s = substr(u, length(u))
        m = 1
        if (s == "K") m = 1e3; else if (s == "M") m = 1e6; else if (s == "G") m = 1e9; else if (s == "T") m = 1e12
        printf "%d", n * m / 1024
      }'
      ;;
  esac
}

run_check() {
  local need disk_ok=1 mem_ok=1 status=0
  read_disk
  read_memory
  need=$(min_free_kb)
  [ "$DISK_FREE" -ge "$need" ] || disk_ok=0
  [ "$MEM_PRESSURE" != "critical" ] || mem_ok=0
  [ "$disk_ok" -eq 1 ] && [ "$mem_ok" -eq 1 ] || status=1

  if [ "$JSON" -eq 1 ]; then
    printf '{"version":%s,"os":"macos","ok":%s,"checks":[' "$(json_str "$VERSION")" "$(json_bool $((1 - status)))"
    printf '{"name":"disk","ok":%s,"free_bytes":%s,"min_free_bytes":%s},' \
      "$(json_bool "$disk_ok")" "$((DISK_FREE * 1024))" "$((need * 1024))"
    printf '{"name":"memory","ok":%s,"pressure":"%s"}]}\n' "$(json_bool "$mem_ok")" "$MEM_PRESSURE"
    return "$status"
  fi
  if [ "$disk_ok" -eq 1 ]; then printf '%sOK  %s ' "$GRN" "$N"; else printf '%sFAIL%s ' "$RED" "$N"; fi
  printf 'disk: %s free, needs %s\n' "$(human "$DISK_FREE")" "$(human "$need")"
  if [ "$mem_ok" -eq 1 ]; then printf '%sOK  %s ' "$GRN" "$N"; else printf '%sFAIL%s ' "$RED" "$N"; fi
  printf 'memory: pressure is %s\n' "$MEM_PRESSURE"
  return "$status"
}

# ---------------------------------------------------------------------------
# JSON output. Sizes are in bytes.
# ---------------------------------------------------------------------------

json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

json_bool() { if [ "$1" -eq 1 ]; then printf true; else printf false; fi; }

json_disk() {
  printf '"disks":[{"name":"/","system":true,"total_bytes":%s,"used_bytes":%s,"free_bytes":%s,"used_percent":%s}]' \
    "$((DISK_TOTAL * 1024))" "$((DISK_USED * 1024))" "$((DISK_FREE * 1024))" "$DISK_PCT"
}

json_memory() {
  local kb count name sep=""
  printf '"memory":{"total_bytes":%s,"used_bytes":%s,"cached_bytes":%s,"swap_used_bytes":%s,"swap_total_bytes":%s,"pressure":"%s","top_apps":[' \
    "$((MEM_TOTAL * 1024))" "$((MEM_USED * 1024))" "$((MEM_CACHED * 1024))" \
    "$((MEM_SWAP_USED * 1024))" "$((MEM_SWAP_TOTAL * 1024))" "$MEM_PRESSURE"
  while IFS=$'\t' read -r kb count name; do
    printf '%s{"name":%s,"bytes":%s,"processes":%s}' "$sep" "$(json_str "$name")" "$((kb * 1024))" "$count"
    sep=","
  done <"$WORK/apps"
  printf ']}'
}

json_items() {
  local i p arr sep="" psep safe=0 caution=0 review=0
  printf '"items":['
  for i in $(sorted_items); do
    printf '%s{"id":"%s","label":%s,"safety":"%s","bytes":%s,"cleanable":%s,"note":%s,"paths":[' \
      "$sep" "${ITEM_ID[i]}" "$(json_str "${ITEM_LABEL[i]}")" "${ITEM_SAFETY[i]}" "$((ITEM_KB[i] * 1024))" \
      "$([ "${ITEM_CLEAN[i]}" = "yes" ] && [ "${ITEM_SAFETY[i]}" != "REVIEW" ] && echo true || echo false)" \
      "$(json_str "${ITEM_NOTE[i]}")"
    psep=""
    IFS=: read -r -a arr <<<"${ITEM_PATHS[i]}"
    for p in "${arr[@]}"; do
      [ -e "$p" ] || continue
      printf '%s%s' "$psep" "$(json_str "$p")"
      psep=","
    done
    printf ']}'
    sep=","
    case "${ITEM_SAFETY[i]}" in
      SAFE) safe=$((safe + ITEM_KB[i])) ;;
      CAUTION) caution=$((caution + ITEM_KB[i])) ;;
      REVIEW) review=$((review + ITEM_KB[i])) ;;
    esac
  done
  printf '],"summary":{"safe_bytes":%s,"caution_bytes":%s,"review_bytes":%s}' \
    "$((safe * 1024))" "$((caution * 1024))" "$((review * 1024))"
}

# json_folders KEY FILE - KB<TAB>path lines (or KB<TAB>kind<TAB>path with "kind").
json_folders() {
  local key=$1 file=$2 with_kind=${3:-} kb kind p sep=""
  printf '"%s":[' "$key"
  if [ -n "$with_kind" ]; then
    while IFS=$'\t' read -r kb kind p; do
      printf '%s{"path":%s,"kind":%s,"bytes":%s}' "$sep" "$(json_str "$p")" "$(json_str "$kind")" "$((kb * 1024))"
      sep=","
    done <"$file"
  else
    while IFS=$'\t' read -r kb p; do
      printf '%s{"path":%s,"bytes":%s}' "$sep" "$(json_str "$p")" "$((kb * 1024))"
      sep=","
    done <"$file"
  fi
  printf ']'
}

json_large_files() {
  local kb mtime p sep=""
  printf '"large_files":['
  while IFS=$'\t' read -r kb mtime p; do
    printf '%s{"path":%s,"bytes":%s,"modified":"%s"}' "$sep" "$(json_str "$p")" "$((kb * 1024))" "$mtime"
    sep=","
  done <"$WORK/large"
  printf ']'
}

# json_report SECTION... - one JSON object with the sections that were scanned.
json_report() {
  local section
  printf '{"version":%s,"os":"macos","command":"%s"' "$(json_str "$VERSION")" "$COMMAND"
  for section in "$@"; do
    printf ','
    case "$section" in
      disk) json_disk ;;
      memory) json_memory ;;
      items) json_items ;;
      dev) json_folders dev_folders "$WORK/dev" ;;
      large) json_large_files ;;
      purge)
        printf '"purge":{"older_than_days":%s,"roots":[' "$OLDER_THAN"
        local r sep=""
        for r in "${DEV_ROOTS[@]}"; do printf '%s%s' "$sep" "$(json_str "$r")"; sep=","; done
        printf '],'
        json_folders folders "$WORK/purge" kind
        printf '}'
        ;;
    esac
  done
  printf '}\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

header() {
  [ "$JSON" -eq 1 ] || [ "$COMMAND" = "check" ] && return 0
  printf '%smedic %s%s %s- %s, macOS %s%s\n' "$B" "$VERSION" "$N" "$D" "$(scutil --get ComputerName 2>/dev/null || hostname)" "$(sw_vers -productVersion)" "$N"
  case "$COMMAND" in
    clean | purge) [ "$DRY_RUN" -eq 1 ] && note "Dry run: shows what would happen, changes nothing." ;;
    *) note "Read-only. Nothing is deleted unless you run '$PROG clean' or '$PROG purge' and confirm." ;;
  esac
  case "$COMMAND" in
    report | disk | clean)
      if [ -d "$HOME/Library/Safari" ] && ! ls "$HOME/Library/Safari" >/dev/null 2>&1; then
        warn "Your terminal has no Full Disk Access, so Trash and Mail sizes may show as empty."
        note "Grant it in System Settings > Privacy & Security > Full Disk Access for complete results."
      fi
      ;;
  esac
}

# storage_report WITH_MEMORY - the report and disk commands.
storage_report() {
  local with_memory=$1 sections=(disk)
  read_disk
  [ "$JSON" -eq 1 ] || show_disk
  if [ "$with_memory" -eq 1 ]; then
    read_memory
    [ "$JSON" -eq 1 ] || show_memory
    sections+=(memory)
  fi
  collect_items
  measure_items
  sections+=(items)
  if [ "$JSON" -eq 0 ]; then
    show_items
    show_commands
  fi
  if [ "$QUICK" -eq 0 ]; then
    [ "$JSON" -eq 1 ] || show_breakdowns
    find_dev_folders
    find_large_files
    sections+=(dev large)
    if [ "$JSON" -eq 0 ]; then
      show_dev_folders
      show_large_files
    fi
  fi
  if [ "$JSON" -eq 1 ]; then
    json_report "${sections[@]}"
  else
    show_system_info
    show_summary
  fi
}

header
case "$COMMAND" in
  report) storage_report 1 ;;
  disk) storage_report 0 ;;
  memory)
    read_memory
    if [ "$JSON" -eq 1 ]; then json_report memory; else show_memory; fi
    ;;
  clean)
    collect_items
    [ -z "$ONLY" ] || check_only
    measure_items
    run_clean || exit 1
    ;;
  purge)
    if [ "$JSON" -eq 1 ]; then
      find_purge_folders
      json_report purge
    else
      run_purge || exit 1
    fi
    ;;
  check) run_check || exit 1 ;;
esac
exit 0
