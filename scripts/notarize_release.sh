#!/bin/bash
# Notarize and staple the app before packaging it into a separately notarized DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${APP_PATH:-$REPO_ROOT/LaunchGrid.app}"
REPO="CacinieP/launchgrid"
PROFILE="${NOTARY_PROFILE:-launchgrid-notary}"
TEAM_ID="${TEAM_ID:-5CFSU44B7Q}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

[ -d "$APP" ] || { echo "FATAL: App not found: $APP"; exit 1; }
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VERSION="${VERSION:-$APP_VERSION}"
[ "$VERSION" = "$APP_VERSION" ] || { echo "FATAL: VERSION does not match the app"; exit 1; }
TAG="v$VERSION"
SOURCE_REF="${SOURCE_REF:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
APP_SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :LaunchGridSourceCommit' "$APP/Contents/Info.plist")"
[ "$APP_SOURCE" = "$SOURCE_REF" ] || { echo "FATAL: Source mismatch; rebuild first"; exit 1; }
NOTES_FILE="${NOTES_FILE:-$REPO_ROOT/doc/releases/$VERSION.md}"
[ -f "$NOTES_FILE" ] || { echo "FATAL: Missing release notes: $NOTES_FILE"; exit 1; }
git -C "$REPO_ROOT" diff --quiet
git -C "$REPO_ROOT" diff --cached --quiet
gh auth status >/dev/null 2>&1 || { echo "FATAL: GitHub authentication unavailable"; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "FATAL: $TAG already exists; nothing has been replaced"
  exit 1
fi

codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep "TeamIdentifier=$TEAM_ID" >/dev/null
codesign -dv --verbose=4 "$APP" 2>&1 | grep 'flags=0x10000(runtime)' >/dev/null

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  if [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    : "${APPLE_ID:?Provide APPLE_ID for Apple ID authentication}"
    xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" --password "$APPLE_APP_PASSWORD" --validate
  else
    : "${P8_PATH:?No Keychain profile; provide P8_PATH}"
    : "${KEY_ID:?Provide KEY_ID}"
    if [ -n "${ISSUER_ID:-}" ]; then
      xcrun notarytool store-credentials "$PROFILE" --key "$P8_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --validate
    else
      printf '\n' | xcrun notarytool store-credentials "$PROFILE" --key "$P8_PATH" --key-id "$KEY_ID" --validate
    fi
  fi
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP_ZIP="$STAGE/LaunchGrid-$VERSION.zip"
echo "Notarizing app $VERSION from $SOURCE_REF"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --wait --keychain-profile "$PROFILE"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

mkdir -p "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/LaunchGrid.app"
ln -s /Applications "$STAGE/dmg/Applications"
DMG_FINAL="$OUT_DIR/LaunchGrid-$VERSION.dmg"
[ ! -e "$DMG_FINAL" ] || { echo "FATAL: Output already exists: $DMG_FINAL"; exit 1; }
hdiutil create -volname LaunchGrid -srcfolder "$STAGE/dmg" -format UDZO "$DMG_FINAL" >/dev/null
xcrun notarytool submit "$DMG_FINAL" --wait --keychain-profile "$PROFILE"
xcrun stapler staple "$DMG_FINAL"
xcrun stapler validate "$DMG_FINAL"

SOURCE_ARCHIVE="$OUT_DIR/LaunchGrid-$VERSION-source.tar.gz"
git -C "$REPO_ROOT" archive --format=tar.gz --prefix="LaunchGrid-$VERSION/" \
  --output="$SOURCE_ARCHIVE" "$SOURCE_REF"
CHECKSUMS="$OUT_DIR/SHA256SUMS.txt"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG_FINAL")" "$(basename "$SOURCE_ARCHIVE")" > "$CHECKSUMS")

if [ "${PUBLISH:-1}" = 1 ]; then
  gh release create "$TAG" "$DMG_FINAL" "$SOURCE_ARCHIVE" "$CHECKSUMS" --repo "$REPO" \
    --target "$SOURCE_REF" --title "LaunchGrid $VERSION" --notes-file "$NOTES_FILE"
  echo "Published: https://github.com/$REPO/releases/tag/$TAG"
else
  echo "Verified artifacts ready in $OUT_DIR; PUBLISH=0 left GitHub unchanged"
fi
