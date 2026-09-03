#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tomaid.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/*.swift \
  -o "$APP/Contents/MacOS/Tomaid" \
  -framework AppKit

cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名，让本地通知等系统服务能识别该应用
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
