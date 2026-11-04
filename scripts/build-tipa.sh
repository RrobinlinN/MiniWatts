#!/bin/bash
# Builds MiniWatts as a TrollStore .tipa for iOS 16.
#
#   ./scripts/build-tipa.sh
#
# Builds the unsigned ipa with build-ipa.sh, then fake-signs it with ldid so it
# carries entitlements, which is all TrollStore needs:
#   - the app gets scripts/trollstore.entitlements: its App Group, plus
#     platform-application and no-sandbox. Outside the sandbox IOPMPowerSource
#     answers in full — InstantAmperage, Voltage, Temperature, CycleCount — which
#     is the only cell-side current an iPhone 12 has: it exposes no IQ0B.
#   - the widget keeps Widget/Widget.entitlements and stays sandboxed.
# Only TrollStore can install entitlements like these. Never publish this build as
# MiniWatts' release: it is a private build for one's own TrollStore device.
#
# Needs Xcode and ldid (`brew install ldid`). Output: build/export/MiniWatts-trollstore.tipa
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build-ipa.sh unsigned

BUILD_DIR="build"
WORK="$BUILD_DIR/tipa"
rm -rf "$WORK"
mkdir -p "$WORK"
unzip -q "$BUILD_DIR/export/MiniWatts-unsigned.ipa" -d "$WORK"
APP="$WORK/Payload/MiniWatts.app"

echo "==> Signing for TrollStore"
while IFS= read -r -d '' appex; do
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  ldid -SWidget/Widget.entitlements "$appex/$executable"
done < <(find "$APP" -name '*.appex' -type d -print0)
ldid -Sscripts/trollstore.entitlements "$APP/MiniWatts"
ldid -e "$APP/MiniWatts"

rm -f "$BUILD_DIR/export/MiniWatts-trollstore.tipa"
(cd "$WORK" && zip -qry "../export/MiniWatts-trollstore.tipa" Payload)
rm -rf "$WORK"

echo
echo "Done:"
ls -lh "$BUILD_DIR/export/MiniWatts-trollstore.tipa"
