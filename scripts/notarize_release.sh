#!/bin/bash
# LaunchGrid 公证 + GitHub Release 流水线（双认证模式）
#
# 前置条件：
#   1. /Applications/LaunchGrid.app 已用 "Developer ID Application" 证书签名
#      （含 hardened runtime 与安全时间戳；签名方法见 README「公证与发布」）
#   2. GitHub 认证：git 凭据助手已存 github.com 凭据，或先执行 gh auth login
#
# 用法（二选一）：
#   A. App Store Connect API Key：
#      P8_PATH=/path/AuthKey_XXX.p8 KEY_ID=XXXXXXXXXX [ISSUER_ID=<UUID>] bash scripts/notarize_release.sh
#      （ISSUER_ID 仅 Team/组织账号需要；Individual 账号不填）
#   B. Apple ID + App 专用密码（appleid.apple.com → Sign-In and Security 生成）：
#      APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx bash scripts/notarize_release.sh
#
# 流程：前置检查 → 打提交包 → 存凭据(带验证) → notarytool submit --wait
#       → stapler staple+validate → spctl 门禁(不过则中止，不会误发)
#       → 重打包 → gh release create
#
# 可调参数：VERSION（默认读 app 的 CFBundleShortVersionString）、OUT_DIR（默认 ~/Desktop）
set -euo pipefail

APP_NAME="LaunchGrid"
APP="/Applications/${APP_NAME}.app"
REPO="CacinieP/launchgrid"
PROFILE="launchgrid-notary"
APPLE_ID="${APPLE_ID:-cacinie@163.com}"
TEAM_ID="${TEAM_ID:-5CFSU44B7Q}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH=/opt/homebrew/bin:$PATH

MODE="asc_key"
[ -n "${APPLE_APP_PASSWORD:-}" ] && MODE="apple_id"

# ---------- 0/8 前置检查 ----------
echo "== 0/8 前置检查（认证模式: $MODE）"
[ -d "$APP" ] || { echo "FATAL: $APP 不存在（先安装）"; exit 1; }

VERSION="${VERSION:-$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
TAG="v${VERSION}"
OUT_DIR="${OUT_DIR:-$HOME/Desktop}"
ZIP_SUBMIT="${OUT_DIR}/${APP_NAME}-${VERSION}-submit.zip"
ZIP_FINAL="${OUT_DIR}/${APP_NAME}-${VERSION}.zip"
echo "版本: $VERSION  tag: $TAG"

codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" \
  || { echo "FATAL: app 未用 Developer ID Application 签名（Team $TEAM_ID）"; exit 1; }
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
  || { echo "FATAL: app 未启用 hardened runtime（codesign 缺 --options runtime）"; exit 1; }

if [ "$MODE" = "asc_key" ]; then
  P8_PATH="${P8_PATH:?必须提供 .p8 路径}"
  KEY_ID="${KEY_ID:?必须提供 Key ID}"
  [ -f "$P8_PATH" ] || { echo "FATAL: .p8 不存在: $P8_PATH"; exit 1; }
  chmod 600 "$P8_PATH"
  echo "OK: app 签名有效 / hardened runtime 就绪 / .p8 权限 600"
else
  echo "OK: app 签名有效 / hardened runtime 就绪"
fi

# ---------- 1/8 打提交包 ----------
echo "== 1/8 打提交包（ditto PK-Zip）"
rm -f "$ZIP_SUBMIT"
ditto -c -k --keepParent "$APP" "$ZIP_SUBMIT"
file "$ZIP_SUBMIT" | grep -q "Zip archive" || { echo "FATAL: 提交包不是有效 Zip"; exit 1; }
echo "OK: $ZIP_SUBMIT ($(du -h "$ZIP_SUBMIT" | awk '{print $1}'))"

# ---------- 2/8 存凭据 ----------
echo "== 2/8 存储 notarytool 凭据并验证"
if [ "$MODE" = "apple_id" ]; then
  xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --validate
elif [ -n "${ISSUER_ID:-}" ]; then
  xcrun notarytool store-credentials "$PROFILE" \
    --key "$P8_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --validate
else
  # Individual Key：notarytool 仍会弹 Issuer ID 提问，喂空行即可
  printf '\n' | xcrun notarytool store-credentials "$PROFILE" \
    --key "$P8_PATH" --key-id "$KEY_ID" --validate
fi

# ---------- 3/8 提交公证 ----------
echo "== 3/8 提交公证并等待（通常 1-5 分钟）"
xcrun notarytool submit "$ZIP_SUBMIT" --wait --keychain-profile "$PROFILE"

# ---------- 4/8 staple ----------
echo "== 4/8 stapling 公证票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ---------- 5/8 Gatekeeper 门禁 ----------
echo "== 5/8 Gatekeeper 验证（不过则中止，不会发布）"
spctl -a -t exec -v "$APP"

# ---------- 6/8 重打包 ----------
echo "== 6/8 重打包 stapled 版（供分发）"
rm -f "$ZIP_FINAL"
ditto -c -k --keepParent "$APP" "$ZIP_FINAL"

# ---------- 7/8 Release notes ----------
NOTES="$(mktemp)"
cat > "$NOTES" <<EOF
macOS 26/27 启动台（Launchpad）移除后的自建替代：按 F4 或点菜单栏网格图标唤出全屏 App 网格，支持搜索、分页、点击启动。

- 要求：macOS 26 (Tahoe) 或更高
- 安装：解压后拖入 /Applications，直接打开即可（Developer ID 签名 + Apple 已公证）
- 用法：F4 唤出/收起 · Esc 关闭 · 顶部搜索框过滤 · 点击图标启动 · 菜单栏图标可刷新/退出
- 源码与构建说明：https://github.com/$REPO
EOF

# ---------- 8/8 建 Release ----------
echo "== 8/8 创建 GitHub Release"
cd "$REPO_ROOT"
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
[ -n "$TOKEN" ] || { echo "FATAL: 取不到 git 凭据（先 gh auth login）"; exit 1; }
export GH_TOKEN="$TOKEN"
gh release create "$TAG" "$ZIP_FINAL" \
  --repo "$REPO" \
  --title "${APP_NAME} ${VERSION}" \
  --notes-file "$NOTES"
rm -f "$NOTES"

echo "== 全部完成 =="
echo "分发包: $ZIP_FINAL"
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "提示：若 tag $TAG 已存在，先 gh release delete $TAG 或提升 VERSION 再跑"
