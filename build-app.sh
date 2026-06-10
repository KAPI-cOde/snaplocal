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
swift build -c debug --product SnapLocal

echo "Creating .app bundle structure..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

echo "Copying binary..."
cp "$BUILD_DIR/SnapLocal" "$APP_PATH/Contents/MacOS/SnapLocal"
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

# A stable self-signed identity keeps the TCC screen-recording grant across rebuilds
# (its designated requirement doesn't change with the binary hash). Create it once with
# ./setup-signing.sh. Without it we fall back to ad-hoc, which forces a re-grant each build.
SIGN_IDENTITY="SnapLocal Dev Cert"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "Code signing with stable identity ($SIGN_IDENTITY)..."
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements "$BUILD_DIR/entitlements.plist" \
        "$APP_PATH"
    echo "Stable identity used → screen-recording permission persists (no TCC reset)."
else
    echo "Code signing ad-hoc (no stable identity; run ./setup-signing.sh to stop the per-build re-grant)..."
    codesign --force --deep --sign - \
        --entitlements "$BUILD_DIR/entitlements.plist" \
        "$APP_PATH"
    # Ad-hoc signing changes the binary hash each build, so macOS TCC revokes screen recording
    # permission silently (System Settings still shows the checkmark but it's stale).
    # Resetting the entry here forces a clean permission prompt on next launch.
    tccutil reset ScreenCapture com.snaplocal.app 2>/dev/null || true
fi

echo "Build complete: $APP_PATH"
echo ""
echo "To run the app:"
echo "  open $APP_PATH"
echo ""
echo "Or:"
echo "  $APP_PATH/Contents/MacOS/SnapLocal"
