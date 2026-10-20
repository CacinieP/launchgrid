# LaunchGrid

macOS 26/27 启动台（Launchpad）移除后的自建替代：按 **F4**（或点菜单栏网格图标）唤出全屏 App 网格，支持搜索、分页、点击启动。

## 功能

- 全屏 Launchpad 风格浮层：7 列图标网格 + 顶部搜索框 + 底部分页圆点
- 数据源：`/Applications`、`/System/Applications`、`/System/Applications/Utilities`、`~/Applications`
- 搜索：大小写/变音符号不敏感的名称过滤
- 分页：每页 35 个（5×7），圆点可点击跳页
- 启动：点击图标经 `NSWorkspace` 打开，并自动收起浮层
- Esc 关闭浮层；菜单栏图标可唤出/刷新/退出
- 全局热键：Carbon `RegisterEventHotKey`（F4），**不需要辅助功能权限**
- 以 accessory（LSUIElement）方式运行，无 Dock 图标

## 构建

依赖：Xcode / Swift 工具链（Swift 6.x），无第三方依赖。

```bash
./scripts/make_app.sh        # swift build -c release + 打 .app bundle + ad-hoc 签名
cp -R LaunchGrid.app /Applications/
open -a LaunchGrid
```

## 使用

| 操作 | 方式 |
|---|---|
| 唤出/收起网格 | F4，或菜单栏 LaunchGrid 图标 → 显示应用网格 |
| 搜索 | 直接在搜索框输入 |
| 启动 App | 点击图标 |
| 关闭 | Esc |
| 刷新应用列表 | 菜单栏 → 刷新应用列表 |
| 退出 | 菜单栏 → 退出 LaunchGrid |

F4 在 macOS 27 已无系统占用；若按下无反应，检查 系统设置 → 键盘 → 键盘快捷键 里是否残留"启动台"映射并移除。

## 调试

```bash
LAUNCHGRID_SHOW_ON_LAUNCH=1 /Applications/LaunchGrid.app/Contents/MacOS/LaunchGrid
```

启动即展示浮层；运行日志写入 `/tmp/launchgrid-debug.log`。

## 结构

```
Sources/LaunchGrid/
├── main.swift               # NSApplication 入口（accessory 模式）
├── AppDelegate.swift        # 状态栏图标、浮层调度、菜单
├── AppLibrary.swift         # 应用目录扫描
├── GridContentView.swift    # SwiftUI 网格/搜索/分页
├── OverlayPanel.swift       # 无边框全屏 NSPanel + Esc 监听
├── HotKey.swift             # Carbon 全局热键
└── DebugLog.swift           # /tmp 调试日志
scripts/make_app.sh          # 构建打包
Resources/Info.plist         # bundle 元数据（LSUIElement=true）
```

## 已知限制

- 不含文件夹（Launchpad 的 folder 归组）与自定义排序，v1 仅平铺网格
- ad-hoc 签名，未公证；更新需重新 `cp -R` 覆盖安装
- 未做开机自启，可在 系统设置 → 通用 → 登录项 中添加
