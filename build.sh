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
# -swift-version 5: explicit MVP choice. Swift 6 strict-concurrency mode fails
# on `nonisolated init` assigning `let` stored properties of an @MainActor class
# (a known Swift 6 nuance). The concurrency annotations (@MainActor, actor) are
# correct at runtime; this is a language-mode limitation, not a logic bug.
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
