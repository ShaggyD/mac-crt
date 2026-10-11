#!/bin/sh
# Assemble "Mac CRT.app" from the SwiftPM build product.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$ROOT/build/Mac CRT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MacCRT" "$APP/Contents/MacOS/MacCRT"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. Note this hashes the binary, so every rebuild is a new
# identity to TCC and macOS will ask for Screen Recording again. Sign with a
# stable certificate if you want the grant to survive rebuilds.
if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "codesign: ad-hoc signed"
else
    echo "codesign: skipped (not available or failed)"
fi

echo "Built $APP"
