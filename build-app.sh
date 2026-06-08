#!/bin/bash
# build-app.sh - Build SnapLocal as a proper macOS .app bundle

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_NAME="SnapLocal"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
APP_NAME="SnapLocal.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
BINARY_PATH="$BUILD_DIR/SnapLocal"
RESOURCES_DIR="$SCRIPT_DIR/Sources/SnapLocalApp/Resources"
INFO_PLIST="$SCRIPT_DIR/Sources/SnapLocalApp/Info.plist"

echo "Building Swift package..."
swift build -c debug

echo "Creating .app bundle structure..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

echo "Copying binary..."
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/SnapLocal"
chmod +x "$APP_PATH/Contents/MacOS/SnapLocal"

echo "Copying Info.plist..."
cp "$INFO_PLIST" "$APP_PATH/Contents/Info.plist"

echo "Copying resources..."
if [ -d "$RESOURCES_DIR" ]; then
    cp -r "$RESOURCES_DIR"/* "$APP_PATH/Contents/Resources/" 2>/dev/null || true
fi

# Create entitlements for ScreenCapture
cat > "$BUILD_DIR/entitlements.plist" << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
ENTEOF

echo "Code signing with entitlements..."
codesign --force --deep --sign - --entitlements "$BUILD_DIR/entitlements.plist" --options runtime "$APP_PATH" 2>/dev/null || codesign --force --deep --sign - --entitlements "$BUILD_DIR/entitlements.plist" "$APP_PATH"

echo "Build complete: $APP_PATH"
echo ""
echo "To run the app:"
echo "  open $APP_PATH"
echo ""
echo "Or:"
echo "  $APP_PATH/Contents/MacOS/SnapLocal"
