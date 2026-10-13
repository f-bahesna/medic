#!/usr/bin/env bash
#
# Installs medic for macOS as a command you can run from any folder:
#
#   curl -fsSL https://github.com/f-bahesna/medic/releases/latest/download/install.sh | bash
#
# Pass options after "bash -s --", for example "| bash -s -- --uninstall".
# Installs for your user only, no sudo. It writes the medic command into
# ~/.local/bin and, once, a PATH line into your shell profile if needed.
#
# License: MIT

set -euo pipefail

REPO="f-bahesna/medic"
BIN_DIR="$HOME/.local/bin"
VERSION=""
FROM=""
MODIFY_PATH=1
MODE="install"

usage() {
  cat <<EOF
Installs medic for macOS as a command you can run from any folder.

Usage: install.sh [options]

Options:
  --version TAG     Install this release (for example v0.3.0) instead of the latest
  --dir DIR         Install into DIR instead of ~/.local/bin
  --no-modify-path  Do not add DIR to PATH in your shell profile
  --link            Link to macos/medic.sh in this checkout, for working on medic
  --from URL|DIR    Download the release files from here instead of GitHub (mirrors, tests)
  --uninstall       Remove medic
  -h, --help        Show this help
EOF
}

die() {
  printf 'medic install: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; VERSION=${1:-}; [ -n "$VERSION" ] || die "--version needs a release tag, like v0.3.0" ;;
    --dir) shift; BIN_DIR=${1:-}; [ -n "$BIN_DIR" ] || die "--dir needs a folder" ;;
    --no-modify-path) MODIFY_PATH=0 ;;
    --link) MODE="link" ;;
    --from) shift; FROM=${1:-}; [ -n "$FROM" ] || die "--from needs a URL or a folder" ;;
    --uninstall) MODE="uninstall" ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "this installs the macOS version. On Windows, use install.ps1 from PowerShell instead"
[ "$(id -u)" -ne 0 ] || die "do not run with sudo; medic installs for your user only"
case "$BIN_DIR" in /*) ;; *) BIN_DIR="$PWD/$BIN_DIR" ;; esac
TARGET="$BIN_DIR/medic"

tilde() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fetch NAME DEST - one release file, from GitHub, a mirror or a local folder.
fetch() {
  local base
  if [ -n "$FROM" ] && [ -d "$FROM" ]; then
    cp "$FROM/$1" "$2" || die "cannot copy $1 from $FROM"
    return
  fi
  if [ -n "$FROM" ]; then
    base=$FROM
  elif [ -n "$VERSION" ]; then
    base="https://github.com/$REPO/releases/download/$VERSION"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  curl -fsSL --proto '=https' --tlsv1.2 "$base/$1" -o "$2" || die "cannot download $base/$1"
}

# verify FILE SUMS - FILE must match its line in the SHA256SUMS file.
verify() {
  local name expected actual
  name=$(basename "$1")
  expected=$(awk -v f="$name" '{ n = $2; sub(/^\*/, "", n) } n == f { print tolower($1) }' "$2")
  actual=$(shasum -a 256 "$1" | awk '{ print $1 }')
  [ -n "$expected" ] || die "SHA256SUMS has no entry for $name"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $name, refusing to install it"
}

# The profile a new terminal reads, for the shell this user logs in with.
shell_profile() {
  case "${SHELL:-}" in
    */zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash) printf '%s' "$HOME/.bash_profile" ;;
  esac
}

