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
  -o build/tests \
  -framework AppKit

./build/tests
