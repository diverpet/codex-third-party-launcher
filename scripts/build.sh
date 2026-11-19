#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
set --
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
  set -- --build-system "$SWIFT_BUILD_SYSTEM"
fi
if [[ -n "${CODEX_LAUNCHER_ARCH:-}" ]]; then
  set -- "$@" --arch "$CODEX_LAUNCHER_ARCH" --scratch-path "$root/.build/$CODEX_LAUNCHER_ARCH"
fi
swift build "$@" --configuration release --product Launcher
bin=$(swift build "$@" --configuration release --show-bin-path)
output_dir=${CODEX_LAUNCHER_OUTPUT_DIR:-"$root/dist"}
app="$output_dir/Codex Third Party.app"

/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/bin/cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
/bin/cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
if [[ -n "${CODEX_LAUNCHER_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$CODEX_LAUNCHER_VERSION" "$app/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$CODEX_LAUNCHER_VERSION" "$app/Contents/Info.plist"
fi
/usr/bin/install -m 755 "$bin/Launcher" "$app/Contents/MacOS/Launcher"
architecture=${CODEX_LAUNCHER_ARCH:-$(uname -m)}
if [[ "$architecture" == x86_64 ]]; then architecture=amd64; fi
proxy="$app/Contents/MacOS/GatewayProxy"
(cd "$root/Proxy" && CGO_ENABLED=0 GOOS=darwin GOARCH="$architecture" go build -trimpath -buildvcs=false -o "$proxy" .)
/usr/bin/plutil -lint "$app/Contents/Info.plist"
if [[ -n "${CODEX_APPLICATION_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$CODEX_APPLICATION_SIGN_IDENTITY" --options runtime --timestamp "$proxy"
  /usr/bin/codesign --force --sign "$CODEX_APPLICATION_SIGN_IDENTITY" --options runtime --timestamp "$app"
else
  /usr/bin/codesign --force --sign - "$proxy"
  /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
