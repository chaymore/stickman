#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH_PATH="${STICKMAN_BUILD_PATH:-${TMPDIR:-/tmp}/stickman-build}/debug"

cd "$ROOT_DIR"
swift build --product Stickman --scratch-path "$SCRATCH_PATH"
OUTPUT_BIN="$(swift build --scratch-path "$SCRATCH_PATH" --show-bin-path)/Stickman"

if [[ ! -x "$OUTPUT_BIN" ]]; then
  echo "Stickman binary was not created" >&2
  exit 1
fi

if [[ "${1:-}" == "--compile-check" ]]; then
  echo "Stickman compiled successfully: $OUTPUT_BIN"
  exit 0
fi

exec "$OUTPUT_BIN" "$@"
