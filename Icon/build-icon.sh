#!/bin/bash
# Compiles Icon/AppIcon.icon (an Icon Composer document) into the files the app ships with,
# and exports light and dark previews. Needs Xcode 26 or later; ./build.sh does not, because
# the outputs are committed.
#
#   Resources/Assets.car    Liquid Glass icon: light, dark, tinted and clear appearances
#   Resources/AppIcon.icns  fallback for macOS before 26
#   Icon/AppIcon-light.png, Icon/AppIcon-dark.png   previews (README)
#
# Usage: Icon/build-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

xcrun actool Icon/AppIcon.icon --compile "$OUT" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$OUT/partial.plist" >/dev/null
mkdir -p Resources
cp "$OUT/Assets.car" "$OUT/AppIcon.icns" Resources/

for rendition in Default Dark; do
    name=$([ "$rendition" = Default ] && echo light || echo dark)
    "$ICTOOL" Icon/AppIcon.icon --export-image --output-file "Icon/AppIcon-$name.png" \
        --platform macOS --rendition "$rendition" --width 256 --height 256 --scale 2 >/dev/null
done

echo "Wrote Resources/Assets.car, Resources/AppIcon.icns, Icon/AppIcon-light.png, Icon/AppIcon-dark.png"
