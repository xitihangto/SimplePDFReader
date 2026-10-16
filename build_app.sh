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

if ! command -v swift >/dev/null 2>&1 \
   || ! command -v swiftc >/dev/null 2>&1 \
   || ! xcrun --show-sdk-path >/dev/null 2>&1; then
  cat >&2 <<'MSG'
错误：Swift 工具链不可用，无法编译。

最常见的原因是「已安装 Xcode 但尚未同意其许可协议」。请执行：
    sudo xcodebuild -license accept

若尚未安装任何工具链，请执行：
    xcode-select --install
MSG
  exit 1
fi

# ---------- 版本号解析 ----------
# 优先级：APP_VERSION 环境变量 > 仓库最近的 git tag > 回退 1.0.0
# CI 发版时通过 APP_VERSION 传入 tag（如 v1.0.1）；本机构建则自动读取最近的 tag。
# 可用 APP_VERSION=1.2.3 ./build_app.sh 手动指定。
VERSION_RAW="${APP_VERSION:-}"
if [ -z "$VERSION_RAW" ]; then
  VERSION_RAW="$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
fi
[ -n "$VERSION_RAW" ] || VERSION_RAW="1.0.0"

# 去掉前缀 v，得到形如 1.0.1 的版本号
VERSION="${VERSION_RAW#v}"
[ -n "$VERSION" ] || VERSION="1.0.0"

# CFBundleVersion 只允许数字与点号，这里做一次净化（如 1.0.1-beta -> 1.0.1）
BUILD="$(printf '%s' "$VERSION" | sed 's/[^0-9.].*$//')"
[ -n "$BUILD" ] || BUILD="1"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "0. 构建版本：$VERSION (CFBundleVersion=$BUILD)"
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
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__APP_BUILD__</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 xitihangto · github.com/xitihangto/SimplePDFReader</string>
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

# 用占位符 + 替换的方式注入版本号：上面的 heredoc 用引号包裹（<<'EOF'），
# 不会展开变量，因此可以安全地先把 plist 原样写出，再定点替换版本字段。
# 注意：这里刻意不用 `sed -i`——BSD sed 与 GNU sed 对 -i 的参数处理不同
# （BSD 要求 `-i ''`，GNU 要求 `-i`），改用「重定向到临时文件再覆盖」的写法，
# 两种实现下行为一致。
PLIST_TMP="$(mktemp)"
sed "s/__APP_VERSION__/${VERSION}/g; s/__APP_BUILD__/${BUILD}/g" \
    "$CONTENTS_DIR/Info.plist" > "$PLIST_TMP"
mv "$PLIST_TMP" "$CONTENTS_DIR/Info.plist"

if grep -q '__APP_VERSION__\|__APP_BUILD__' "$CONTENTS_DIR/Info.plist"; then
  echo "错误：Info.plist 中的版本号占位符未被替换。" >&2
  exit 1
fi

echo "2. 正在编译 SimplePDFReader..."
swiftc -O -parse-as-library \
    -target arm64-apple-macosx13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    "$SCRIPT_DIR/Sources/SimplePDFReader/ModelsAndViewModel.swift" \
    "$SCRIPT_DIR/Sources/SimplePDFReader/WindowSupport.swift" \
    "$SCRIPT_DIR/Sources/SimplePDFReader/AppAndViews.swift" \
    -framework SwiftUI -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers \
    -o "$MACOS_DIR/SimplePDFReader"

echo "3. 正在清理扩展属性并做本地签名..."

# 重要：codesign 会拒绝签署带有 resource fork / Finder 信息的 bundle
# （报错 "resource fork, Finder information, or similar detritus not allowed"）。
# 必须先清除全部扩展属性，否则签名会静默失败，产物只带有链接器的临时签名、
# 且 Info.plist 不会被绑定，导致 codesign --verify 校验不通过。
xattr -cr "$APP_BUNDLE" || true

# 顶层 bundle 目录还可能被盖上 com.apple.FinderInfo / com.apple.fileprovider.fpfs#P
# （沙箱内新建文件、或 Finder 触碰过都会留下）—— codesign 同样视为 detritus 拒绝，
# 报同样的 "resource fork, Finder information, or similar detritus not allowed"。
# com.apple.provenance 是 macOS 26 的内核属性、用户态删不掉，但实测不影响签名
# 有效性（codesign --verify 照常通过），留着即可，无需处理。
for attr in com.apple.FinderInfo com.apple.fileprovider.fpfs#P; do
  xattr -d "$attr" "$APP_BUNDLE" 2>/dev/null || true
done

# 清理与签名之间存在异步竞争：系统守护进程可能在清理后、签名前的毫秒级窗口里
# 又把 FinderInfo 盖回来（本沙箱内实测复现过）。因此签名带重试：每次重新清理
# 后立即签，最多 3 次；仍失败才报错退出。
sign_ok=0
for attempt in 1 2 3; do
  if codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null; then
    sign_ok=1
    break
  fi
  echo "签名失败（第 ${attempt} 次，疑似扩展属性被重新盖上），重新清理后重试..." >&2
  xattr -cr "$APP_BUNDLE" || true
  for attr in com.apple.FinderInfo com.apple.fileprovider.fpfs#P; do
    xattr -d "$attr" "$APP_BUNDLE" 2>/dev/null || true
  done
done
if [ "$sign_ok" != 1 ]; then
  echo "错误：本地签名失败（多次重试后仍有扩展属性干扰）。" >&2
  exit 1
fi

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

echo "构建完成（版本 $VERSION，已本地签名并通过校验）：$APP_BUNDLE"
