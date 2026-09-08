#!/bin/bash
# Build from reviewed committed source, then sign and notarize locally.
# Does not create or overwrite a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Name an existing notarytool Keychain profile}"
: "${LONGHAUL_STAGE_DIR:?Choose a fresh staging directory outside this repository}"
: "${LONGHAUL_RELEASE_DIR:?Choose a fresh final artifact directory outside this repository}"
SOURCE_COMMIT="$(git rev-parse --verify HEAD)"
if [ -n "$(git status --porcelain)" ]; then
  echo 'Release requires a clean, committed worktree.' >&2
  exit 1
fi
./script/test_all.sh
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
test -z "$(git status --porcelain)"
./script/package_local.sh
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
test -z "$(git status --porcelain)"
test "$(plutil -extract LonghaulSourceCommit raw "$LONGHAUL_STAGE_DIR/Longhaul.app/Contents/Info.plist")" = "$SOURCE_COMMIT"
./script/notarize.sh "$LONGHAUL_STAGE_DIR/Longhaul.app" "$LONGHAUL_RELEASE_DIR"
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
test -z "$(git status --porcelain)"
printf '%s\n' "$SOURCE_COMMIT" > "$LONGHAUL_RELEASE_DIR/SOURCE_COMMIT"
echo 'Validate extracted install and launch before publishing the immutable artifacts.'
