#!/usr/bin/env bash
# Runs the menu bar app's unit tests. With only the Command Line Tools and no
# Xcode, Swift Testing is not on the default search paths, so pass them in.
set -euo pipefail
cd "$(dirname "$0")"
flags=()
dev=$(xcode-select -p)
if [[ "$dev" == */CommandLineTools ]]; then
  fw="$dev/Library/Developer/Frameworks"
  flags=(-Xswiftc -F -Xswiftc "$fw" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xlinker -F -Xlinker "$fw" -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$dev/Library/Developer/usr/lib")
fi
swift test ${flags[@]+"${flags[@]}"} "$@"