add_to_path() {
  local profile line dir_expr
  case ":$PATH:" in *":$BIN_DIR:"*) return ;; esac
  case "$BIN_DIR" in
    "$HOME"/*) dir_expr="\$HOME${BIN_DIR#"$HOME"}" ;;
    *) dir_expr=$BIN_DIR ;;
  esac
  line="export PATH=\"$dir_expr:\$PATH\""
  profile=$(shell_profile)
  if [ "$MODIFY_PATH" -eq 0 ] || [ -z "$profile" ]; then
    printf '\n%s is not on your PATH yet. Add this line to your shell profile:\n  %s\n' "$(tilde "$BIN_DIR")" "$line"
    return
  fi
  if ! grep -qxF "$line" "$profile" 2>/dev/null; then
    printf '\n# Added by the medic installer\n%s\n' "$line" >>"$profile"
    printf 'Added %s to PATH in %s.\n' "$(tilde "$BIN_DIR")" "$(tilde "$profile")"
  fi
  printf 'Open a new terminal window, or run this once to use medic right away:\n  %s\n' "$line"
}

# Warn when another "medic" earlier on PATH would run instead of this one.
check_shadowed() {
  local found
  found=$(command -v medic 2>/dev/null || true)
  if [ -n "$found" ] && [ "$found" != "$TARGET" ]; then
    printf '\nNote: %s comes earlier on your PATH and runs instead of this medic.\n' "$found"
  fi
}

is_medic() { [ -f "$1" ] && head -n 5 "$1" | grep -q '^# medic for macOS'; }

install_release() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/medic-install.XXXXXX") || die "cannot create a temp directory"
  # shellcheck disable=SC2064 # expand $tmp now, it is local
  trap "rm -rf '$tmp'" EXIT
  fetch SHA256SUMS "$tmp/SHA256SUMS"
  fetch medic.sh "$tmp/medic.sh"
  verify "$tmp/medic.sh" "$tmp/SHA256SUMS"
  /bin/bash -n "$tmp/medic.sh" || die "the downloaded medic.sh does not parse, refusing to install it"

  mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  if [ -e "$TARGET" ] && ! [ -L "$TARGET" ] && ! is_medic "$TARGET"; then
    die "$(tilde "$TARGET") already exists and is not medic, leaving it alone"
  fi
  # Copy next to the target and rename, so a running medic is never half-written.
  if ! { cp "$tmp/medic.sh" "$BIN_DIR/.medic.new" && chmod 755 "$BIN_DIR/.medic.new" && mv -f "$BIN_DIR/.medic.new" "$TARGET"; }; then
    rm -f "$BIN_DIR/.medic.new"
    die "cannot write $TARGET"
  fi
  printf 'Installed %s to %s.\n' "$("$TARGET" --version)" "$(tilde "$TARGET")"
}

install_link() {
  local src
  src="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/macos/medic.sh"
  [ -f "$src" ] || die "--link needs to run from a medic checkout: bash install.sh --link"
  mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  if [ -e "$TARGET" ] && ! [ -L "$TARGET" ] && ! is_medic "$TARGET"; then
    die "$(tilde "$TARGET") already exists and is not medic, leaving it alone"
  fi
  ln -sfn "$src" "$TARGET" || die "cannot link $TARGET"
  printf 'Linked %s to %s.\n' "$(tilde "$TARGET")" "$(tilde "$src")"
}

uninstall() {
  local profile
  if [ -L "$TARGET" ] || is_medic "$TARGET"; then
    rm -f "$TARGET"
    printf 'Removed %s.\n' "$(tilde "$TARGET")"
    profile=$(shell_profile)
    if [ -n "$profile" ] && grep -q '^# Added by the medic installer$' "$profile" 2>/dev/null; then
      printf 'The PATH line in %s is left in place, other tools may use %s too.\n' "$(tilde "$profile")" "$(tilde "$BIN_DIR")"
    fi
  elif [ -e "$TARGET" ]; then
    die "$(tilde "$TARGET") is not medic, leaving it alone"
  else
    printf 'medic is not installed in %s.\n' "$(tilde "$BIN_DIR")"
  fi
}

case "$MODE" in
  install) install_release; add_to_path; check_shadowed; printf '\nRun: medic\n' ;;
  link) install_link; add_to_path; check_shadowed ;;
  uninstall) uninstall ;;
esac
