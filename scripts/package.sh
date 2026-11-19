#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
version=${1:-}
if [[ $# -ne 1 || ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'Usage: %s MAJOR.MINOR.PATCH\n' "$0" >&2
  exit 2
fi
if [[ -n "${CODEX_APPLICATION_SIGN_IDENTITY:-}" && -z "${CODEX_INSTALLER_SIGN_IDENTITY:-}" ]] ||
   [[ -z "${CODEX_APPLICATION_SIGN_IDENTITY:-}" && -n "${CODEX_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  printf 'Set both Developer ID signing identities for a release package.\n' >&2
  exit 2
fi

CODEX_LAUNCHER_VERSION="$version" CODEX_LAUNCHER_ARCH=arm64 "$root/scripts/build.sh"
app="$root/dist/Codex Third Party.app"
/usr/bin/lipo "$app/Contents/MacOS/Launcher" -verify_arch arm64
/usr/bin/lipo "$app/Contents/MacOS/GatewayProxy" -verify_arch arm64

staging=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$staging"' EXIT
payload="$staging/payload"
/bin/mkdir -p "$payload"
/usr/bin/ditto "$app" "$payload/Codex Third Party.app"

identifier=io.github.diverpet.codex-third-party-launcher.pkg
component=Launcher.pkg
components="$staging/components.plist"
/usr/bin/pkgbuild --analyze --root "$payload" "$components"
if /usr/libexec/PlistBuddy -c 'Print :0:BundleIsRelocatable' "$components" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$components"
else
  /usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$components"
fi
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked true' "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$components"
/usr/bin/pkgbuild --root "$payload" --component-plist "$components" --identifier "$identifier" \
  --version "$version" --install-location /Applications "$staging/$component"

cat > "$staging/Distribution.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Codex Third Party</title>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="launcher"/></choices-outline>
  <choice id="launcher" visible="false"><pkg-ref id="$identifier"/></choice>
  <pkg-ref id="$identifier" version="$version">$component</pkg-ref>
</installer-gui-script>
EOF

set -- --distribution "$staging/Distribution.xml" --package-path "$staging"
if [[ -n "${CODEX_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  set -- "$@" --sign "$CODEX_INSTALLER_SIGN_IDENTITY"
fi
package="Codex-Third-Party-${version}-arm64.pkg"
/usr/bin/productbuild "$@" "$staging/$package"
/bin/mv "$staging/$package" "$root/dist/$package"
printf '%s\n' "$root/dist/$package"
