#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
    --build-only|run|--verify|--debug|--logs|--telemetry) ;;
    *) echo "usage: $0 [--build-only|run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
# Set ICE_SIGN_IDENTITY to a Developer ID identity for a stable, trusted local signature.
SIGN_IDENTITY="${ICE_SIGN_IDENTITY:--}"
CONFIGURATION="${ICE_BUILD_CONFIGURATION:-Debug}"
INJECT_DEBUG_ENTITLEMENTS=YES
if [[ "$CONFIGURATION" == Release ]]; then INJECT_DEBUG_ENTITLEMENTS=NO; fi
SIGN_FLAGS=()
if [[ "$SIGN_IDENTITY" != - ]]; then SIGN_FLAGS+=("OTHER_CODE_SIGN_FLAGS=--timestamp"); fi
xcodebuild -project "$ROOT_DIR/Ice.xcodeproj" -scheme Ice -configuration "$CONFIGURATION" \
    -derivedDataPath "$ROOT_DIR/build/native-derived" \
    -clonedSourcePackagesDirPath "$ROOT_DIR/build/SourcePackages" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS="$INJECT_DEBUG_ENTITLEMENTS" \
    ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} build
APP_PATH="$ROOT_DIR/build/native-derived/Build/Products/$CONFIGURATION/Ice.app"
if [[ "$MODE" == --build-only ]]; then
    echo "$APP_PATH"
    exit 0
fi
pkill -x Ice || true
case "$MODE" in
    --debug) lldb -- "$APP_PATH/Contents/MacOS/Ice" ;;
    *)
        open -n "$APP_PATH"
        case "$MODE" in
            --verify) sleep 2; pgrep -x Ice ;;
            --logs) /usr/bin/log stream --info --style compact --predicate 'process == "Ice"' ;;
            --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.jordanbaird.Ice"' ;;
        esac
        ;;
esac
