#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc Tests/TestRunner.swift \
  Sources/FileSystemService.swift \
  Sources/ClipboardService.swift \
  Sources/RootPathStore.swift \
  Sources/FinderVisibilityService.swift \
  Sources/FinderSelectionService.swift \
  Sources/ShortcutSettingsStore.swift \
  Sources/ShortcutMenuAppearance.swift \
  Sources/GlobalShortcutState.swift \
  Sources/KeyboardEventSynthesizer.swift \
  Sources/CommandQTargetProvider.swift \
  Sources/FinderDismissService.swift \
  Sources/GlobalShortcutService.swift \
  Sources/LaunchAtLoginService.swift \
  Sources/MouseWheelReverseStore.swift \
  Sources/MouseWheelReverseService.swift \
  -o build/tests \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework UserNotifications \
  -framework ServiceManagement

./build/tests
