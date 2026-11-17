#!/bin/bash
# 构建 DSDPlayer.app
set -e
cd "$(dirname "$0")"

swift build -c release

APP=".build/DSDPlayer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DSDPlayer "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DSDPlayer</string>
    <key>CFBundleIdentifier</key><string>local.dsdplayer</string>
    <key>CFBundleName</key><string>DSDPlayer</string>
    <key>CFBundleDisplayName</key><string>DSD Player</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>DSD Audio</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array><string>public.data</string></array>
            <key>CFBundleTypeExtensions</key>
            <array><string>dsf</string><string>dff</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" 2>/dev/null || true
echo "构建完成: $APP"
