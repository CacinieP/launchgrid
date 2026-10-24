#!/bin/bash
# 构建 LaunchGrid.app（release + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_ARGS=(-c release)
if [ "${UNIVERSAL:-1}" = 1 ]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP="LaunchGrid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LaunchGrid" "$APP/Contents/MacOS/LaunchGrid"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
SOURCE_COMMIT="$(git rev-parse HEAD)"
/usr/libexec/PlistBuddy -c "Add :LaunchGridSourceCommit string $SOURCE_COMMIT" "$APP/Contents/Info.plist"
cat > "$APP/Contents/Resources/SOURCE.md" <<EOF
LaunchGrid — Copyright (c) 2026 CacinieP
SPDX-License-Identifier: AGPL-3.0-only

Corresponding source for this build:
https://github.com/CacinieP/launchgrid/tree/$SOURCE_COMMIT
https://github.com/CacinieP/launchgrid/archive/$SOURCE_COMMIT.tar.gz

The complete GNU Affero General Public License v3 is included in LICENSE.
EOF
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP"
echo "Install:  cp -R $APP /Applications/ && open -a LaunchGrid"
