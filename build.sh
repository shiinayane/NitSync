#!/bin/bash
# Builds build/NitSync.app (ad-hoc signed). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=build/NitSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
python3 -I Localization/build-strings.py
cp Resources/Assets.car Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/NitSync"
codesign --force --sign - "$APP"
echo "Built $APP"
