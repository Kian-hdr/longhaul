#!/bin/bash
# Finalize an already signed app. Credentials stay in an existing Keychain profile.
set -euo pipefail
APP="${1:?Usage: NOTARY_PROFILE=name script/notarize.sh /path/Longhaul.app /path/output}"
OUTPUT="${2:?Provide a new output directory}"
: "${NOTARY_PROFILE:?Name an existing notarytool Keychain profile}"
test -d "$APP"
test ! -e "$OUTPUT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
test "$VERSION" = 1.0.0
codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT"
ARCHIVE="$OUTPUT/Longhaul-$VERSION-arm64.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUTPUT/notary-result.json"
test "$(plutil -extract status raw "$OUTPUT/notary-result.json")" = Accepted
xcrun notarytool log "$(plutil -extract id raw "$OUTPUT/notary-result.json")" --keychain-profile "$NOTARY_PROFILE" "$OUTPUT/notary-log.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=4 "$APP"
# ZIP cannot itself carry a ticket; archive the now-stapled app.
ditto -c -k --keepParent "$APP" "$ARCHIVE"
(cd "$OUTPUT" && shasum -a 256 "Longhaul-$VERSION-arm64.zip" > SHA256SUMS)
EXTRACTED="$OUTPUT/verification"
mkdir "$EXTRACTED"
ditto -x -k "$ARCHIVE" "$EXTRACTED"
codesign --verify --deep --strict "$EXTRACTED/Longhaul.app"
xcrun stapler validate "$EXTRACTED/Longhaul.app"
spctl --assess --type execute --verbose=4 "$EXTRACTED/Longhaul.app"
test "$(plutil -extract LonghaulSourceCommit raw "$EXTRACTED/Longhaul.app/Contents/Info.plist")" = "$(plutil -extract LonghaulSourceCommit raw "$APP/Contents/Info.plist")"
echo "Notarized archive and SHA256SUMS: $OUTPUT"
