#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source_app="${1:-/Applications/ChatGPT.app}"
applications="${CODEX_LAUNCHER_INSTALL_DIR:-$HOME/Applications}"
launcher="$applications/Codex Third Party.app"
desktop_root="$applications/.codex-thirdparty"
desktop="$desktop_root/ChatGPT.app"

if [[ $# -gt 1 || ! -f "$source_app/Contents/Info.plist" ]]; then
  printf 'Usage: %s [path-to-official-ChatGPT.app]\n' "$0" >&2
  exit 1
fi
if [[ -e "$launcher" || -L "$launcher" ]]; then
  printf 'A launcher is already installed at %s. Move it aside before installing.\n' "$launcher" >&2
  exit 1
fi
openai_signature='anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'
/usr/bin/codesign --verify --deep --strict -R="$openai_signature" "$source_app"
"$root/scripts/build.sh"
/bin/mkdir -p "$applications" "$desktop_root"

staging=$(/usr/bin/mktemp -d "$applications/.codex-launcher-install.XXXXXX")
if [[ ! -e "$desktop" ]]; then
  /bin/cp -cRp "$source_app" "$staging/ChatGPT.app" ||
    /usr/bin/ditto "$source_app" "$staging/ChatGPT.app"
  /usr/bin/codesign --verify --deep --strict -R="$openai_signature" "$staging/ChatGPT.app"
  /bin/mv "$staging/ChatGPT.app" "$desktop"
else
  /usr/bin/codesign --verify --deep --strict -R="$openai_signature" "$desktop"
fi
/usr/bin/ditto "$root/dist/Codex Third Party.app" "$staging/Codex Third Party.app"
/bin/mv "$staging/Codex Third Party.app" "$launcher"
/bin/rmdir "$staging"
printf 'Installed %s\n' "$launcher"
