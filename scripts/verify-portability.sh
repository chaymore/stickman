#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if rg -n -g '!scripts/verify-portability.sh' -g '!DesignConcepts/**' -g '!NightLock/**' -g '!dist/**' -g '!.build/**' -g '!.local-build/**' '/Users/[A-Za-z0-9._-]+/' .; then
  echo "Found a machine-specific absolute user path." >&2
  exit 1
fi

if rg -n -g '!dist/**' -g '!.build/**' -g '!.local-build/**' -g '!**/node_modules/**' 'sk-(?:or-v1-)?[A-Za-z0-9_-]{20,}|gh[opusr]_[A-Za-z0-9]{20,}' .; then
  echo "Found text that resembles an API credential." >&2
  exit 1
fi

swift test
STICKMAN_ARCHS="$(uname -m)" ./scripts/build-app.sh
codesign --verify --deep --strict dist/Stickman.app
plutil -lint dist/Stickman.app/Contents/Info.plist

echo "Stickman portability checks passed."
