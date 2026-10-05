#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="ice-build-script-test-") as directory:
    folder = pathlib.Path(directory)
    (folder / "xcodebuild").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ICE_TEST_ARGUMENTS"\nexit "${ICE_TEST_XCODE_EXIT:-0}"\n')
    for name in ("open", "pkill"):
        (folder / name).write_text('#!/bin/sh\nprintf "%s\\n" "' + name + '" >> "$ICE_TEST_ACTIONS"\n')
    for executable in folder.iterdir():
        executable.chmod(0o755)
    cases = [
        ("default build", ["--build-only"], {}, 0),
        ("signed debug", ["--build-only"], {"ICE_SIGN_IDENTITY": "Review Identity"}, 0),
        ("signed release", ["--build-only"], {"ICE_SIGN_IDENTITY": "Review Identity", "ICE_BUILD_CONFIGURATION": "Release"}, 0),
        ("default Run", [], {}, 0),
        ("failed Run", [], {"ICE_TEST_XCODE_EXIT": "42"}, 42),
    ]
    for label, arguments, overrides, expected_exit in cases:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ICE_")}
        environment.update(PATH=str(folder) + ":/usr/bin:/bin", ICE_TEST_ARGUMENTS=str(folder / "arguments"), ICE_TEST_ACTIONS=str(folder / "actions"))
        environment.update(overrides)
        (folder / "actions").write_text("")
        result = subprocess.run(["/bin/bash", str(root / "script/build_and_run.sh"), *arguments], cwd=root, env=environment, capture_output=True, text=True)
        assert result.returncode == expected_exit, (label, result.stderr)
        build_arguments = (folder / "arguments").read_text().splitlines()
        identity = overrides.get("ICE_SIGN_IDENTITY", "-")
        assert "CODE_SIGN_IDENTITY=" + identity in build_arguments, label
        assert ("OTHER_CODE_SIGN_FLAGS=--timestamp" in build_arguments) == (identity != "-"), label
        injected = "NO" if overrides.get("ICE_BUILD_CONFIGURATION") == "Release" else "YES"
        assert "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=" + injected in build_arguments, label
        expected_actions = ["pkill", "open"] if not arguments and expected_exit == 0 else []
        assert (folder / "actions").read_text().splitlines() == expected_actions, label
    print(f"{len(cases)} build script checks passed (no real build, launch or process termination)")
PY
