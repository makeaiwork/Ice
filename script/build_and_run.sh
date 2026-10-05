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
xcodebuild -project "$ROOT_DIR/Ice.xcodeproj" -scheme Ice -configuration Debug \
    -derivedDataPath "$ROOT_DIR/build/native-derived" \
    -clonedSourcePackagesDirPath "$ROOT_DIR/build/SourcePackages" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=YES build
APP_PATH="$ROOT_DIR/build/native-derived/Build/Products/Debug/Ice.app"
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
