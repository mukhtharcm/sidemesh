#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOBILE_DIR="$ROOT_DIR/apps/mobile"

FLAVOR="${FLAVOR:-prod}"
case "$FLAVOR" in
  dev)
    APP_NAME="${APP_NAME:-Sidemesh Dev}"
    BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.sidemesh.sidemeshMobile.dev}"
    ;;
  prod)
    APP_NAME="${APP_NAME:-Sidemesh}"
    BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.sidemesh.sidemeshMobile}"
    ;;
  *)
    echo "Unsupported FLAVOR: $FLAVOR (expected dev or prod)" >&2
    exit 1
    ;;
esac
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
FLUTTER_BUILD_NAME="${FLUTTER_BUILD_NAME:-${VERSION%%-*}}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$MOBILE_DIR/macos/Runner/Release.entitlements}"
ENABLE_DATA_PROTECTION_KEYCHAIN=false
if [[ -n "$SIGNING_IDENTITY" && -n "$TEAM_ID" ]]; then
  ENABLE_DATA_PROTECTION_KEYCHAIN=true
fi
SIGNING_ENTITLEMENTS_PATH="$ENTITLEMENTS_PATH"
signing_entitlements_tmp=""

cleanup() {
  if [[ -n "$signing_entitlements_tmp" && -f "$signing_entitlements_tmp" ]]; then
    rm -f "$signing_entitlements_tmp"
  fi
}
trap cleanup EXIT

BUILD_PRODUCTS_DIR="$MOBILE_DIR/build/macos/Build/Products/Release-$FLAVOR"
BUILT_APP_PATH="$BUILD_PRODUCTS_DIR/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/artifacts/macos/$VERSION"
DIST_APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-macos.dmg"
DMG_STAGE="$DIST_DIR/dmg-stage"

echo "Sidemesh macOS release"
echo "App: $APP_NAME"
echo "Version: $VERSION ($BUILD_NUMBER)"
echo "Flavor: $FLAVOR"
echo "Bundle version: $FLUTTER_BUILD_NAME"
echo "Bundle: $BUNDLE_IDENTIFIER"
echo "Signing: ${SIGNING_IDENTITY:-unsigned/ad-hoc}"
echo "Data protection keychain: $ENABLE_DATA_PROTECTION_KEYCHAIN"

cd "$MOBILE_DIR"
flutter pub get
dart_defines=()
if [[ "$ENABLE_DATA_PROTECTION_KEYCHAIN" == "true" ]]; then
  dart_defines+=(
    --dart-define=SIDEMESH_MACOS_USE_DATA_PROTECTION_KEYCHAIN=true
  )
fi
flutter build macos \
  --release \
  --flavor "$FLAVOR" \
  --build-name "$FLUTTER_BUILD_NAME" \
  --build-number "$BUILD_NUMBER" \
  "${dart_defines[@]}"

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "Built app not found: $BUILT_APP_PATH" >&2
  find "$MOBILE_DIR/build/macos/Build/Products" -maxdepth 3 -name "*.app" -print 2>/dev/null || true
  exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP_PATH/Contents/Info.plist")"
if [[ "$actual_bundle_id" != "$BUNDLE_IDENTIFIER" ]]; then
  echo "Unexpected bundle id: $actual_bundle_id, expected $BUNDLE_IDENTIFIER" >&2
  exit 1
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing app with Developer ID identity: $SIGNING_IDENTITY"
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi
  if [[ "$ENABLE_DATA_PROTECTION_KEYCHAIN" == "true" ]]; then
    signing_entitlements_tmp="$(mktemp "${TMPDIR:-/tmp}/sidemesh-release-entitlements.XXXXXX.plist")"
    cp "$ENTITLEMENTS_PATH" "$signing_entitlements_tmp"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_IDENTIFIER" "$signing_entitlements_tmp" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier $TEAM_ID.$BUNDLE_IDENTIFIER" "$signing_entitlements_tmp"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$signing_entitlements_tmp" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $TEAM_ID" "$signing_entitlements_tmp"
    SIGNING_ENTITLEMENTS_PATH="$signing_entitlements_tmp"
  fi

  if [[ -d "$BUILT_APP_PATH/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
      codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$item"
    done < <(find "$BUILT_APP_PATH/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0)
  fi

  codesign \
    --force \
    --deep \
    --timestamp \
    --options runtime \
    --entitlements "$SIGNING_ENTITLEMENTS_PATH" \
    --sign "$SIGNING_IDENTITY" \
    "$BUILT_APP_PATH"

  codesign --verify --deep --strict --verbose=2 "$BUILT_APP_PATH"
else
  echo "No SIGNING_IDENTITY provided; creating unsigned/ad-hoc artifacts."
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS_PATH" "$BUILT_APP_PATH" || true
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP_PATH" "$DIST_APP_PATH"

echo "Creating ZIP: $ZIP_PATH"
(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP_PATH"
)

echo "Creating DMG: $DMG_PATH"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$DIST_APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
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

echo "Artifacts:"
echo "$ZIP_PATH"
echo "$DMG_PATH"
