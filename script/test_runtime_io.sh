#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Every module, executable and runtime fixture lives in this invocation's private
# temporary directory. Neither SwiftPM nor the app's build output is touched.
python3 - "$PWD" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="longhaul-runtime-io-") as directory:
    temporary = Path(directory)
    subprocess.run(['swift', 'build', '--scratch-path', str(temporary / 'swiftpm'),
                    '--target', 'LonghaulBridge'], check=True, timeout=180)
    debug = temporary / 'swiftpm/arm64-apple-macosx/debug'
    objects = [str(p) for target in ['LonghaulCore', 'LonghaulBridge', 'CLonghaulSupport']
               for p in (debug / (target + '.build')).glob('*.o')]
    binary = temporary / "runtime-io-harness"
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos26.0',
        '-parse-as-library', '-I', str(debug / 'Modules'),
        '-I', str(debug / 'CLonghaulSupport.build'), *objects,
        '-framework', 'AppKit', '-framework', 'IOKit', '-lsqlite3',
        '-import-objc-header', str(root / 'App/Support/Longhaul-Bridging-Header.h'),
        str(root / 'App/Services/Journal.swift'),
        str(root / 'App/Services/CodexActivityMonitor.swift'),
        str(root / 'App/Services/RuntimeIO.swift'),
        str(root / 'Tests/RuntimeIORecoveryHarness.swift'),
        '-o', str(binary),
    ], check=True, timeout=60)
    fixtures = temporary / "fixtures"
    fixtures.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(fixtures) + "/")
    subprocess.run([str(binary)], env=environment, check=True, timeout=30)
    subprocess.run([str(binary), "--fifo-probe"], env=environment, check=True, timeout=5)
PY
