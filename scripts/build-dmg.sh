#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

# By default build from source. Set ECOBEE_DMG_APP only to package an already verified app.
if [[ -n "${ECOBEE_DMG_APP:-}" ]]; then
    APP="$ECOBEE_DMG_APP"
else
    bash "$PROJECT/scripts/build-app.sh"
    APP="${ECOBEE_APP_OUTPUT:-$PROJECT/dist/Ecobee Local.app}"
fi
[[ -d "$APP" ]] || { echo "App bundle not found: $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
OUTPUT="${ECOBEE_DMG_OUTPUT:-$PROJECT/dist/Ecobee-Local-$VERSION-arm64.dmg}"
mkdir -p "$(dirname "$OUTPUT")"
[[ ! -e "$OUTPUT" && ! -e "$OUTPUT.sha256" ]] || { echo "Release output already exists: $OUTPUT" >&2; exit 1; }

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/ecobee-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Ecobee Local.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install.txt" <<EOF
Ecobee Local $VERSION — Apple Silicon

Requires an Apple Silicon Mac (M1 or later) running macOS $MINIMUM or later.

1. Drag Ecobee Local.app onto the Applications shortcut.
2. Eject this disk image and open Ecobee Local from Applications.
3. Allow local-network access and pair your own thermostat using its HomeKit code.

Python and the connection helper are included. No separate Python installation,
Ecobee developer API key, iPhone, or Apple home hub is needed for local control.
Pairing is stored in your Mac's Keychain; this download includes no saved pairing.

This is an ad-hoc-signed testing build, not an Apple-notarized public release.
macOS may block the downloaded app. Review Apple's guidance before deciding
whether to open software from an unidentified developer:
https://support.apple.com/102445
Do not disable Gatekeeper or other system-wide security protections.

Normal timed fan runs require the app open and the Mac awake. The experimental
thermostat deadline test is a development feature, not general fan scheduling.

Independent app, not made by or affiliated with ecobee.
Source: https://github.com/jeremylumanbailey/ecobee-mac-local
EOF

hdiutil create -volname "Ecobee Local $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
(cd "$(dirname "$OUTPUT")" && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
printf 'Created testing DMG: %s\nChecksum: %s.sha256\n' "$OUTPUT" "$OUTPUT"
