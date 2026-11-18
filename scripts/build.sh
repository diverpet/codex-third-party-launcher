#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
set --
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
  set -- --build-system "$SWIFT_BUILD_SYSTEM"
fi
swift build "$@" --configuration release --product Launcher
bin=$(swift build "$@" --configuration release --show-bin-path)
app="$root/dist/Codex Third Party.app"

/bin/mkdir -p "$app/Contents/MacOS"
/bin/cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/bin/install -m 755 "$bin/Launcher" "$app/Contents/MacOS/Launcher"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
