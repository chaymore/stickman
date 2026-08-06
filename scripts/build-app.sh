#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Stickman.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ARCH_LIST="${STICKMAN_ARCHS:-arm64 x86_64}"
MINIMUM_MACOS_VERSION="${STICKMAN_MINIMUM_MACOS_VERSION:-12.0}"
BUNDLE_ID="${STICKMAN_BUNDLE_ID:-com.chaymore.Stickman}"
APP_VERSION="${STICKMAN_VERSION:-0.5.0}"
BUILD_NUMBER="${STICKMAN_BUILD_NUMBER:-6}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ROOT_DIR/.local-build"
BUILD_ROOT="$(mktemp -d "$ROOT_DIR/.local-build/StickmanRelease.XXXXXX")"
cleanup() { rm -rf "$BUILD_ROOT" 2>/dev/null || true }
trap cleanup EXIT

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH_BINARIES=()
BUILD_PIDS=()
for ARCH in ${(z)ARCH_LIST}; do
  ARCH_BUILD_DIR="$BUILD_ROOT/$ARCH"
  mkdir -p "$ARCH_BUILD_DIR/module-cache"
  ARCH_BINARY="$ARCH_BUILD_DIR/StickmanBinary"
  ARCH_BINARIES+=("$ARCH_BINARY")
  (
    xcrun --sdk macosx swiftc \
      -O \
      -whole-module-optimization \
      -swift-version 5 \
      -target "$ARCH-apple-macos$MINIMUM_MACOS_VERSION" \
      -sdk "$SDK_PATH" \
      -module-cache-path "$ARCH_BUILD_DIR/module-cache" \
      -framework AppKit \
      -framework ApplicationServices \
      -framework CoreGraphics \
      -framework AVFoundation \
      -framework EventKit \
      -framework Security \
      -framework UserNotifications \
      -framework Network \
      "$ROOT_DIR"/Sources/*.swift \
      -o "$ARCH_BINARY"
  ) &
  BUILD_PIDS+=("$!")
done

for BUILD_PID in "${BUILD_PIDS[@]}"; do
  wait "$BUILD_PID"
done

if (( ${#ARCH_BINARIES[@]} == 1 )); then
  cp "${ARCH_BINARIES[1]}" "$MACOS_DIR/StickmanBinary"
else
  lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/StickmanBinary"
fi

cp "$ROOT_DIR/STICKMAN_SYSTEM_PROMPT.md" "$RESOURCES_DIR/STICKMAN_SYSTEM_PROMPT.md"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  ditto "$ROOT_DIR/Resources" "$RESOURCES_DIR"
fi

cat > "$MACOS_DIR/Stickman" <<'SCRIPT'
#!/bin/zsh

set -euo pipefail

KEYCHAIN_SERVICE="Stickman OpenAI API Key"
OPENROUTER_KEYCHAIN_SERVICE="Stickman OpenRouter API Key"
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

read_keychain_value() {
  local primary_service="$1"
  local legacy_service="$2"
  local value
  value="$(security find-generic-password -a "$USER" -s "$primary_service" -w 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(security find-generic-password -a "$USER" -s "$legacy_service" -w 2>/dev/null || true)"
  fi
  print -r -- "$value"
}

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  key="$(read_keychain_value "$KEYCHAIN_SERVICE" "Milo OpenAI API Key")"
  if [[ -n "$key" ]]; then
    export OPENAI_API_KEY="$key"
  fi
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  openrouter_key="$(read_keychain_value "$OPENROUTER_KEYCHAIN_SERVICE" "Milo OpenRouter API Key")"
  if [[ -n "$openrouter_key" ]]; then
    export OPENROUTER_API_KEY="$openrouter_key"
  fi
fi

export STICKMAN_PROJECT_DIR="$APP_ROOT/Resources"
export STICKMAN_SYSTEM_PROMPT_PATH="$APP_ROOT/Resources/STICKMAN_SYSTEM_PROMPT.md"

exec "$APP_ROOT/MacOS/StickmanBinary"
SCRIPT

chmod +x "$MACOS_DIR/Stickman" "$MACOS_DIR/StickmanBinary"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Stickman</string>
  <key>CFBundleExecutable</key>
  <string>Stickman</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Stickman</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_MACOS_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Stickman controls Chrome tabs and redirects distracting sites only when you request it or enable a focus rule.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Stickman reads your Calendar.app events to help with classes, meetings, and planned homework time.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Stickman reads your Calendar.app events to help with classes, meetings, and planned homework time.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Stickman needs microphone access so you can talk to him in voice mode.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Stickman creates and reads reminders only when you ask him to manage one.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Stickman creates and reads reminders only when you ask him to manage one.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${STICKMAN_SIGN_IDENTITY:--}"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
  else
    codesign --force --deep --options runtime \
      --entitlements "$ROOT_DIR/Resources/Stickman.entitlements" \
      --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
  fi
fi

echo "Built universal Stickman.app ($ARCH_LIST) at $APP_DIR"
