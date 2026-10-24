import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: OverlayPanel?
    private var windowPanel: WindowPanel?
    private var appHotKey: HotKey?
    private var processHotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private var networkHotKey: HotKey?
    private var windowHotKey: HotKey?
    private var escMonitor: Any?

    private let appStore = AppStore()
    private let monitor = ProcessMonitor()
    private let clipboardStore = ClipboardStore()
    private let pasteContext = PasteContext()
    private let networkMonitor = NetworkMonitor()
    private var mode: LaunchMode = .apps

    /// 默认呈现方式，记住用户的选择（UserDefaults）
    private var presentation: LauncherPresentation {
        get {
            let raw = UserDefaults.standard.string(forKey: "launchgrid.presentation") ?? ""
            return LauncherPresentation(rawValue: raw) ?? .fullscreen
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "launchgrid.presentation")
            updatePresentationMenuState()
        }
    }

    /// 上次看的面板，⌘F4 开窗口时沿用
    private var lastMode: LaunchMode = .apps

    /// 菜单里的「默认显示方式」两项，切换时更新选中态
    private var fullscreenMenuItem: NSMenuItem?
    private var windowMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")
        appStore.reload()
        DebugLog.log("apps=\(appStore.apps.count)")
        buildStatusItem()
        DebugLog.log("statusItem built")

        // 剪贴板历史要跨浮层收起继续积累，所以常驻监听
        clipboardStore.start()
        DebugLog.log("clipboardStore started entries=\(clipboardStore.entries.count)")
        DebugLog.log("accessibility trusted=\(PasteBack.isTrusted)")

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

        // ⇧F4 → 剪贴板历史
        let clipboardHotKey = HotKey(keyCode: UInt32(kVK_F4), id: 3, modifiers: UInt32(shiftKey))
        clipboardHotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle(target: .clipboard) }
        }
        self.clipboardHotKey = clipboardHotKey

        // ⇧⌥F4 → 网络监控
        let networkHotKey = HotKey(keyCode: UInt32(kVK_F4), id: 4, modifiers: UInt32(shiftKey | optionKey))
        networkHotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle(target: .network) }
        }
        self.networkHotKey = networkHotKey

        // ⌘F4 → 直接开窗口模式（沿用上次看的面板）
        let windowHotKey = HotKey(keyCode: UInt32(kVK_F4), id: 5, modifiers: UInt32(cmdKey))
        windowHotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.showWindowMode() }
        }
        self.windowHotKey = windowHotKey

        // 调试用：LAUNCHGRID_SHOW_ON_LAUNCH=apps|processes|clipboard|network 可指定启动时直接展示哪个面板
        let launchMode = ProcessInfo.processInfo.environment["LAUNCHGRID_SHOW_ON_LAUNCH"]
        DebugLog.log("env LAUNCHGRID_SHOW_ON_LAUNCH=\(launchMode ?? "nil")")
        if let launchMode {
            let initial: LaunchMode
            switch launchMode {
            case "processes": initial = .processes
            case "clipboard": initial = .clipboard
            case "network": initial = .network
            default: initial = .apps
            }
            // 调试用：LAUNCHGRID_PRESENTATION=fullscreen|window 可指定启动时的呈现方式
            let launchPresentation: LauncherPresentation
            if let raw = ProcessInfo.processInfo.environment["LAUNCHGRID_PRESENTATION"],
               let parsed = LauncherPresentation(debugKey: raw) {
                launchPresentation = parsed
            } else {
                launchPresentation = presentation
            }
            DispatchQueue.main.async {
                DebugLog.log("calling showSurface")
                self.showSurface(mode: initial, presentation: launchPresentation)
                DebugLog.log("showSurface returned")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardStore.stop()
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
        menu.addItem(NSMenuItem(title: "显示剪贴板历史 (⇧F4)",
                                action: #selector(toggleClipboardPanel),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "显示网络监控 (⇧⌥F4)",
                                action: #selector(toggleNetworkPanel),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "窗口模式 (⌘F4)",
                                action: #selector(showWindowMode),
                                keyEquivalent: ""))
        menu.addItem(.separator())

        // 默认显示方式：全屏 / 窗口，决定四个面板热键按哪种形态呼出
        let presentationMenu = NSMenu(title: "默认显示方式")
        let fullscreen = NSMenuItem(title: "全屏", action: #selector(setFullscreenPresentation), keyEquivalent: "")
        let window = NSMenuItem(title: "窗口", action: #selector(setWindowPresentation), keyEquivalent: "")
        presentationMenu.addItem(fullscreen)
        presentationMenu.addItem(window)
        fullscreenMenuItem = fullscreen
        windowMenuItem = window
        let presentationItem = NSMenuItem(title: "默认显示方式", action: nil, keyEquivalent: "")
        presentationItem.submenu = presentationMenu
        menu.addItem(presentationItem)
        updatePresentationMenuState()

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

    private func updatePresentationMenuState() {
        fullscreenMenuItem?.state = presentation == .fullscreen ? .on : .off
        windowMenuItem?.state = presentation == .window ? .on : .off
    }

    @objc private func setFullscreenPresentation() {
        presentation = .fullscreen
        DebugLog.log("presentation -> 全屏")
    }

    @objc private func setWindowPresentation() {
        presentation = .window
        DebugLog.log("presentation -> 窗口")
    }

    // MARK: - Panel

    @objc private func toggleAppGrid() {
        toggle(target: .apps)
    }

    @objc private func toggleProcessPanel() {
        toggle(target: .processes)
    }

    @objc private func toggleClipboardPanel() {
        toggle(target: .clipboard)
    }

    @objc private func toggleNetworkPanel() {
        toggle(target: .network)
    }

    /// ⌘F4：直接开窗口模式，沿用上次看的面板
    @objc private func showWindowMode() {
        showSurface(mode: lastMode, presentation: .window)
    }

    /// 浮层已显示时按同一个热键收起；按另一个热键则原地切换模式
    private func toggle(target: LaunchMode) {
        lastMode = target
        if isSurfaceVisible {
            if mode == target {
                hideCurrentSurface()
            } else {
                mode = target
                applySurfaceActivation()
            }
            return
        }
        showSurface(mode: target, presentation: presentation)
    }

    private var isSurfaceVisible: Bool {
        (panel?.isVisible ?? false) || (windowPanel?.isShowing ?? false)
    }

    /// 按当前模式把两个面板的可见性同步过来（进程页/网络页要开始轮询）
    private func applySurfaceActivation() {
        monitor.setActive(mode == .processes)
        networkMonitor.setActive(mode == .network)
    }

    private func showSurface(mode target: LaunchMode, presentation pres: LauncherPresentation) {
        mode = target
        lastMode = target
        switch pres {
        case .fullscreen:
            showFullscreen()
        case .window:
            showWindow()
        }
    }

    private func showFullscreen() {
        let wasVisible = panel?.isVisible ?? false
        // 两种形态互斥：开一种先关另一种
        windowPanel?.hide()

        let screen = NSScreen.main ?? NSScreen.screens.first
        DebugLog.log("showPanel screens=\(NSScreen.screens.count) main=\(NSScreen.main != nil)")
        guard let screen else { DebugLog.log("no screen"); return }

        // 浮层还没显示时才有真正的「前台 app」可抓，已经显示着就沿用旧目标
        if !wasVisible {
            pasteContext.capture()
        }

        if panel == nil {
            panel = OverlayPanel(rootView: makeRootView())
            panel?.onHide = { [weak self] in
                self?.applySurfaceActivation()
            }
        }
        panel?.show(on: screen)
        applySurfaceActivation()
        installEscMonitor()
        scheduleSnapshot()
    }

    private func showWindow() {
        let wasVisible = windowPanel?.isShowing ?? false
        panel?.hide()

        if !wasVisible {
            pasteContext.capture()
        }

        if windowPanel == nil {
            windowPanel = WindowPanel(rootView: makeRootView())
            windowPanel?.onHide = { [weak self] in
                self?.applySurfaceActivation()
            }
        }
        windowPanel?.show()
        applySurfaceActivation()
        installEscMonitor()
        scheduleSnapshot()
    }

    private func hideCurrentSurface() {
        if panel?.isVisible == true {
            panel?.hide()
        } else if windowPanel?.isShowing == true {
            windowPanel?.hide()
        }
        removeEscMonitor()
    }

    /// 两个形态共用同一份 RootView，靠 mode binding 同步内容
    private func makeRootView() -> some View {
        let modeBinding = Binding<LaunchMode>(
            get: { [weak self] in self?.mode ?? .apps },
            set: { [weak self] in
                DebugLog.log("mode binding set -> \($0.rawValue)")
                self?.mode = $0
                self?.lastMode = $0
            }
        )
        return RootView(
            appStore: appStore,
            monitor: monitor,
            clipboardStore: clipboardStore,
            pasteContext: pasteContext,
            networkMonitor: networkMonitor,
            mode: modeBinding,
            onLaunch: { [weak self] app in
                self?.launch(app)
            },
            onHidePanel: { [weak self] in
                self?.panel?.hide()
                self?.windowPanel?.hide()
            }
        )
    }

    // MARK: - 调试截图

    /// 延迟一点等 SwiftUI 布局稳定后再截屏，两种形态都能截
    private func scheduleSnapshot() {
        guard DebugSnapshot.outputPath != nil else { return }
        let delay = Double(ProcessInfo.processInfo.environment["LAUNCHGRID_SNAPSHOT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let isWindow = self.windowPanel?.isShowing == true
            let view = isWindow ? self.windowPanel?.contentView : self.panel?.contentView
            guard let view else { return }
            DebugLog.log("snapshot mode=\(self.mode.rawValue) window=\(isWindow)")
            DebugSnapshot.capture(view)
        }
    }

    // MARK: - Esc

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.hideCurrentSurface()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    private func launch(_ app: AppItem) {
        panel?.hide()
        windowPanel?.hide()
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
