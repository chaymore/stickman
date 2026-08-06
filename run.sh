#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.local-build"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
OUTPUT_BIN="$BUILD_DIR/Stickman"

mkdir -p "$MODULE_CACHE_DIR"

swiftc \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework AVFoundation \
  -framework EventKit \
  -framework Security \
  -framework UserNotifications \
  -framework Network \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$OUTPUT_BIN"

if [[ ! -x "$OUTPUT_BIN" ]]; then
  echo "Stickman binary was not created" >&2
  exit 1
fi

if [[ "${1:-}" == "--compile-check" ]]; then
  echo "Stickman compiled successfully: $OUTPUT_BIN"
  exit 0
fi

exec "$OUTPUT_BIN" "$@"
