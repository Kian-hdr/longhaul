#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to an installed Developer ID Application identity}"
LONGHAUL_CONFIGURATION=Release ./script/build_and_run.sh --build-only
BUILD_DIR="${LONGHAUL_BUILD_DIR:-$HOME/Library/Caches/Longhaul/Build}"
SOURCE_APP="$BUILD_DIR/Build/Products/Release/Longhaul.app"
STAGE="${LONGHAUL_STAGE_DIR:-$HOME/Library/Caches/Longhaul/Stage}"
mkdir -p "$STAGE"
if [ -e "$STAGE/Longhaul.app" ]; then
  echo "Stage already contains Longhaul.app. Choose a fresh LONGHAUL_STAGE_DIR." >&2
  exit 1
fi
ditto --norsrc "$SOURCE_APP" "$STAGE/Longhaul.app"
APP="$STAGE/Longhaul.app"
codesign --force --options runtime --timestamp --identifier space.exlumina.longhaul.companion --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/LonghaulCompanion"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/bin/longhaul"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed local candidate: $APP"
echo 'This candidate has not been notarized or published.'
