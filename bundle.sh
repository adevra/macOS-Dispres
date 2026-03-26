#!/bin/bash
set -e

APP_NAME="Dispres"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building release..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/$APP_NAME" "$MACOS/$APP_NAME"
cp "Sources/Dispres/Resources/Info.plist" "$CONTENTS/Info.plist"

if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Ad-hoc sign
codesign --force --sign - "$BUNDLE_DIR"

echo ""
echo "Done! Created $BUNDLE_DIR"
echo "  Install:  cp -r $BUNDLE_DIR /Applications/"
echo "  Run:      open $BUNDLE_DIR"
