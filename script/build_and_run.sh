#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
MODE="${1:-run}"
CONFIGURATION="${LONGHAUL_CONFIGURATION:-Debug}"
SWIFT_CONFIGURATION=debug
if [ "$CONFIGURATION" = "Release" ]; then SWIFT_CONFIGURATION=release; fi
mkdir -p build dist
BUILD_DIR="${LONGHAUL_BUILD_DIR:-$HOME/Library/Caches/Longhaul/Build}"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/Build/Products/$CONFIGURATION/Longhaul.app"
# Check before Xcode or copy/sign steps can modify a previously launched product.
python3 - "$APP" <<'PY'
import ctypes, os, subprocess, sys
from pathlib import Path
destination = str(Path(sys.argv[1]).resolve()) + '/'
libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
for name in ['Longhaul', 'longhaul', 'LonghaulCompanion']:
    result = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', name], capture_output=True, text=True)
    for pid in result.stdout.split():
        buffer = ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid), buffer, len(buffer)) <= 0:
            try: os.kill(int(pid), 0)
            except ProcessLookupError: continue
            raise SystemExit('Cannot identify a running Longhaul process; refusing to modify the build destination.')
        executable = os.fsdecode(buffer.value)
        if executable and str(Path(executable).resolve()).startswith(destination):
            raise SystemExit('Build destination is running. Use a fresh LONGHAUL_BUILD_DIR or perform a controlled quit first.')
PY
swift build -c "$SWIFT_CONFIGURATION" --product longhaul
swift build -c "$SWIFT_CONFIGURATION" --product LonghaulCompanion
xcodegen generate --quiet
xcodebuild -project Longhaul.xcodeproj -scheme Longhaul -configuration "$CONFIGURATION" -derivedDataPath "$BUILD_DIR" build >build/xcodebuild.log 2>&1 || { rg 'error:|warning:|BUILD FAILED' build/xcodebuild.log; exit 1; }
APP="$BUILD_DIR/Build/Products/$CONFIGURATION/Longhaul.app"
mkdir -p "$APP/Contents/Resources/bin"
cp -X "$(swift build -c "$SWIFT_CONFIGURATION" --show-bin-path)/longhaul" "$APP/Contents/Resources/bin/longhaul"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp -X "$(swift build -c "$SWIFT_CONFIGURATION" --show-bin-path)/LonghaulCompanion" "$APP/Contents/MacOS/LonghaulCompanion"
cp -X Resources/space.exlumina.longhaul.companion.plist "$APP/Contents/Library/LaunchAgents/"
# Folder resources must not convey interpreter caches or development metadata.
python3 - "$APP/Contents/Resources" <<'PY'
from pathlib import Path
import shutil, sys
root = Path(sys.argv[1])
for path in root.rglob('__pycache__'):
    if path.is_dir():
        shutil.rmtree(path)  # Regenerable cache in this build's app bundle only.
for path in root.rglob('*'):
    if path.is_file() and (path.suffix == '.pyc' or path.name == '.DS_Store'):
        path.unlink()  # Disposable metadata copied into the build, never source.
PY
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Longhaul" "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Longhaul" "$APP/Contents/Info.plist"
SOURCE_COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || echo uncommitted)"
/usr/bin/plutil -replace LonghaulSourceCommit -string "$SOURCE_COMMIT" "$APP/Contents/Info.plist"
codesign --force --identifier space.exlumina.longhaul.companion --sign - "$APP/Contents/MacOS/LonghaulCompanion"
codesign --force --sign - "$APP/Contents/Resources/bin/longhaul"
codesign --force --sign - "$APP"
if [ "$MODE" = "--build-only" ]; then exit 0; fi
# Never replace a live closed-lid owner before its normal cleanup has completed.
check_cleanup() { python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ.get('LONGHAUL_DATA_DIR', str(Path.home() / 'Library/Application Support/Longhaul')))
ledger = root / 'lid-current-session.json'
if ledger.exists():
    try:
        stage = json.loads(ledger.read_text()).get('stage')
    except (ValueError, OSError):
        raise SystemExit('Cannot verify closed-lid cleanup. Inspect Longhaul before relaunching.')
    if stage != 'cleanupAccepted':
        raise SystemExit('Open the lid and pause Longhaul; wait for confirmed cleanup before relaunching. Build succeeded.')
PY
}
check_cleanup
# Quit only this product, allowing its assertion owner to clean up.
if pgrep -x Longhaul >/dev/null; then
  osascript -e 'tell application id "space.exlumina.longhaul" to quit'
  for _ in {1..20}; do if ! pgrep -x Longhaul >/dev/null; then break; fi; sleep 0.1; done
  if pgrep -x Longhaul >/dev/null; then echo "Longhaul did not finish cleanup; refusing another instance."; exit 1; fi
fi
check_cleanup
case "$MODE" in
  --preview) /usr/bin/open -n "$APP" --args --preview ;;
  --debug) lldb "$APP/Contents/MacOS/Longhaul" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP"; /usr/bin/log stream --level info --predicate 'subsystem == "space.exlumina.longhaul"' ;;
  run|--verify) /usr/bin/open -n "$APP"; if [ "$MODE" = "--verify" ]; then sleep 1; pgrep -x Longhaul; fi ;;
  *) echo 'Usage: build_and_run.sh [--build-only|--preview|--debug|--logs|--telemetry|--verify]'; exit 2 ;;
esac
