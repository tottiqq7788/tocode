#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tomaid.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/*.swift \
  -o "$APP/Contents/MacOS/Tomaid" \
  -framework AppKit

cp Resources/Info.plist "$APP/Contents/Info.plist"
echo "Built $APP"
