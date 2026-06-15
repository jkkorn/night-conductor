#!/usr/bin/env bash
# Build → Developer-ID sign → notarize → staple → zip a distributable release.
# One-time setup (see packaging/README.md): a "Developer ID Application" cert,
# and a stored notarytool credential profile (default name: night-conductor).
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-night-conductor}"
APP="dist/Night Conductor.app"

# 1. Build + sign with Developer ID + hardened runtime.
./build-app.sh

# 2. Refuse to ship an ad-hoc-signed app (notarization would reject it anyway).
if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "ERROR: '$APP' is not Developer ID signed." >&2
    echo "Create the cert (packaging/README.md) — 'security find-identity -v -p codesigning'" >&2
    echo "must list a 'Developer ID Application' identity." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/Night-Conductor-$VERSION.zip"

echo "▸ Zipping for notarization…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to Apple notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "▸ Stapling the ticket…"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP" # re-zip the stapled app for distribution

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo ""
echo "✓ Notarized release: $PWD/$ZIP"
echo "  version: $VERSION"
echo "  sha256:  $SHA"
echo ""
echo "Next:"
echo "  1. gh release create v$VERSION \"$ZIP\" --title \"v$VERSION\" --generate-notes"
echo "  2. In packaging/night-conductor.rb set: version \"$VERSION\"  and  sha256 \"$SHA\""
