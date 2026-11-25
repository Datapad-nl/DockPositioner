#!/bin/bash
# Builds a release binary and assembles build/DockPositioner.app.
# Signing identity: CODESIGN_IDENTITY if set ("-" signs ad-hoc); otherwise the Datapad Developer ID
# if it is in the keychain; otherwise ad-hoc. A stable signature keeps the Accessibility
# permission across builds; an ad-hoc signature changes on every build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DockPositioner"

APP=build/DockPositioner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DockPositioner"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>nl.datapad.DockPositioner</string>
    <key>CFBundleName</key>
    <string>DockPositioner</string>
    <key>CFBundleExecutable</key>
    <string>DockPositioner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>DockPositioner asks Finder to empty the Trash when you choose Empty Trash in its Dock. It sends Finder nothing else.</string>
</dict>
</plist>
PLIST

DEFAULT_IDENTITY="Developer ID Application: Datapad B.V. (3FZVG3KWR3)"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -qF "$DEFAULT_IDENTITY"; then
    IDENTITY="$DEFAULT_IDENTITY"
else
    IDENTITY="-"
    echo "No CODESIGN_IDENTITY set and no Datapad Developer ID in the keychain: signing ad-hoc."
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
