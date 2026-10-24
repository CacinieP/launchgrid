import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: OverlayPanel?
    private var appHotKey: HotKey?
    private var processHotKey: HotKey?

    private let appStore = AppStore()
    private let monitor = ProcessMonitor()
    private var mode: LaunchMode = .apps

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")
        appStore.reload()
        DebugLog.log("apps=\(appStore.apps.count)")
        buildStatusItem()
        DebugLog.log("statusItem built")

        // F4 → 应用网格
        let appHotKey = HotKey(keyCode: UInt32(kVK_F4), id: 1, modifiers: 0)
        appHotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle(target: .apps) }
        }
        self.appHotKey = appHotKey

        // ⌥F4 → 进程管理
        let processHotKey = HotKey(keyCode: UInt32(kVK_F4), id: 2, modifiers: UInt32(optionKey))
        processHotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle(target: .processes) }
        }
        self.processHotKey = processHotKey

        // 调试用：LAUNCHGRID_SHOW_ON_LAUNCH=apps|processes 可指定启动时直接展示哪个面板
        let launchMode = ProcessInfo.processInfo.environment["LAUNCHGRID_SHOW_ON_LAUNCH"]
        DebugLog.log("env LAUNCHGRID_SHOW_ON_LAUNCH=\(launchMode ?? "nil")")
        if let launchMode {
            let initial: LaunchMode = (launchMode == "processes") ? .processes : .apps
            DispatchQueue.main.async {
                DebugLog.log("calling showPanel")
                self.showPanel(mode: initial)
                DebugLog.log("showPanel returned")
            }
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2",
                                   accessibilityDescription: "LaunchGrid")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示应用网格 (F4)",
                                action: #selector(toggleAppGrid),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "显示进程管理 (⌥F4)",
                                action: #selector(toggleProcessPanel),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "刷新应用列表",
                                action: #selector(reloadApps),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 LaunchGrid",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Panel

    @objc private func toggleAppGrid() {
        toggle(target: .apps)
    }

    @objc private func toggleProcessPanel() {
        toggle(target: .processes)
    }

    /// 浮层已显示时按同一个热键收起；按另一个热键则原地切换模式
    private func toggle(target: LaunchMode) {
        if let panel, panel.isVisible {
            if mode == target {
                panel.hide()
            } else {
                mode = target
            }
            return
        }
        showPanel(mode: target)
    }

    private func showPanel(mode target: LaunchMode) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        DebugLog.log("showPanel screens=\(NSScreen.screens.count) main=\(NSScreen.main != nil)")
        guard let screen else { DebugLog.log("no screen"); return }

        mode = target

        if panel == nil {
            // 浮层只建一次，之后靠 mode binding 切换内容
            let modeBinding = Binding<LaunchMode>(
                get: { [weak self] in self?.mode ?? .apps },
                set: { [weak self] in self?.mode = $0 }
            )
            panel = OverlayPanel(rootView: RootView(
                appStore: appStore,
                monitor: monitor,
                mode: modeBinding
            ) { [weak self] app in
                self?.launch(app)
            })
            panel?.onHide = { [weak self] in
                self?.monitor.setActive(false)
            }
        }

        panel?.show(on: screen)
        if target == .processes {
            monitor.setActive(true)
        }

        // 调试用：延迟一点等 SwiftUI 布局稳定后再截屏
        if DebugSnapshot.outputPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let view = self?.panel?.contentView else { return }
                DebugSnapshot.capture(view)
            }
        }
    }

    private func launch(_ app: AppItem) {
        panel?.hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, _ in }
    }

    @objc private func reloadApps() {
        appStore.reload()
        DebugLog.log("apps reloaded count=\(appStore.apps.count)")
        // 修复：之前这里顺带 showPanel()，导致点菜单「刷新应用列表」就弹浮层
    }
}
