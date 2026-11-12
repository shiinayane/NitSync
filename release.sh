#!/bin/bash
# Builds NitSync for distribution: Developer ID signature with the hardened runtime,
# notarized by Apple, ticket stapled, zipped into dist/.
#
#   ./release.sh            build, sign, notarize, staple, zip
#   ./release.sh --install  the same, then install to /Applications and start it from there
#
# Needs a "Developer ID Application" certificate in the keychain and notarytool credentials
# saved once under a keychain profile (default name NitSync, override with NOTARY_PROFILE):
#   xcrun notarytool store-credentials NitSync --apple-id <Apple ID> --team-id <Team ID>
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-NitSync}"
APP=build/NitSync.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="dist/NitSync-$VERSION.zip"

# The first Developer ID Application identity, unless SIGN_IDENTITY names one.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

./build.sh
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# The upload goes in a temporary file: if notarization or stapling fails, nothing in dist/
# looks like a finished release.
mkdir -p dist
rm -f "$ZIP"
UPLOAD="$(mktemp -d)/NitSync-$VERSION.zip"
trap 'rm -rf "$(dirname "$UPLOAD")"' EXIT
ditto -c -k --keepParent "$APP" "$UPLOAD"
echo "Submitting for notarization (profile $PROFILE)…"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$(dirname "$UPLOAD")/notary.log"
# notarytool can exit 0 with an Invalid status; require Accepted.
grep -q "status: Accepted" "$(dirname "$UPLOAD")/notary.log" || { echo "Notarization was not accepted." >&2; exit 1; }

# Staple the ticket to the app so it opens offline too, then zip the stapled app.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv -t exec "$APP"
echo "Built $ZIP"

if [ "${1:-}" = "--install" ]; then
    pkill -x NitSync || true
    sleep 0.5
    rm -rf /Applications/NitSync.app
    ditto "$APP" /Applications/NitSync.app
    open /Applications/NitSync.app
    echo "Installed /Applications/NitSync.app"
fi
