#!/usr/bin/env bash
# Build a runnable waik.app from the SwiftPM products.
#
# Usage:
#   Scripts/build.sh                  # debug build, ad-hoc signed
#   CONFIG=release Scripts/build.sh   # release build
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" Scripts/build.sh
#   WAIK_TEAM_ID=ABCDE12345 Scripts/build.sh
#
# Without SIGN_ID set, both binaries are ad-hoc signed (codesign -s -), which is
# enough to run locally but not enough for SMAppService to trust the daemon.
# For real use, supply a Developer ID Application certificate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-debug}"
SIGN_ID="${SIGN_ID:--}"
APP_NAME="waik"
APP_BUNDLE="build/${APP_NAME}.app"

echo "==> Generating app icon"
Scripts/generate-icon.swift "$ROOT"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product waik
swift build -c "$CONFIG" --product waik-helper

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/waik"        "$APP_BUNDLE/Contents/MacOS/waik"
cp "$BIN_DIR/waik-helper" "$APP_BUNDLE/Contents/MacOS/waik-helper"

cp Resources/Info.plist               "$APP_BUNDLE/Contents/Info.plist"
cp Resources/com.waik.helper.plist    "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.waik.helper.plist"
cp Resources/AppIcon.icns             "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Stamp the marketing version into the bundle plist. Sparkle's update check
# compares CFBundleVersion (numeric) of the running app against sparkle:version
# in the appcast — they must be the same encoding or every check returns
# "you are up to date" regardless of release order.
if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
        "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MARKETING_VERSION" \
        "$APP_BUNDLE/Contents/Info.plist"
fi

# Embed Sparkle.framework. SwiftPM builds the framework next to the
# executable; the .app expects it under Contents/Frameworks. ditto
# preserves symlinks (the framework heavily relies on Versions/Current).
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

    # SwiftPM-built executables don't get the standard .app rpath. Without
    # this, dyld looks for @rpath/Sparkle.framework only under
    # Contents/MacOS (via @loader_path) and fails to launch.
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$APP_BUNDLE/Contents/MacOS/waik" 2>/dev/null || true
fi

# PkgInfo (optional but harmless)
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Signing with: $SIGN_ID"

# Sign Sparkle.framework first — every embedded binary inside it must be
# signed with the same identity as the host app, otherwise Gatekeeper
# rejects the whole bundle. Sign inside-out: helper services, the main
# framework binary, then the framework itself.
SPARKLE_BUNDLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_BUNDLE_FRAMEWORK" ]; then
    find "$SPARKLE_BUNDLE_FRAMEWORK/Versions/Current/XPCServices" \
        -name '*.xpc' -maxdepth 1 -type d 2>/dev/null | while read -r xpc; do
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGN_ID" "$xpc"
    done
    if [ -d "$SPARKLE_BUNDLE_FRAMEWORK/Versions/Current/Updater.app" ]; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGN_ID" \
            "$SPARKLE_BUNDLE_FRAMEWORK/Versions/Current/Updater.app"
    fi
    if [ -x "$SPARKLE_BUNDLE_FRAMEWORK/Versions/Current/Autoupdate" ]; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGN_ID" \
            "$SPARKLE_BUNDLE_FRAMEWORK/Versions/Current/Autoupdate"
    fi
    codesign --force --options runtime --timestamp=none \
        --sign "$SIGN_ID" "$SPARKLE_BUNDLE_FRAMEWORK"
fi

codesign --force --options runtime --timestamp=none \
    --sign "$SIGN_ID" \
    --entitlements Resources/waik.helper.entitlements \
    "$APP_BUNDLE/Contents/MacOS/waik-helper"

codesign --force --options runtime --timestamp=none \
    --sign "$SIGN_ID" \
    --entitlements Resources/waik.entitlements \
    "$APP_BUNDLE/Contents/MacOS/waik"

codesign --force --options runtime --timestamp=none \
    --sign "$SIGN_ID" \
    --entitlements Resources/waik.entitlements \
    "$APP_BUNDLE"

echo "==> Verifying signatures"
codesign --verify --verbose "$APP_BUNDLE/Contents/MacOS/waik-helper"
codesign --verify --verbose "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
