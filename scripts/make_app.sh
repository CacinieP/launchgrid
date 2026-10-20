#!/bin/bash
# 构建 LaunchGrid.app（release + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="LaunchGrid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/LaunchGrid" "$APP/Contents/MacOS/LaunchGrid"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Install:  cp -R $APP /Applications/ && open -a LaunchGrid"
