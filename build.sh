#!/bin/bash
# Builds build/NitSync.app (ad-hoc signed). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=build/NitSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/NitSync"
codesign --force --sign - "$APP"
echo "Built $APP"
