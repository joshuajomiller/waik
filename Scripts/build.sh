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

# PkgInfo (optional but harmless)
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Signing with: $SIGN_ID"
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
