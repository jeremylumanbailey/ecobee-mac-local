#!/bin/bash
# Standalone runners work with Command Line Tools; no XCTest or Keychain access required.
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$PROJECT/.build-app/tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SDK="${ECOBEE_SDK:-$DEVELOPER_DIR/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK" ]]; then SDK="$(xcrun --show-sdk-path)"; fi
PYTHON="${ECOBEE_TEST_PYTHON:-${ECOBEE_BUILD_PYTHON:-$PROJECT/.build-app/venv/bin/python}}"
[[ -x "$PYTHON" ]] || { echo "Set ECOBEE_TEST_PYTHON to the app's build-environment Python." >&2; exit 1; }
mkdir -p "$BUILD"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-cache"
export SWIFT_MODULECACHE_PATH="$BUILD/swift-cache"
COVERAGE=$(mktemp -d "$BUILD/coverage.XXXXXX")
export LLVM_PROFILE_FILE="$COVERAGE/%p-%m.profraw"
FLAGS=(-sdk "$SDK" -g -Onone -profile-generate -profile-coverage-mapping)
swiftc "${FLAGS[@]}" -emit-library -emit-module -module-name LocalCore \
    "$PROJECT"/Sources/LocalCore/*.swift -emit-module-path "$BUILD/LocalCore.swiftmodule" \
    -o "$BUILD/libLocalCore.dylib" -Xlinker -install_name -Xlinker @rpath/libLocalCore.dylib
LINK=(-I "$BUILD" -L "$BUILD" -lLocalCore -Xlinker -rpath -Xlinker "$BUILD")
swiftc "${FLAGS[@]}" "${LINK[@]}" "$PROJECT/Tests/LocalCoreTests/main.swift" -o "$BUILD/local-core-checks"
swiftc "${FLAGS[@]}" "${LINK[@]}" -parse-as-library \
    "$PROJECT/Sources/EcobeeMac/AppDependencies.swift" \
    "$PROJECT/Sources/EcobeeMac/AppModel.swift" \
    "$PROJECT/Sources/EcobeeMac/BonjourDiscovery.swift" \
    "$PROJECT/Sources/EcobeeMac/HelperConnection.swift" \
    "$PROJECT/Sources/EcobeeMac/PairingStore.swift" \
    "$PROJECT/Tests/AppTests/Checks.swift" -o "$BUILD/app-checks"
"$BUILD/local-core-checks"
TEST_PYTHON="$PYTHON" TEST_HELPER_SCRIPT="$PROJECT/Tests/AppTests/fake_helper.py" "$BUILD/app-checks"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$PROJECT/Tests/run_python_tests.py" "$COVERAGE" | tee "$COVERAGE/python-summary.txt"
xcrun llvm-profdata merge -sparse "$COVERAGE"/*.profraw -o "$COVERAGE/swift.profdata"
xcrun llvm-cov report "$BUILD/app-checks" -object "$BUILD/local-core-checks" -object "$BUILD/libLocalCore.dylib" \
    -instr-profile="$COVERAGE/swift.profdata" -ignore-filename-regex='/Tests/' | tee "$COVERAGE/swift-summary.txt"
xcrun llvm-cov show "$BUILD/app-checks" -object "$BUILD/local-core-checks" -object "$BUILD/libLocalCore.dylib" \
    -instr-profile="$COVERAGE/swift.profdata" -ignore-filename-regex='/Tests/' \
    -format=html -output-dir="$COVERAGE/swift-html" > /dev/null
printf '%s\n' "$COVERAGE" > "$BUILD/latest-coverage-path.txt"
printf 'Coverage reports: %s\n' "$COVERAGE"
