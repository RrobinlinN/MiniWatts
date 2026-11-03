#!/bin/bash
# Builds the iOS 16 sensor probe without an Xcode project, for TrollStore.
#
# Two .tipa files from one binary, differing only in entitlements:
#   sandboxed    — what a normally sideloaded MiniWatts would see
#   unsandboxed  — platform-application + no-sandbox, which only TrollStore can grant
# Different bundle ids, so both can be installed side by side.
#
# Needs Xcode and ldid (`brew install ldid`). Output in build/probe16/.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/probe16
rm -rf "$out"
mkdir -p "$out"

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios16.0 \
    -sdk "$sdk" \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -file-prefix-map "$PWD=/Probe16" \
    Probe16/Probe.swift Probe16/ProbeApp.swift \
    -o "$out/MiniWattsProbe"

for variant in sandboxed unsandboxed; do
    app="$out/$variant/Payload/MiniWattsProbe.app"
    mkdir -p "$app"
    cp "$out/MiniWattsProbe" "$app/MiniWattsProbe"
    cp Probe16/Info.plist "$app/Info.plist"
    case $variant in
        sandboxed)   display="Probe SB" ;;
        unsandboxed) display="Probe NoSB" ;;
    esac
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier org.zhaohe.MiniWattsProbe16.$variant" "$app/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $display" "$app/Info.plist"
    plutil -convert binary1 "$app/Info.plist"
    ldid -S"Probe16/$variant.entitlements" "$app/MiniWattsProbe"
    ldid -e "$app/MiniWattsProbe"
    (cd "$out/$variant" && zip -qry "../MiniWattsProbe16-$variant.tipa" Payload)
done

ls -l "$out"/*.tipa
