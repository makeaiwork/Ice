#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ice-native-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$ROOT_DIR/build/ModuleCache" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/NativeMenuBarPolicy.swift" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/NativeMenuBarOrder.swift" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/NativeMenuBarOperation.swift" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/NativeMenuBarMigration.swift" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/NativeMenuBarVisibilityRequest.swift" \
    "$ROOT_DIR/Ice/MenuBar/Compatibility/MenuBarVisibilityAssertion.swift" \
    "$ROOT_DIR/Tests/NativeMenuBarPolicyTests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
