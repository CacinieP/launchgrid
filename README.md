# LaunchGrid

macOS 26/27 启动台（Launchpad）移除后的自建替代：按 **F4**（或点菜单栏网格图标）唤出全屏 App 网格，支持搜索、分页、点击启动。按 **⌥F4** 唤出进程管理面板，查看全部进程的 CPU / 内存占用并终止进程。

## 功能

**应用网格（F4）**

- 全屏 Launchpad 风格浮层：7 列图标网格 + 顶部搜索框 + 底部分页圆点
- 数据源：`/Applications`、`/System/Applications`、`/System/Applications/Utilities`、`~/Applications`
- 搜索：大小写/变音符号不敏感的名称过滤
- 分页：每页 35 个（5×7），圆点可点击跳页
- 启动：点击图标经 `NSWorkspace` 打开，并自动收起浮层
- Esc 关闭浮层；菜单栏图标可唤出/刷新/退出
- 全局热键：Carbon `RegisterEventHotKey`（F4），**不需要辅助功能权限**
- 以 accessory（LSUIElement）方式运行，无 Dock 图标

**进程管理（⌥F4）**

- 列出**全部**进程（含 node / python / launchd 等非 GUI 进程），数据来自 `/bin/ps`
- 每行显示：进程名、完整可执行路径、PID、用户、CPU%、常驻内存
- 点表头切换排序（进程名 / PID / CPU / 内存 / 用户），再点一次切换升降序
- 搜索支持进程名、完整路径、PID
- 选中后可**终止**（GUI 应用走 `NSRunningApplication.terminate()` 让它自己保存并退出，其余走 SIGTERM）或**强制终止**（SIGKILL）；右键菜单同样可触发
- 列表每 2 秒自动刷新；只有停留在进程页时才轮询，浮层收起即停
- GUI 应用显示其应用图标，其余进程显示通用齿轮图标

两个模式在同一个浮层内用顶部分段控件切换，切换不重建浮层，状态与滚动位置都保留。

## 构建

依赖：Xcode / Swift 工具链（Swift 6.x），无第三方依赖。

```bash
./scripts/make_app.sh        # swift build -c release + 打 .app bundle + ad-hoc 签名
cp -R LaunchGrid.app /Applications/
open -a LaunchGrid
```

## 公证与发布（发给外部用户）

`make_app.sh` 产出的是 ad-hoc 签名版，只能本机运行；要分发必须 **Developer ID 签名 + Apple 公证**。

**1. 签名**（证书需已在登录钥匙串，见下方「已知坑」）：

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <名字> (<Team ID>)" \
  /Applications/LaunchGrid.app
```

`--options runtime`（hardened runtime）与 `--timestamp`（安全时间戳）是公证硬性要求；本 bundle 为单 Mach-O、无嵌套可执行代码、无沙箱，**不需要** `--deep` 与 entitlements。

**2. 公证 + 发布**（一条命令跑完）：

```bash
# 路线 A：App Store Connect API Key（Team 账号需 ISSUER_ID）
P8_PATH=~/Desktop/AuthKey_XXX.p8 KEY_ID=XXXXXXXXXX [ISSUER_ID=<UUID>] \
  bash scripts/notarize_release.sh

