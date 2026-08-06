#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${STICKMAN_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

APP_PATH="$ROOT_DIR/dist/Stickman.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Stickman.app is missing. Run without STICKMAN_SKIP_BUILD to build it first." >&2
  exit 1
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
ARCHIVE_PATH="$ROOT_DIR/dist/Stickman-$VERSION-macos-universal.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if [[ -n "${STICKMAN_NOTARY_PROFILE:-}" ]]; then
  if [[ "${STICKMAN_SIGN_IDENTITY:--}" == "-" ]]; then
    echo "STICKMAN_NOTARY_PROFILE requires STICKMAN_SIGN_IDENTITY to be a Developer ID Application identity." >&2
    exit 1
  fi
  TEMP_ARCHIVE="$(mktemp -t Stickman-notary).zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$TEMP_ARCHIVE"
  xcrun notarytool submit "$TEMP_ARCHIVE" --keychain-profile "$STICKMAN_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$TEMP_ARCHIVE"
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
(
  cd "$ROOT_DIR/dist"
  shasum -a 256 "${ARCHIVE_PATH:t}" > "${CHECKSUM_PATH:t}"
)

echo "Packaged $ARCHIVE_PATH"
echo "Checksum $CHECKSUM_PATH"
if [[ "${STICKMAN_SIGN_IDENTITY:--}" == "-" ]]; then
  echo "This build is ad-hoc signed. Set STICKMAN_SIGN_IDENTITY and STICKMAN_NOTARY_PROFILE for a notarized public release."
fi
