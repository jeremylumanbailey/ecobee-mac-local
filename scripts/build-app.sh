#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${ECOBEE_BUILD_ROOT:-$PROJECT/.build-app}"
APP="${ECOBEE_APP_OUTPUT:-$PROJECT/dist/Ecobee Local.app}"
PYTHON="${ECOBEE_BUILD_PYTHON:-$BUILD_ROOT/venv/bin/python}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${ECOBEE_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK" ]]; then SDK="$(xcrun --show-sdk-path)"; fi
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/swift-cache"
export PYINSTALLER_CONFIG_DIR="$BUILD_ROOT/pyinstaller-cache"
mkdir -p "$BUILD_ROOT"
if [[ ! -x "$PYTHON" ]]; then
    python3 -m venv "$BUILD_ROOT/venv"
    "$PYTHON" -m pip install -r "$PROJECT/helper/requirements.lock"
fi
swift build -c release --product EcobeeMac --arch arm64 --sdk "$SDK" --package-path "$PROJECT" --scratch-path "$BUILD_ROOT/swift" --disable-sandbox
BIN="$(swift build -c release --arch arm64 --sdk "$SDK" --package-path "$PROJECT" --scratch-path "$BUILD_ROOT/swift" --disable-sandbox --show-bin-path)"
if [[ -z "${ECOBEE_HELPER_DIST:-}" ]]; then
    "$PYTHON" -m PyInstaller --noconfirm --onedir --target-arch arm64 --name HAPHelper \
        --distpath "$BUILD_ROOT/helper-dist" --workpath "$BUILD_ROOT/helper-build" --specpath "$BUILD_ROOT" \
        --collect-all aiohomekit --collect-all zeroconf --copy-metadata aiohomekit "$PROJECT/helper/hap_helper.py"
    HELPER_DIST="$BUILD_ROOT/helper-dist/HAPHelper"
else
    HELPER_DIST="$ECOBEE_HELPER_DIST"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EcobeeMac" "$APP/Contents/MacOS/EcobeeMac"
ditto "$HELPER_DIST" "$APP/Contents/Resources/HAPHelper"
cp "$PROJECT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$PROJECT/AppIcon.icns" ]]; then cp "$PROJECT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
cp "$PROJECT/README.md" "$APP/Contents/Resources/README.md"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
"$PYTHON" "$PROJECT/scripts/licenses.py" "$APP/Contents/Resources/ThirdPartyLicenses"
# Local ad-hoc signing. Use a Developer ID identity and notarization before public distribution.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/EcobeeMac" "$APP/Contents/Resources/HAPHelper/HAPHelper"
printf 'Built: %s\n' "$APP"
