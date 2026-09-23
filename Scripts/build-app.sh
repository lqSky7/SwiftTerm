#!/bin/bash
# Build the executable, assemble it into a real .app bundle, advance the build number, and install
# it. SwiftPM cannot produce a bundle, so this writes the Info.plist and lays out Contents/.
#
#   ./Scripts/build-app.sh [debug|release]     build and install
#   ./Scripts/build-app.sh release --no-install  build only, leave it in dist/
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

CONFIG="${1:-release}"
INSTALL="${2:-}"
APP_NAME="swiftTerm"
EXECUTABLE="SwiftTerm"
INSTALL_DIR="${SWIFTTERM_INSTALL_DIR:-/Applications}"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

# The build number lives in the source plist and advances on every build, so an installed copy can
# always be told apart from the one before it without opening anything.
PLIST_BUDDY=/usr/libexec/PlistBuddy
BUILD_NUMBER=$(( $("$PLIST_BUDDY" -c "Print :CFBundleVersion" app/Info.plist) + 1 ))
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" app/Info.plist
MARKETING_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" app/Info.plist)"

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp app/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for macOS to launch it locally and for the identity to stay stable across
# rebuilds, without needing a Developer ID.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ built $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER) → $APP"

[ "$INSTALL" = "--no-install" ] && exit 0

# Replacing a running bundle leaves the old process alive on the deleted inode, which shows up as a
# stale window that will not respond. The old copy is stopped first.
pkill -x "$EXECUTABLE" >/dev/null 2>&1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"
echo "✓ installed → $INSTALL_DIR/$APP_NAME.app"
