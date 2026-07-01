#!/usr/bin/env bash
# Builds dist/Night Conductor.app from source. Requires Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Building release binary…"
swift build -c release

APP_DIR="dist/Night Conductor.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/NightConductor "$APP_DIR/Contents/MacOS/NightConductor"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NightConductor</string>
    <key>CFBundleIdentifier</key><string>app.night-conductor</string>
    <key>CFBundleName</key><string>Night Conductor</string>
    <key>CFBundleDisplayName</key><string>Night Conductor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.7</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "▸ Generating icon…"
ICON_PNG="$(mktemp -d)/icon.png"
swift scripts/make-icon.swift "$ICON_PNG"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP_DIR/Contents/Resources/AppIcon.icns" "$ICONSET"

# Sign with Developer ID + hardened runtime when a cert is available (so
# release builds notarize); otherwise ad-hoc, so anyone can still build.
# Override the identity with SIGN_IDENTITY=...; set SIGN_IDENTITY=- to force ad-hoc.
# NB: `|| true` is load-bearing — under `set -euo pipefail`, a no-match grep
# (no Developer ID cert, e.g. on CI) would otherwise abort the script before
# the ad-hoc fallback below ever runs.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "▸ Signing (Developer ID: $IDENTITY, hardened runtime)…"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_DIR"
else
    echo "▸ Signing (ad-hoc — no Developer ID cert found)…"
    codesign --force -s - "$APP_DIR"
fi

echo ""
echo "✓ Built: $PWD/$APP_DIR"
echo "  Drag it into /Applications and double-click. Look for the moon 🌙 in your menu bar."
