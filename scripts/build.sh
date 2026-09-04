#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tocode.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/*.swift \
  -o "$APP/Contents/MacOS/Tocode" \
  -framework AppKit

cp Resources/Info.plist "$APP/Contents/Info.plist"

# 生成 app 图标（与菜单栏一致的 folder 符号）
mkdir -p "$APP/Contents/Resources"
swiftc -O scripts/render_icon.swift -o build/render_icon -framework AppKit
./build/render_icon build/icon_1024.png

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名，让本地通知等系统服务能识别该应用
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