# 路线 B：Apple ID + App 专用密码（appleid.apple.com 生成）
APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx bash scripts/notarize_release.sh
```

脚本自动完成：前置检查（Developer ID 签名 + hardened runtime）→ ditto 打提交包 → 存凭据并验证 → `notarytool submit --wait` → `stapler staple` + validate → **`spctl` Gatekeeper 门禁（不过则中止，不会误发）** → 重打包 → `gh release create`。版本号默认读 app 的 `CFBundleShortVersionString`（可用 `VERSION=` 覆盖）；产物默认落 `~/Desktop`（可用 `OUT_DIR=` 改）。

**已知坑**（均实测踩过）：

| 现象 | 原因与解法 |
|---|---|
| fastlane 建证书卡在 `Could not install WWDR certificate` | fastlane 清单里的 `AppleWWDRCAG5.cer` 等对国内 IP 返 403，`curl -f` 判致命。挂代理下载全部 7 个中间证书并 `security import` 进登录钥匙串，fastlane 即跳过下载 |
| ASC Key 提交报 `HTTP 401 Unauthenticated` | Team 账号的 Key 必须提供 Issuer ID（集成页面顶部 UUID）；Individual 账号才可留空 |
| `store-credentials` 对 Individual Key 也弹 Issuer ID 提问 | 非交互运行需喂空行（脚本已处理） |
| `ditto -c` 产出 cpio 而非 zip | 少了 `-k`；notarytool 只收 PK-Zip |

公证成功后本机自检：

```bash
spctl -a -t exec -v /Applications/LaunchGrid.app
# 期望：accepted source=Notarized Developer ID
```

## 使用

| 操作 | 方式 |
|---|---|
| 唤出/收起网格 | F4，或菜单栏 LaunchGrid 图标 → 显示应用网格 |
| 唤出/收起进程管理 | ⌥F4，或菜单栏 → 显示进程管理 |
| 切换应用 / 进程 | 浮层顶部分段控件 |
| 搜索 | 直接在搜索框输入（应用名 / 进程名 / 路径 / PID） |
| 启动 App | 点击图标 |
| 选择进程 | 点击进程行 |
| 终止进程 | 选中后点「终止」，或右键 → 终止（SIGTERM） |
| 强制终止进程 | 选中后点「强制终止」，或右键 → 强制终止（SIGKILL） |
| 关闭 | Esc |
| 刷新应用列表 | 菜单栏 → 刷新应用列表 |
| 退出 | 菜单栏 → 退出 LaunchGrid |

F4 在 macOS 27 已无系统占用；若按下无反应，检查 系统设置 → 键盘 → 键盘快捷键 里是否残留"启动台"映射并移除。

⌥F4 选它是因为：⌃F2/⌃F3/⌃F4 已被系统占用（菜单栏 / Dock / 下一个窗口），而 F5 虽然空闲但会被浏览器的刷新键抢走——无修饰键的全局热键会吞掉按键。

## 调试

```bash
LAUNCHGRID_SHOW_ON_LAUNCH=apps /Applications/LaunchGrid.app/Contents/MacOS/LaunchGrid
LAUNCHGRID_SHOW_ON_LAUNCH=processes /Applications/LaunchGrid.app/Contents/MacOS/LaunchGrid
```

启动即展示浮层（`apps` / `processes` 指定打开哪个页面）；运行日志写入 `/tmp/launchgrid-debug.log`。

没有录屏权限时（`screencapture` 报 `could not create image from display`），可以让应用自己把浮层渲染成 PNG：

```bash
LAUNCHGRID_SNAPSHOT_PATH=/tmp/lg.png LAUNCHGRID_SHOW_ON_LAUNCH=processes open -a LaunchGrid
```

## 结构

```
Sources/LaunchGrid/
├── main.swift               # NSApplication 入口（accessory 模式）
├── AppDelegate.swift        # 状态栏图标、浮层调度、双热键、菜单
├── AppLibrary.swift         # 应用目录扫描 + 图标缓存 + AppStore
├── GridContentView.swift    # SwiftUI 应用网格/分页
├── RootView.swift           # 浮层根视图：模式切换 + 统一搜索框
├── ProcessMonitor.swift     # ps 取数、进程快照、终止/强制终止
├── ProcessContentView.swift # SwiftUI 进程列表/排序/操作栏
├── OverlayPanel.swift       # 无边框全屏 NSPanel + Esc 监听
├── HotKey.swift             # Carbon 全局热键（支持修饰键 + 多实例 id）
├── DebugLog.swift           # /tmp 调试日志
└── DebugSnapshot.swift      # /tmp 截图（绕开录屏权限）
scripts/make_app.sh          # 构建打包（ad-hoc 签名）
scripts/make_icon.swift      # 生成应用图标（AppKit 绘制 → .iconset → iconutil → .icns）
scripts/notarize_release.sh  # 公证 + GitHub Release 流水线（双认证：ASC Key / Apple ID+App 专用密码）
Resources/Info.plist         # bundle 元数据（LSUIElement=true）
Resources/AppIcon.icns       # 应用图标
```

重新生成图标：

```bash
swiftc -O scripts/make_icon.swift -o /tmp/genicon && /tmp/genicon /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

## 已知限制

- 不含文件夹（Launchpad 的 folder 归组）与自定义排序，v1 仅平铺网格
- `make_app.sh` 产出 ad-hoc 签名版，分发需走上方「公证与发布」流程
- 开机自启需在 系统设置 → 通用 → 登录项 中添加（本机已添加）
- 进程列表走 `/bin/ps`，CPU% 是系统的衰减平均值，不是瞬时采样
- 终止别的用户 / root 的进程会因权限不足失败（会明确提示）
