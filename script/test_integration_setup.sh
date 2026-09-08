#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/longhaul-integration-harness.XXXXXX")"
# This directory is exclusively disposable output created by this invocation.
trap 'rm -rf "$build_dir"' EXIT
swift build --scratch-path "$build_dir/swiftpm" --target LonghaulBridge
debug="$build_dir/swiftpm/arm64-apple-macosx/debug"
objects=("$debug"/LonghaulCore.build/*.o "$debug"/LonghaulBridge.build/*.o "$debug"/CLonghaulSupport.build/*.o)
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 \
  -I "$debug/Modules" -I "$debug/CLonghaulSupport.build" "${objects[@]}" \
  -framework AppKit -framework IOKit \
  App/Services/LocalProcess.swift App/Services/IntegrationSetup.swift \
  Tests/IntegrationSetupHarness.swift -o "$build_dir/integration-setup-harness"
"$build_dir/integration-setup-harness"
