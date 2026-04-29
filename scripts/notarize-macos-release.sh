#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-Sidemesh}"
VERSION="${VERSION:?VERSION is required}"
APPLE_ID="${APPLE_ID:?APPLE_ID is required}"
APP_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD is required}"
TEAM_ID="${TEAM_ID:?TEAM_ID is required}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

DIST_DIR="$ROOT_DIR/artifacts/macos/$VERSION"
APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.dmg"
APP_NOTARY_LOG="$DIST_DIR/notary-app-log.json"
DMG_NOTARY_LOG="$DIST_DIR/notary-dmg-log.json"
DMG_STAGE="$DIST_DIR/dmg-stage"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ZIP not found: $ZIP_PATH" >&2
  exit 1
fi

submit_and_require_acceptance() {
  local artifact_path="$1"
  local log_path="$2"

  xcrun notarytool submit "$artifact_path" \
    --apple-id "$APPLE_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAM_ID" \
    --output-format json \
    --wait \
    2>&1 | tee "$log_path"

  python3 - "$log_path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
status = payload.get("status")
if status != "Accepted":
    raise SystemExit(f"notarization status was {status!r}, expected 'Accepted'")
PY
}

echo "Submitting app ZIP for notarization: $ZIP_PATH"
submit_and_require_acceptance "$ZIP_PATH" "$APP_NOTARY_LOG"

echo "Stapling app ticket: $APP_PATH"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "Recreating ZIP from stapled app"
rm -f "$ZIP_PATH"
(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

echo "Recreating DMG from stapled app"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGE"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

echo "Submitting DMG for notarization: $DMG_PATH"
submit_and_require_acceptance "$DMG_PATH" "$DMG_NOTARY_LOG"

echo "Stapling DMG ticket: $DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Notarization complete:"
echo "$ZIP_PATH"
echo "$DMG_PATH"
