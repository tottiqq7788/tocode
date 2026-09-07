#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc Tests/TestRunner.swift \
  Tests/WeChatTestSupport.swift \
  Sources/FileSystemService.swift \
  Sources/ClipboardService.swift \
  Sources/RootPathStore.swift \
  Sources/CodexProjectService.swift \
  Sources/CodexSyncSettingsStore.swift \
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
  Sources/WeChatModels.swift \
  Sources/WeChatCrypto.swift \
  Sources/WeChatILinkClient.swift \
  Sources/WeChatCredentialStore.swift \
  Sources/WeChatStateStore.swift \
  Sources/WeChatArchiveService.swift \
  Sources/WeChatBindingPage.swift \
  Sources/WeChatAssociationService.swift \
  -o build/tests \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework Security \
  -framework UserNotifications \
  -framework ServiceManagement

./build/tests
