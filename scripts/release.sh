#!/bin/bash
# Builds, checks and zips a release: build/DockPositioner-<version>.zip.
# With NOTARY_PROFILE set (a notarytool keychain profile) the zip is also notarised and stapled.
# Without it this is a dry run: the zip is signed but not notarised.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DockPositioner.app

scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="build/DockPositioner-$VERSION.zip"

INFO="$(codesign -dvv "$APP" 2>&1)"
if ! grep -q '^Authority=Developer ID Application' <<<"$INFO"; then
    echo "Release refused: $APP is not signed with a Developer ID Application identity (ad-hoc or other)." >&2
    exit 1
fi
if ! grep -q 'flags=0x10000(runtime)' <<<"$INFO"; then
    echo "Release refused: $APP does not have the hardened runtime flag (flags=0x10000(runtime))." >&2
    exit 1
fi

make_zip() {
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
}
make_zip

if [ -n "${NOTARY_PROFILE:-}" ]; then
    RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || {
        echo "$RESULT" >&2
        echo "Notarisation submit failed." >&2
        exit 1
    }
    echo "$RESULT"
    if ! grep -q 'status: Accepted' <<<"$RESULT"; then
        echo "Notarisation was not Accepted; see the output above (xcrun notarytool log <id> --keychain-profile \"$NOTARY_PROFILE\")." >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    make_zip
    spctl --assess --type execute -vv "$APP"
else
    echo "Dry run: $ZIP is signed but NOT notarised (NOTARY_PROFILE is not set)."
fi

echo "Zip: $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
