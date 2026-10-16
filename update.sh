#!/bin/bash
# 把 /Applications 里的 SimplePDFReader 更新到最新的 GitHub Release 产物。
#
# 为什么用 CI 产物而不是本地 build_app.sh 的产物：
#   Release 产物只允许由 GitHub Actions（macos-15/arm64）从仓库源码构建，
#   任何下载到的 .app 都能溯源到具体提交；本地产物仅供开发调试。
#
# 用法：
#   ./update.sh            # 更新到最新 Release
#   ./update.sh v1.5.0     # 更新到指定版本（tag 必须以 v 开头）
#
# 发版约定：每次改代码发版后都应执行本脚本，让本机安装版与线上 Release 保持一致。
#
# 注意：所有变量展开一律用 ${VAR} 花括号形式 —— macOS 自带 bash 3.2 会把紧跟
# 在 $VAR 后面的全角字符（如 "）"、"、"）误当作变量名的一部分。
set -euo pipefail

REPO="xitihangto/SimplePDFReader"
VERSION="${1:-latest}"
APP_DIR="/Applications/SimplePDFReader.app"
ASSET="SimplePDFReader-macOS-arm64.zip"

TMP_DIR="$(mktemp -d /tmp/spdf-update.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

echo "==> 下载 Release 产物（版本：${VERSION}）"
if [ "${VERSION}" = "latest" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  case "${VERSION}" in
    v*) ;;
    *) echo "错误：版本号必须以 v 开头（例如 v1.5.0），当前为 '${VERSION}'。" >&2; exit 1 ;;
  esac
  URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi
# -f：HTTP 失败时返回非 0；-L：跟随 latest/download 的重定向；--retry：容忍网络抖动
curl -fL --retry 3 -o "${TMP_DIR}/${ASSET}" "${URL}"

echo "==> 解压并校验签名"
unzip -q -o "${TMP_DIR}/${ASSET}" -d "${TMP_DIR}"
codesign --verify --deep --strict --verbose=2 "${TMP_DIR}/SimplePDFReader.app" >/dev/null
NEW_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${TMP_DIR}/SimplePDFReader.app/Contents/Info.plist")"
NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "${TMP_DIR}/SimplePDFReader.app/Contents/Info.plist")"
if [ "${NEW_BUNDLE_ID}" != "com.spark.SimplePDFReader" ]; then
  echo "错误：产物 Bundle ID 异常（${NEW_BUNDLE_ID}），疑似下载错了文件。" >&2
  exit 1
fi
echo "    产物版本：${NEW_VERSION}（Bundle ID：${NEW_BUNDLE_ID}）"

if [ -d "${APP_DIR}" ]; then
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${APP_DIR}/Contents/Info.plist" 2>/dev/null || echo unknown)"
  if [ "${OLD_VERSION}" = "${NEW_VERSION}" ]; then
    echo "==> 已安装版本即为 ${NEW_VERSION}，无需更新。"
    exit 0
  fi
  echo "==> 当前已安装版本：${OLD_VERSION}"
  # 先尝试优雅退出正在运行的实例（Apple Event，不需要辅助功能权限；失败不影响后续）
  osascript -e 'with timeout of 5 seconds
quit app "SimplePDFReader"
end timeout' >/dev/null 2>&1 || true
  sleep 1
  # 旧版移入废纸篓，保留回退余地；trash 不可用时退回到手动 mv
  trash "${APP_DIR}" 2>/dev/null \
    || mv "${APP_DIR}" "${HOME}/.Trash/SimplePDFReader-${OLD_VERSION}.app"
fi

echo "==> 安装到 /Applications"
mv "${TMP_DIR}/SimplePDFReader.app" "${APP_DIR}"
echo "完成：/Applications/SimplePDFReader.app（${NEW_VERSION}）。"

# 安装后自查（与 README「安装后可自查」一致）
codesign --verify --verbose=2 "${APP_DIR}" >/dev/null \
  && echo "签名自查：valid on disk"
if xattr -p com.apple.quarantine "${APP_DIR}" >/dev/null 2>&1; then
  echo "警告：产物带有 com.apple.quarantine 标记（curl 下载不应有此标记，请检查下载链路）。" >&2
else
  echo "隔离属性自查：无 com.apple.quarantine"
fi
