#!/bin/bash
# Bounded fixtures only. Physical power qualification is a separate attended test.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/longhaul-suite.XXXXXX")"
# This invocation owns only regenerable compiler output in this directory.
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swift test --scratch-path "$TEST_BUILD_DIR"
swift build --scratch-path "$TEST_BUILD_DIR" --product longhaul
DEBUG_PATH="$(swift build --scratch-path "$TEST_BUILD_DIR" --show-bin-path)"
python3 script/test_hooks.py "$DEBUG_PATH/longhaul"
./script/test_integration_setup.sh
./script/test_runtime_io.sh
python3 script/test_lid_probe_runner.py
python3 script/test_lid_session_runner.py
python3 script/test_lid_app_service.py --debug-path "$DEBUG_PATH"
python3 script/test_codex_activity_monitor.py --debug-path "$DEBUG_PATH"
python3 script/test_lid_continuity_verifier.py
python3 script/test_lid_session_verifier.py
python3 script/check_source.py
