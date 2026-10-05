#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/pi-agent"
OUTPUT="$ROOT/build/togent-runtime"
SOURCE_MARKER="$VENDOR/TOCODE_VENDOR_SOURCE"
PATCH_MARKER="$VENDOR/TOCODE_VENDOR_PATCHES"
MODEL_MANIFEST="$VENDOR/packages/ai/src/providers/data/.manifest.json"
SESSION_MANAGER="$VENDOR/packages/coding-agent/src/core/session-manager.ts"
BUN_VERSION="1.3.13"
BUN_BIN="$VENDOR/node_modules/.bin/bun"

if [[ ! -f "$SOURCE_MARKER" \
      || ! -f "$PATCH_MARKER" \
      || ! -f "$VENDOR/package-lock.json" \
      || ! -f "$MODEL_MANIFEST" \
      || ! -f "$SESSION_MANAGER" ]]; then
  echo "Vendored Pi source, lockfile, or offline model data is missing." >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="darwin-arm64" ;;
  Darwin-x86_64) PLATFORM="darwin-x64" ;;
  *)
    echo "Togent runtime currently supports Darwin arm64/x64 only." >&2
    exit 1
    ;;
esac

FINGERPRINT="$PLATFORM:$(shasum -a 256 \
  "$SOURCE_MARKER" \
  "$PATCH_MARKER" \
  "$VENDOR/package-lock.json" \
  "$MODEL_MANIFEST" \
  "$SESSION_MANAGER" \
  | shasum -a 256 | awk '{print $1}')"
if [[ "${TOGENT_REBUILD:-0}" != "1" \
      && -x "$OUTPUT/pi" \
      && -f "$OUTPUT/.tocode-runtime-fingerprint" \
      && "$(cat "$OUTPUT/.tocode-runtime-fingerprint")" == "$FINGERPRINT" ]]; then
  echo "Togent runtime is current: $OUTPUT/pi"
  exit 0
fi

TEMP_OUTPUT="$ROOT/build/togent-runtime-build"
rm -rf "$TEMP_OUTPUT" "$OUTPUT"

ARGS=(--offline-model-data --platform "$PLATFORM" --out "$TEMP_OUTPUT")
if [[ ! -x "$BUN_BIN" \
      || "$("$BUN_BIN" --version 2>/dev/null || true)" != "$BUN_VERSION" ]]; then
  (
    cd "$VENDOR"
    npm ci --ignore-scripts
    node node_modules/bun/install.js
  )
fi
if [[ ! -x "$BUN_BIN" \
      || "$("$BUN_BIN" --version 2>/dev/null || true)" != "$BUN_VERSION" ]]; then
  echo "Pinned Bun $BUN_VERSION is unavailable." >&2
  exit 1
fi
ARGS=(--skip-install "${ARGS[@]}")

(
  cd "$VENDOR"
  export PATH="$VENDOR/node_modules/.bin:$PATH"
  ./scripts/build-binaries.sh "${ARGS[@]}"
)

cp -R "$TEMP_OUTPUT/$PLATFORM" "$OUTPUT"
printf '%s\n' "$FINGERPRINT" > "$OUTPUT/.tocode-runtime-fingerprint"
chmod 0755 "$OUTPUT/pi"
rm -rf "$TEMP_OUTPUT"

echo "Built Togent runtime: $OUTPUT/pi"
