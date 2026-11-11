#!/bin/bash
set -e

# Ensure execution from repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Script to build standalone Graviton.app for macOS

APP_NAME="Graviton"
APP_VERSION="${APP_VERSION:-1.1.0}"
BUNDLE_ID="com.smnk.graviton"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

if [ -z "$DEVELOPER_DIR" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "🔨 Building release binary with Swift PM..."
TMPDIR=/tmp swift build -c release --disable-sandbox
BIN_DIR=$(TMPDIR=/tmp swift build -c release --disable-sandbox --show-bin-path 2>/dev/null || echo "")

echo "📦 Creating macOS App Bundle at ${BUNDLE_DIR} (v${APP_VERSION})..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy binary
if [ -n "${BIN_DIR}" ] && [ -f "${BIN_DIR}/${APP_NAME}" ]; then
    cp "${BIN_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
elif [ -f ".build/out/Products/Release/${APP_NAME}" ]; then
    cp ".build/out/Products/Release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
elif [ -f ".build/release/${APP_NAME}" ]; then
    cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
else
    echo "❌ Error: Release binary '${APP_NAME}' not found in .build!"
    exit 1
fi

chmod +x "${MACOS_DIR}/${APP_NAME}"

# Copy app resources directly into Contents/Resources
if [ -d "Sources/Graviton/Resources" ]; then
    cp -R "Sources/Graviton/Resources/"* "${RESOURCES_DIR}/"
fi

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Clear any extended attributes before signing
xattr -cr "${BUNDLE_DIR}" 2>/dev/null || true

if [ -n "$CODE_SIGN_IDENTITY" ]; then
    echo "🔏 Signing app bundle with identity: ${CODE_SIGN_IDENTITY}..."
    codesign --force --options runtime --timestamp \
        --entitlements "scripts/entitlements.plist" \
        --sign "${CODE_SIGN_IDENTITY}" "${BUNDLE_DIR}"
else
    echo "🔏 Signing app bundle with ad-hoc signature..."
    codesign --force --deep --sign - "${BUNDLE_DIR}"
fi

echo "🔍 Verifying app bundle signature..."
codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"
echo "✅ App bundle created and verified at ${BUNDLE_DIR}!"

echo "📀 Creating DMG installer at build/${APP_NAME}.dmg..."
DMG_TEMP_DIR="build/dmg_temp"
rm -rf "${DMG_TEMP_DIR}" "build/${APP_NAME}.dmg"
mkdir -p "${DMG_TEMP_DIR}"
cp -R "${BUNDLE_DIR}" "${DMG_TEMP_DIR}/"
ln -s /Applications "${DMG_TEMP_DIR}/Applications"

DMG_CREATED=0
for attempt in 1 2 3; do
    if hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TEMP_DIR}" -ov -format UDZO "build/${APP_NAME}.dmg"; then
        DMG_CREATED=1
        break
    fi
    echo "⚠️ hdiutil create attempt ${attempt} failed, retrying in 2s..."
    sleep 2
done
rm -rf "${DMG_TEMP_DIR}"

if [ "$DMG_CREATED" -ne 1 ]; then
    echo "❌ Error: Failed to create DMG after 3 attempts."
    exit 1
fi

if [ -n "$CODE_SIGN_IDENTITY" ]; then
    echo "🔏 Signing DMG with identity: ${CODE_SIGN_IDENTITY}..."
    codesign --force --sign "${CODE_SIGN_IDENTITY}" --timestamp "build/${APP_NAME}.dmg"
    codesign --verify --verbose=2 "build/${APP_NAME}.dmg"
fi

echo "🗜️ Creating ZIP archives with ditto..."
rm -f "build/${APP_NAME}.zip" "build/${APP_NAME}-v${APP_VERSION}.zip" "build/${APP_NAME}.app.zip"
ditto -c -k --keepParent "${BUNDLE_DIR}" "build/${APP_NAME}.zip"
cp "build/${APP_NAME}.zip" "build/${APP_NAME}-v${APP_VERSION}.zip"
cp "build/${APP_NAME}.zip" "build/${APP_NAME}.app.zip"

echo "🎉 All release artifacts created in build/:"
ls -lh build/*.dmg build/*.zip

if [ "$1" = "--install" ] || [ "$2" = "--install" ]; then
    echo "🚀 Installing ${APP_NAME}.app into /Applications..."
    killall "${APP_NAME}" 2>/dev/null || true
    killall "AGYTokenTracker" 2>/dev/null || true
    sleep 1
    killall -9 "${APP_NAME}" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    rm -rf "/Applications/AGYTokenTracker.app"
    cp -R "${BUNDLE_DIR}" /Applications/
    echo "✅ Successfully installed! Launching /Applications/${APP_NAME}.app..."
    open "/Applications/${APP_NAME}.app"
else
    echo "👉 You can run it now with: open ${BUNDLE_DIR}"
    echo "👉 Or install to Applications: ./scripts/build_app.sh --install"
    echo "👉 Or manually: cp -r ${BUNDLE_DIR} /Applications/"
fi
