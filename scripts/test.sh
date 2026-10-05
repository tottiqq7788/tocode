#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_togent_runtime.sh

mkdir -p build
swiftc Tests/TestRunner.swift \
  Tests/WeChatTestSupport.swift \
  Tests/TocodeCommandTestSupport.swift \
  Tests/AnkerCredentialTests.swift \
  Tests/ModelRelayTestSupport.swift \
  Tests/ModelRelayCallMetricsTestSupport.swift \
  Tests/TogentTestSupport.swift \
  Tests/TogentRoleTests.swift \
  Tests/TogentRuntimeTests.swift \
  Tests/TogentWeChatTests.swift \
  Tests/ModelRelayTests.swift \
  Sources/FileSystemService.swift \
  Sources/ClipboardService.swift \
  Sources/RootPathStore.swift \
  Sources/CodexProjectService.swift \
  Sources/CodexSyncSettingsStore.swift \
  Sources/FinderFollowSettingsStore.swift \
  Sources/DirectoryRootResolver.swift \
  Sources/ExtendedSettingsStore.swift \
  Sources/CodexModelSwitchService.swift \
  Sources/AnkerCredentialService.swift \
  Sources/CodexApplicationRestarter.swift \
  Sources/FinderVisibilityService.swift \
  Sources/FinderSelectionService.swift \
  Sources/ShortcutSettingsStore.swift \
  Sources/ShortcutMenuAppearance.swift \
  Sources/AlertFocus.swift \
  Sources/DirectoryMenuMode.swift \
  Sources/DirectoryMenuResume.swift \
  Sources/TocodePreferences.swift \
  Sources/TocodePortableSettings.swift \
  Sources/UserManual.swift \
  Sources/GlobalShortcutState.swift \
  Sources/KeyboardEventSynthesizer.swift \
  Sources/TrackpadShortcut.swift \
  Sources/MultitouchSupportMonitor.swift \
  Sources/TrackpadShortcutService.swift \
  Sources/ShortcutRecorderPrompt.swift \
  Sources/KeyboardShortcutMapping.swift \
  Sources/KeyboardShortcutRemapService.swift \
  Sources/KeyboardShortcutMappingPrompt.swift \
  Sources/MacTimer.swift \
  Sources/MacTimerService.swift \
  Sources/MacTimerPrompt.swift \
  Sources/CommandQTargetProvider.swift \
  Sources/FinderDismissService.swift \
  Sources/GlobalShortcutService.swift \
  Sources/LaunchAtLoginService.swift \
  Sources/MouseWheelReverseStore.swift \
  Sources/MouseWheelReverseService.swift \
  Sources/DockAutohideRestrictStore.swift \
  Sources/DockAutohideRestrictService.swift \
  Sources/ScreenBlackoutService.swift \
  Sources/TogentModels.swift \
  Sources/TogentStore.swift \
  Sources/TogentWorkspaceService.swift \
  Sources/TogentRPCClient.swift \
  Sources/TogentSandbox.swift \
  Sources/TogentGitService.swift \
  Sources/TogentRuntimeService.swift \
  Sources/TogentService.swift \
  Sources/TogentPrompts.swift \
  Sources/WeChatModels.swift \
  Sources/WeChatCrypto.swift \
  Sources/WeChatILinkClient.swift \
  Sources/WeChatCredentialStore.swift \
  Sources/WeChatFileCredentialStore.swift \
  Sources/WeChatStateStore.swift \
  Sources/WeChatArchiveService.swift \
  Sources/WeChatArchiveMigration.swift \
  Sources/WeChatBindingPage.swift \
  Sources/WeChatAssociationService.swift \
  Sources/WeChatQuickInput.swift \
  Sources/TocodeCommand.swift \
  Sources/TocodeRootChooser.swift \
  Sources/TocodeCommandExecutor.swift \
  Sources/TocodeIPCProtocol.swift \
  Sources/TocodeSocketTransport.swift \
  Sources/TocodeIPCServer.swift \
  Sources/TocodeCLIRunner.swift \
  Sources/ModelRelayModels.swift \
  Sources/ModelRelayConfigStore.swift \
  Sources/ModelRelayKeychainStore.swift \
  Sources/ModelRelayLocalKeyVault.swift \
  Sources/ModelRelayCallMetricsStore.swift \
  Sources/ModelRelayHTTPParser.swift \
  Sources/ModelRelayRouter.swift \
  Sources/ModelRelayUpstreamClient.swift \
  Sources/ModelRelayHTTPServer.swift \
  Sources/ModelRelayService.swift \
  Sources/ModelRelayPrompts.swift \
  Sources/ModelRelayStatusPanel.swift \
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
