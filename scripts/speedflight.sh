#!/bin/bash
# Cuts a signed ad hoc IPA, uploads it to Speedflight, and prints the page
# link as the last line. Signs through the App Store Connect key in
# .env.speedflight; the key must belong to DEVELOPMENT_TEAM.
#
#   scripts/speedflight.sh "<title>" "<notes>" [screenshot.png ...]
#
# The page link is the only auth for installing. The secret in
# .env.speedflight is the only auth for uploading. Do not paste either
# anywhere public.
set -euo pipefail
cd "$(dirname "$0")/.."

TITLE="${1:?usage: speedflight.sh \"<title>\" \"<notes>\" [screenshot.png ...]}"
NOTES="${2:?usage: speedflight.sh \"<title>\" \"<notes>\" [screenshot.png ...]}"
shift 2
SCREENSHOTS=("$@")

if [[ -f .env.speedflight ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.speedflight
  set +a
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID in .env.speedflight}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in .env.speedflight}"
: "${SPEEDFLIGHT_SECRET:?set SPEEDFLIGHT_SECRET in .env.speedflight}"
: "${SPEEDFLIGHT_DEEP_LINK:?set SPEEDFLIGHT_DEEP_LINK in .env.speedflight}"
: "${SPEEDFLIGHT_AUTHOR:?set SPEEDFLIGHT_AUTHOR in .env.speedflight}"
ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$ASC_PRIVATE_KEY_PATH" ]] || { echo "missing ASC key file: $ASC_PRIVATE_KEY_PATH" >&2; exit 1; }

PROJECT="apps/mobile/ios/Runner.xcworkspace"
SCHEME="prod"
BUNDLE_ID="dev.sidemesh.mobile"
TEAM_ID="${SPEEDFLIGHT_TEAM_ID:?set SPEEDFLIGHT_TEAM_ID in .env.speedflight}"
BASE="${SPEEDFLIGHT_BASE:-https://speedflight.dev}"
# The same worker on its workers.dev route, kept as an upload fallback. The
# page link stays on the custom domain.
FALLBACK_BASE="https://speedflight.jake-7c3.workers.dev"
OUT="apps/mobile/build/speedflight"

# The page shows a branch and commit, so those must be real: everything
# committed, and the commit on the remote. Under CI the checkout is the
# pushed commit by definition, and a detached HEAD has no upstream to test.
BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
COMMIT="$(git rev-parse HEAD)"
# https form of origin, so the page can link the branch and commit.
REPO_URL="$(git remote get-url origin 2>/dev/null | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##')"
case "$REPO_URL" in https://*) ;; *) REPO_URL="" ;; esac
if [[ -z "${CI:-}" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree is dirty: commit before sharing a build" >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "$COMMIT" "@{u}" 2>/dev/null; then
    echo "HEAD is not pushed: git push -u origin $BRANCH" >&2
    exit 1
  fi
fi

(cd apps/mobile && "${FLUTTER_BIN:-flutter}" build ios --config-only --release --flavor prod)
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Flutter changed tracked files: review and commit before sharing a build" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# Archive signed, not with CODE_SIGNING_ALLOWED=NO: an unsigned archive
# carries no entitlements and the export re-sign does not add them back.
# Cloud signing with the ASC key makes a development certificate for the
# archive and the ad hoc one for the export.
xcodebuild -workspace "$PROJECT" -scheme "$SCHEME" \
  -configuration Release-prod \
  -destination "generic/platform=iOS" \
  -archivePath "$OUT/App.xcarchive" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER="" \
  -quiet archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key><string>export</string>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$OUT/App.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -quiet
mv "$OUT"/export/*.ipa "$OUT/signed.ipa"

# 1. Register the build with its metadata. The server answers with the ids.
META="$(jq -n \
  --arg title "$TITLE" --arg notes "$NOTES" \
  --arg deepLink "$SPEEDFLIGHT_DEEP_LINK" \
  --arg branch "$BRANCH" --arg commit "$COMMIT" \
  --arg author "$SPEEDFLIGHT_AUTHOR" \
  --arg repoUrl "$REPO_URL" \
  '{title:$title, notes:$notes, deepLink:$deepLink, branch:$branch, commit:$commit, author:$author}
   + (if $repoUrl == "" then {} else {repoUrl:$repoUrl} end)')"
create() {
  curl -sfS --retry 3 --retry-all-errors --retry-delay 3 \
    -X POST "$1/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds" \
    -H "Content-Type: application/json" --data "$META"
}
CREATED="$(create "$BASE" || create "$FALLBACK_BASE")"
BUILD_ID="$(jq -er '.buildId | strings | select(test("^[A-Za-z0-9_-]+$"))' <<<"$CREATED")"
PAGE_URL="$(jq -er '.pageUrl | strings | select(startswith("https://"))' <<<"$CREATED")"

# 2. Upload the IPA. The server reads name, version, and build number from
#    its Info.plist and rejects it if the bundle id does not match.
upload() {
  curl -sfS --http1.1 --retry 5 --retry-all-errors --retry-delay 5 \
    -X PUT "$1/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds/$BUILD_ID/app.ipa" \
    --data-binary @"$OUT/signed.ipa" >/dev/null
}
upload "$BASE" || upload "$FALLBACK_BASE"

# 3. Screenshots, if given: what changed, as pictures. Named 01-, 02-, ...
#    so the page keeps the order you passed them in.
# The guarded expansion keeps macOS bash 3.2's set -u happy when no
# screenshots were passed; a bare "${SCREENSHOTS[@]}" aborts the script.
n=0
for shot in ${SCREENSHOTS[@]+"${SCREENSHOTS[@]}"}; do
  [[ -f "$shot" ]] || { echo "no such screenshot: $shot" >&2; continue; }
  n=$((n + 1))
  ext="${shot##*.}"
  case "$ext" in png|PNG) type=image/png ;; jpg|jpeg|JPG|JPEG) type=image/jpeg ;; webp) type=image/webp ;; *) echo "skip $shot: not png/jpg/webp" >&2; continue ;; esac
  name="$(printf '%02d-%s' "$n" "$(basename "$shot" | tr -c 'A-Za-z0-9._-\n' '-')")"
  curl -sfS --retry 3 --retry-all-errors --retry-delay 3 \
    -X PUT "$BASE/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/builds/$BUILD_ID/screenshots/$name" \
    -H "Content-Type: $type" --data-binary @"$shot" >/dev/null || echo "screenshot upload failed: $shot" >&2
done

# 4. Icon, if configured. Best effort.
if [[ -n "${SPEEDFLIGHT_ICON:-}" && -f "$SPEEDFLIGHT_ICON" ]]; then
  curl -sS -X PUT "$BASE/api/apps/$SPEEDFLIGHT_SECRET/$BUNDLE_ID/icon" \
    -H "Content-Type: image/png" --data-binary @"$SPEEDFLIGHT_ICON" >/dev/null || true
fi

echo
echo "Build page: $PAGE_URL"
