#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tocode.app"
mkdir -p "$APP/Contents/MacOS"

FRAMEWORKS=(
  -framework AppKit
  -framework ApplicationServices
  -framework CoreGraphics
  -framework CoreImage
  -framework Security
  -framework UserNotifications
  -framework ServiceManagement
  -framework Network
  -lsqlite3
)

# App 与 CLI 各自一个 @main，分两次编译避免入口冲突。
APP_SOURCES=()
CLI_SOURCES=()
for file in Sources/*.swift; do
  base="$(basename "$file")"
  case "$base" in
    TocodeCLI.swift)
      CLI_SOURCES+=("$file")
      ;;
    TocodeApp.swift|AppDelegate.swift|StatusItemController.swift|MenuBuilder.swift)
      APP_SOURCES+=("$file")
      ;;
    ModelRelay*.swift)
      APP_SOURCES+=("$file")
      ;;
    TocodeCLIRunner.swift)
      CLI_SOURCES+=("$file")
      ;;
    *)
      APP_SOURCES+=("$file")
      CLI_SOURCES+=("$file")
      ;;
  esac
done

swiftc -O "${APP_SOURCES[@]}" \
  -o "$APP/Contents/MacOS/Tocode" \
  "${FRAMEWORKS[@]}"

mkdir -p build
swiftc -O "${CLI_SOURCES[@]}" \
  -o build/tocode \
  "${FRAMEWORKS[@]}"

bash scripts/build_togent_runtime.sh

cp Resources/Info.plist "$APP/Contents/Info.plist"

# 生成 app 图标（与菜单栏一致的 folder 符号）
mkdir -p "$APP/Contents/Resources"
rm -rf "$APP/Contents/Resources/Togent"
mkdir -p "$APP/Contents/Resources/Togent"
cp -R build/togent-runtime/. "$APP/Contents/Resources/Togent/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Togent/"
cp Vendor/pi-agent/LICENSE "$APP/Contents/Resources/Togent/PI_LICENSE"
cp Vendor/pi-agent/BUN_LICENSE.md "$APP/Contents/Resources/Togent/BUN_LICENSE.md"
cp Vendor/pi-agent/TOCODE_VENDOR_SOURCE "$APP/Contents/Resources/Togent/"
cp Vendor/pi-agent/TOCODE_VENDOR_PATCHES "$APP/Contents/Resources/Togent/"
cp Resources/Togent/README.md "$APP/Contents/Resources/Togent/TOCODE_README.md"
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

# Bun 产物自带的 linker-signed 签名在复制后不可验证；先显式重签内置运行时，
# 再封装 App 的资源 seal，保证 nested codesign 可独立校验。
codesign --force --sign - \
  --identifier "com.tocode.mac.togent.pi" \
  "$APP/Contents/Resources/Togent/pi"

# 本地 ad-hoc 构建显式使用稳定 designated requirement。
# 否则默认 DR 会绑定每次变化的 cdhash，重编译后 TCC 会静默拒绝旧的 Apple Events 授权。
codesign --force --deep --sign - \
  --identifier "com.tocode.mac" \
  --requirements '=designated => identifier "com.tocode.mac"' \
  "$APP"

echo "Built $APP"
echo "Built build/tocode"
