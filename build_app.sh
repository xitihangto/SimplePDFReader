#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="${OUTPUT_APP_PATH:-$PARENT_DIR/SimplePDFReader.app}"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_PNG="$SCRIPT_DIR/AppIcon.png"
ICON_ICNS="$SCRIPT_DIR/AppIcon.icns"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "1. 正在生成红色系高清应用图标 (1024x1024)..."
swift "$SCRIPT_DIR/generate_icon.swift" "$ICON_PNG" "$ICON_ICNS"
cp "$ICON_ICNS" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>SimplePDFReader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.spark.SimplePDFReader</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SimplePDFReader</string>
    <key>CFBundleDisplayName</key>
    <string>SimplePDFReader</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>pdf</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "2. 正在编译 SimplePDFReader..."
swiftc -O -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$SCRIPT_DIR/Sources/SimplePDFReader/ModelsAndViewModel.swift" \
    "$SCRIPT_DIR/Sources/SimplePDFReader/AppAndViews.swift" \
    -framework SwiftUI -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers \
    -o "$MACOS_DIR/SimplePDFReader"

# 同步刷新 Finder 自定义图标缓存，确保 Finder 立即显示新图标
swift -e '
import Cocoa
if let img = NSImage(contentsOfFile: "'"$ICON_PNG"'") {
    NSWorkspace.shared.setIcon(img, forFile: "'"$APP_BUNDLE"'", options: [])
}
' 2>/dev/null || true

codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
touch "$APP_BUNDLE"

echo "编译与图标绑定完成：$APP_BUNDLE"
