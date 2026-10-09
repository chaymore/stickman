#!/bin/zsh
# Builds Stickman outside Google Drive (synced folders make SwiftPM slow), runs the tests,
# installs to /Applications, and restarts it. SKIP_TESTS=1 skips the tests.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${STICKMAN_WORK_DIR:-${TMPDIR:-/tmp}/stickman-dev}"
mkdir -p "$WORK"
rsync -a --delete --exclude .build --exclude .local-build --exclude dist --exclude DesignConcepts --exclude .git "$ROOT/" "$WORK/pkg/"
cd "$WORK/pkg"

if [[ "${SKIP_TESTS:-0}" != 1 ]]; then
  if ! swift test --scratch-path "$WORK/spm" > "$WORK/test.log" 2>&1; then
    grep -E "error:|✘" "$WORK/test.log" | head -40
    echo "Tests failed; not installing. Full log: $WORK/test.log"
    exit 1
  fi
  grep -E "Test run with" "$WORK/test.log" || true
fi

STICKMAN_BUILD_PATH="$WORK/release" ./scripts/build-app.sh
codesign --verify --deep --strict dist/Stickman.app

rm -rf /Applications/Stickman.app
ditto dist/Stickman.app /Applications/Stickman.app
# Stickman Blocker's launch agent keeps Stickman running; restart through it when installed.
launchctl kickstart -k "gui/$(id -u)/com.chaymore.NightLock.agent" 2>/dev/null || open /Applications/Stickman.app
codesign -d -r- /Applications/Stickman.app 2>&1 | grep designated
