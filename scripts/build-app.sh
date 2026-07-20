#!/bin/bash
# Build a runnable Peachy Code.app bundle from the SwiftPM release build.
# Usage: scripts/build-app.sh [output-dir]
#   output-dir defaults to ./dist
#
# SwiftPM only produces a bare executable; this script assembles the full
# .app bundle (Info.plist, resources, SPM resource bundle, Sparkle framework,
# icon) so it can be double-clicked and later packaged into a DMG.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO/dist}"
APP_NAME="Peachy Code"
EXEC_NAME="peachy-code"
APP="$OUT_DIR/$APP_NAME.app"

echo "── Release build ──────────────────────────────"
swift build -c release --package-path "$REPO"
BIN="$(swift build -c release --package-path "$REPO" --show-bin-path)"
echo "bin: $BIN"

echo "── Assemble bundle ────────────────────────────"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

# Executable
cp "$BIN/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"

# Info.plist (CFBundleExecutable must match EXEC_NAME)
cp "$REPO/Info.plist" "$APP/Contents/Info.plist"

# Resources: icon + copied resource dirs + SPM-generated resource bundle
cp "$REPO/Sources/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for dir in Defaults Fonts Images Extensions; do
  [ -d "$REPO/Sources/Resources/$dir" ] && cp -R "$REPO/Sources/Resources/$dir" "$APP/Contents/Resources/$dir"
done
# SPM resource bundle (peachy-code_peachy-code.bundle)
if [ -d "$BIN/${EXEC_NAME}_${EXEC_NAME}.bundle" ]; then
  cp -R "$BIN/${EXEC_NAME}_${EXEC_NAME}.bundle" "$APP/Contents/Resources/"
fi

# Sparkle framework — the release executable links @rpath/Sparkle.framework
# with rpath @loader_path (the MacOS dir), so place it beside the executable.
cp -R "$BIN/Sparkle.framework" "$APP/Contents/MacOS/Sparkle.framework"
# Also add an explicit rpath to Frameworks for robustness and copy there too.
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true

echo "── Ad-hoc codesign (local run) ────────────────"
# Ad-hoc sign so macOS Gatekeeper allows local launch. For distribution,
# replace with a Developer ID identity and notarization.
codesign --force --deep --sign - "$APP" 2>&1 | tail -2 || true

echo "── Done ───────────────────────────────────────"
echo "App: $APP"
echo "Executable arch: $(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo unknown)"
