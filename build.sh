#!/bin/bash
# 构建 扫描卡.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="扫描卡"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
BIN="$APP/Contents/MacOS/ScanCard"

mkdir -p "$BUILD_DIR/mc"
echo "==> 编译"
xcrun swiftc \
  -target "$(uname -m)-apple-macos15.0" \
  -swift-version 5 \
  -O \
  -module-cache-path "$BUILD_DIR/mc" \
  Sources/*.swift \
  -framework AppKit -framework Vision -framework ScreenCaptureKit \
  -framework Carbon -framework Security -framework SwiftUI \
  -framework Translation -framework QuartzCore -framework CoreImage \
  -o "$BUILD_DIR/ScanCard"

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/ScanCard" "$BIN"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（签名失败，可忽略，首次运行可能被系统提示）"

echo "==> 完成：$APP"
