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
# The icon package's name, which is also the name actool compiles it under and the name the bundle's
# `CFBundleIconName` has to say. One name in three places, so it lives here once — see the icon block
# below for what happens when they disagree.
ICON="swiftTerm"
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

# The app icon, which on macOS 26 is an Icon Composer package rather than a picture.
#
# `actool` compiles it into `Assets.car` — the Liquid Glass layers, with the light and dark and tinted
# appearances — and alongside that emits the flat `.icns` the bundle still has to carry.
#
# **`--app-icon` has to name the package.** Give it a name that matches no package and actool does not
# fail: it compiles the layers into the catalog under a name nothing looks up, writes an empty
# partial.plist, emits no `.icns`, and exits zero. macOS then finds no icon under `CFBundleIconName` and
# falls back to whatever `.icns` is lying in Resources, which on macOS 26 it draws with its own
# legacy-icon treatment — a hard glass rim around art that was never drawn for one. That silent fallback
# is what this script used to ship: `--app-icon AppIcon` against a package called `swiftTerm.icon`.
xcrun actool "app/assets/$ICON.icon" \
    --compile "$APP/Contents/Resources" \
    --output-format human-readable-text \
    --output-partial-info-plist "$APP/Contents/Resources/partial.plist" \
    --app-icon "$ICON" \
    --include-all-app-icons \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx

if [ ! -f "$APP/Contents/Resources/$ICON.icns" ]; then
    echo "✗ actool produced no $ICON.icns — --app-icon must match the .icon package's name" >&2
    exit 1
fi
rm -f "$APP/Contents/Resources/partial.plist"

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
