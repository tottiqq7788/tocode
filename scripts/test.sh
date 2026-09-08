#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc Tests/TestRunner.swift \
  Tests/WeChatTestSupport.swift \
  Tests/TocodeCommandTestSupport.swift \
  Sources/FileSystemService.swift \
  Sources/ClipboardService.swift \
  Sources/RootPathStore.swift \
  Sources/CodexProjectService.swift \
  Sources/CodexSyncSettingsStore.swift \
  Sources/CodexModelSwitchService.swift \
  Sources/CodexApplicationRestarter.swift \
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
  Sources/ScreenBlackoutService.swift \
  Sources/WeChatModels.swift \
  Sources/WeChatCrypto.swift \
  Sources/WeChatILinkClient.swift \
  Sources/WeChatCredentialStore.swift \
  Sources/WeChatFileCredentialStore.swift \
  Sources/WeChatStateStore.swift \
  Sources/WeChatArchiveService.swift \
  Sources/WeChatBindingPage.swift \
  Sources/WeChatAssociationService.swift \
  Sources/TocodeCommand.swift \
  Sources/TocodeRootChooser.swift \
  Sources/TocodeCommandExecutor.swift \
  Sources/TocodeIPCProtocol.swift \
  Sources/TocodeSocketTransport.swift \
  Sources/TocodeIPCServer.swift \
  Sources/TocodeCLIRunner.swift \
  -o build/tests \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework Security \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework Network \
  -lsqlite3

./build/tests
