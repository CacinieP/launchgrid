# 打包、验收与发布

[文档目录](README.md) · [开发与调试](development.md) · [0.4.2 更新说明](releases/0.4.2.md)

本文件是维护流程，不表示当前版本已经通过测试、公证或发布。**先用 `PUBLISH=0` 产出并验收，再上传已验收的同一批文件。**

## 1. 准备确切源码

所有变更通过 feature branch → PR → GitHub merge。发布前完成 diff 自审、必要实机验收和 CI，分支按主线更新；不要直接向 main push。合并后使用干净 checkout，并确认 `git status --short` 没有遗漏的改动或需纳入源码的未跟踪文件。

更新 [Info.plist](../Resources/Info.plist) 的 `CFBundleShortVersionString` / `CFBundleVersion`，以及 `doc/releases/<版本>.md`。App bundle ID 为 `app.caciniep.launchgrid`，发行最低系统为 macOS 26.0。正式版本号使用数字段，如 `0.4.2`，tag 为 `v0.4.2`，DMG 为 `LaunchGrid-0.4.2.dmg`。

```bash
swift test
swift build -c release
git status --short
git rev-parse HEAD
```

这些是需执行的命令，不是通过记录。记录实际测试结果、系统/架构和源码 commit；用户一周试用按 [试用清单](USER_TESTING.md) 单独推进。

## 2. 构建通用签名 App

需要 Xcode/Swift 工具链、`gh`、Apple Developer ID Application 签名身份以及可用的公证凭据。凭据留在官方工具与钥匙串中，不写入仓库、日志或发行说明。

从仓库根目录运行，替换签名身份占位文本：

```bash
SIGN_IDENTITY="Developer ID Application: <名称> (<Team ID>)" ./scripts/make_app.sh
```

[make_app.sh](../scripts/make_app.sh) 默认 `--arch arm64 --arch x86_64`，复制二进制、Info.plist、图标和 LICENSE 到 `LaunchGrid.app`，加入 `LaunchGridSourceCommit`，生成带确切源码 URL 的 `SOURCE.md`，再使用 hardened runtime、timestamp 和指定身份签名。此命令会重建仓库根目录的 `LaunchGrid.app`。不提供 `SIGN_IDENTITY` 则是 ad-hoc 开发包；`UNIVERSAL=0` 仅供本机开发，不应冒充通用发行包。

## 3. 仅生成并校验产物

```bash
PUBLISH=0 bash scripts/notarize_release.sh
```

[notarize_release.sh](../scripts/notarize_release.sh) 默认参数：

| 参数 | 默认值/用途 |
|---|---|
| `APP_PATH` | 仓库根的 `LaunchGrid.app` |
| `NOTARY_PROFILE` | 钥匙串 profile `launchgrid-notary` |
| `TEAM_ID` | `5CFSU44B7Q`，需与发行签名及更新器策略一致 |
| `OUT_DIR` | 仓库根 `dist/` |
| `VERSION` | App 的 `CFBundleShortVersionString`，覆盖值必须相同 |
| `SOURCE_REF` | 当前 HEAD，必须与 App 内 `LaunchGridSourceCommit` 相同 |
| `NOTES_FILE` | `doc/releases/$VERSION.md` |
| `PUBLISH` | 脚本默认 `1`；先验收阶段必须显式设 `0` |

脚本会检查 App、版本、确切源码引用、发行说明、tracked 工作区、GitHub 登录、同名 release、签名 Team 和 hardened runtime。不要仅依赖 tracked diff 检查来判断源码干净；未跟踪源码仍需人工核对。

优先使用已存的公证钥匙串 profile。无 profile 时，脚本支持运行时提供 App Store Connect Key（`P8_PATH`、`KEY_ID`、可选 `ISSUER_ID`），或 Apple ID（`APPLE_ID`、`APPLE_APP_PASSWORD`），并调用 `notarytool store-credentials`。不要把实际凭据粘入文档或 shell 历史。

实际流水线：

