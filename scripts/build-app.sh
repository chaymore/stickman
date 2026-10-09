#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Stickman.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ARCH_LIST="${STICKMAN_ARCHS:-arm64 x86_64}"
MINIMUM_MACOS_VERSION="${STICKMAN_MINIMUM_MACOS_VERSION:-13.0}"
BUNDLE_ID="${STICKMAN_BUNDLE_ID:-com.chaymore.Stickman}"
APP_VERSION="${STICKMAN_VERSION:-0.6.0}"
BUILD_NUMBER="${STICKMAN_BUILD_NUMBER:-7}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ROOT_DIR/.local-build"

# Stickman.app carries Stickman Blocker's root daemon, installer, and recovery tool, plus
# the computer-use MCP relay, alongside the app itself. SwiftPM builds them once per architecture.
PRODUCTS=(Stickman StickmanBlockerDaemon StickmanBlockerInstaller stickman-blocker-recover stickman-computer-use)
SCRATCH_ROOT="${STICKMAN_BUILD_PATH:-${TMPDIR:-/tmp}/stickman-build}"
BIN_DIRS=()
for ARCH in ${(z)ARCH_LIST}; do
  SCRATCH="$SCRATCH_ROOT/$ARCH"
  (cd "$ROOT_DIR" && swift build -c release --triple "$ARCH-apple-macosx$MINIMUM_MACOS_VERSION" --scratch-path "$SCRATCH")
  BIN_DIRS+=("$(cd "$ROOT_DIR" && swift build -c release --triple "$ARCH-apple-macosx$MINIMUM_MACOS_VERSION" --scratch-path "$SCRATCH" --show-bin-path)")
done

for PRODUCT in "${PRODUCTS[@]}"; do
  # The app binary is the bundle's executable itself, so macOS privacy grants made for
  # Stickman.app apply to the running process. LaunchEnvironment.swift loads its API keys.
  DESTINATION="$MACOS_DIR/$PRODUCT"
  INPUTS=()
  for BIN_DIR in "${BIN_DIRS[@]}"; do INPUTS+=("$BIN_DIR/$PRODUCT"); done
  if (( ${#INPUTS[@]} == 1 )); then
    cp "${INPUTS[1]}" "$DESTINATION"
  else
    lipo -create "${INPUTS[@]}" -output "$DESTINATION"
  fi
  chmod +x "$DESTINATION"
done

cp "$ROOT_DIR/STICKMAN_SYSTEM_PROMPT.md" "$RESOURCES_DIR/STICKMAN_SYSTEM_PROMPT.md"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  ditto "$ROOT_DIR/Resources" "$RESOURCES_DIR"
fi


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
  <string>Stickman controls Chrome tabs when you ask, and redirects blocked Safari and Chrome tabs to the Blocked by Stickman page.</string>
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
  # A local self-signed "Stickman Local Signing" identity, when present, gives every build
  # the same code identity, so macOS keeps Accessibility and Screen Recording grants across
  # reinstalls. Without it the build is ad-hoc signed and the grants reset each time.
  LOCAL_IDENTITY="Stickman Local Signing"
  if [[ -z "${STICKMAN_SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  else
    SIGN_IDENTITY="${STICKMAN_SIGN_IDENTITY:--}"
  fi
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
  elif [[ "$SIGN_IDENTITY" == "$LOCAL_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
  else
    codesign --force --deep --options runtime \
      --entitlements "$ROOT_DIR/Resources/Stickman.entitlements" \
      --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
  fi
fi

echo "Built universal Stickman.app ($ARCH_LIST) at $APP_DIR"
