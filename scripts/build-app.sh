#!/bin/sh
# Assemble CRTOverlay.app from the SwiftPM build product.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$ROOT/build/CRTOverlay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/CRTOverlay" "$APP/Contents/MacOS/CRTOverlay"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature: gives the app a stable-enough identity for TCC to attribute
# a Screen Recording grant to. Rebuilds change the cdhash, so macOS may re-ask.
if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "codesign: ad-hoc signed"
else
    echo "codesign: skipped (not available or failed)"
fi

echo "Built $APP"