1. 用 ditto 制作 App ZIP，提交 `notarytool --wait`。
2. **staple 并 validate App**，通过 `spctl --assess --type execute`。
3. 将已 staple 的 App 与 Applications 入口装进 DMG。
4. 独立提交 DMG 公证，staple 并 validate DMG。
5. 从同一 `SOURCE_REF` 生成源码包，并计算 DMG/源码包 SHA-256。
6. `PUBLISH=0` 到此停止，不创建 GitHub release。

输出为 `dist/LaunchGrid-$VERSION.dmg`、`dist/LaunchGrid-$VERSION-source.tar.gz` 和 `dist/SHA256SUMS.txt`。有同名 release 或 DMG 文件时脚本中止，不覆盖既有产物。App ZIP 是临时提交材料，不作为最终安装资产。

## 4. 验收实际分发内容

检查源码 commit、版本、两种架构与许可证，再只读挂载刚生成的 DMG，检查里面的 App，而不是仅检查构建目录：

```bash
lipo -archs LaunchGrid.app/Contents/MacOS/LaunchGrid
codesign --verify --deep --strict LaunchGrid.app
spctl --assess --type execute --verbose LaunchGrid.app
xcrun stapler validate LaunchGrid.app
```

| 验收项 | 需记录的结果 |
|---|---|
| 包与来源 | DMG/源码 SHA-256、版本、源码 commit、App 内 LICENSE/SOURCE.md 一致 |
| 实际 DMG | 只读挂载、内部 App 的版本/架构、codesign、stapler、Gatekeeper |
| 首次启动 | Applications 安装、菜单栏、全屏/窗口、Esc、五组热键、冲突与录制、登录项 |
| 启动器 | 中文输入法、拼音/首字母/别名、方向键/回车、拖放/文件夹、重启保留、备份/恢复/旧库失败提示 |
| 应用详情 | 正确应用与子进程，CPU/内存/网络可见性，正常退出与权限失败提示 |
| 剪贴板 | 新安装默认关闭、开启后仅记录新文本、暂停/排除/清空、关闭仍可查看历史、直接回贴授权 |
| 网络 | 可见性采样、停用期间不累计、命令失败提示；DNS/诊断仅用受控测试网络 |
| 更新 | 元数据/digest 与签名拒绝路径、只读安装限制、隔离目录的安装；端到端更新需单独记录 |

不要替换用户正在使用的真实安装或采集真实剪贴板来做自动化测试。没有完成的 Intel 实机、辅助功能或端到端更新验证应明确标注，不能以单元测试或模拟数据代替。截图写入 `doc/screenshots/`，只使用可公开内容。

## 5. 发布已验收产物

`PUBLISH=0` 之后不要直接用相同输出目录重跑脚本并期待只上传：脚本会发现已存在 DMG 而中止。保留原产物，确认 PR 已合并、CI 全绿、源码 commit 与包一致，再上传这批文件。以下在仓库根目录执行，`SOURCE_REF` 必须确认为该包内的源码 commit：

```bash
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' LaunchGrid.app/Contents/Info.plist)"
SOURCE_REF="$(/usr/libexec/PlistBuddy -c 'Print :LaunchGridSourceCommit' LaunchGrid.app/Contents/Info.plist)"
gh release create "v$VERSION" "dist/LaunchGrid-$VERSION.dmg" "dist/LaunchGrid-$VERSION-source.tar.gz" "dist/SHA256SUMS.txt" --repo CacinieP/launchgrid --target "$SOURCE_REF" --title "LaunchGrid $VERSION" --notes-file "doc/releases/$VERSION.md"
```

若使用自定义 `OUT_DIR` / `NOTES_FILE`，上传命令也应改成对应的已验收路径。默认 `PUBLISH=1` 的脚本能在全新输出目录完成并直接发布，但不是本项目“先验收同一批文件”的首选流程。不要重新构建替换已经验收过的资产后仍沿用原验证结果。

发布后读取真实 release，确认 tag/target、资产名称、GitHub asset `digest`、下载链接和安装说明。原生更新器要求精确官方资产 URL 与 GitHub SHA-256；未提供合格 digest 时会回退手动安装。检查结束后按仓库纪律删除已合并 feature branch。发现已发布缺陷应通过新 PR/新版本修复，保留既有发行记录。
