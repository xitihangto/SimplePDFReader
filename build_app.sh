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

# ---------- 前置环境检查 ----------
if ! xcode-select -p >/dev/null 2>&1; then
  cat >&2 <<'MSG'
错误：未检测到 Xcode 或 Command Line Tools。
请先在终端执行：
    xcode-select --install
MSG
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1 || ! xcrun --show-sdk-path >/dev/null 2>&1; then
  cat >&2 <<'MSG'
错误：Swift 工具链不可用，无法编译。

最常见的原因是「已安装 Xcode 但尚未同意其许可协议」。请执行：
    sudo xcodebuild -license accept

若尚未安装任何工具链，请执行：
    xcode-select --install
MSG
  exit 1
fi

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

echo "3. 正在清理扩展属性并做本地签名..."

# 重要：codesign 会拒绝签署带有 resource fork / Finder 信息的 bundle
# （报错 "resource fork, Finder information, or similar detritus not allowed"）。
# 必须先清除全部扩展属性，否则签名会静默失败，产物只带有链接器的临时签名、
# 且 Info.plist 不会被绑定，导致 codesign --verify 校验不通过。
xattr -cr "$APP_BUNDLE"

# 注意：这里不要再用 NSWorkspace.setIcon() 去写 Finder 自定义图标——
# 那一步会往 bundle 里塞入 Icon\r 文件与 ResourceFork/FinderInfo 属性，
# 正是导致上面签名失败的元凶。App 图标由 Info.plist 的 CFBundleIconFile
# 指向 Resources/AppIcon.icns，Finder 与 Dock 会正常显示，无需额外写入。
codesign --force --deep --sign - "$APP_BUNDLE"

# 校验签名，失败则明确报错（不要吞掉错误）
if ! codesign --verify --verbose=2 "$APP_BUNDLE"; then
  echo "错误：本地签名校验未通过。" >&2
  exit 1
fi

touch "$APP_BUNDLE"

echo "构建完成（已本地签名并通过校验）：$APP_BUNDLE"
