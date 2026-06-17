#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Gheen.app"
CONTENTS="$APP/Contents"
BIN_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
BIN="$BIN_DIR/Gheen"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

echo "==> Compiling (Apple Silicon, target macOS 13)"
# -swift-version 5: pragmatic language mode for the MVP (keeps @MainActor /
# actor annotations valid without strict-concurrency build failures).
swiftc \
    -swift-version 5 \
    -target arm64-apple-macosx13.0 \
    -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework UserNotifications \
    -o "$BIN" \
    Sources/Gheen/*.swift

echo "==> Bundling Info.plist"
cp Resources/Info.plist "$CONTENTS/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Built $APP"
echo "==> Launching"
open "$APP"
