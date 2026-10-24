import AppKit
import Carbon
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: OverlayPanel?
    private var windowPanel: WindowPanel?
    private var hotKeys: [ShortcutAction: HotKey] = [:]
    private var shortcutMenuItems: [ShortcutAction: NSMenuItem] = [:]
    private var shortcutWarningMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var escMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let preferences = AppPreferences.shared
    private let navigation = LauncherNavigation()
    private var inspectionActive = false

    private let appStore = AppStore()
    private let monitor = ProcessMonitor()
    private let clipboardStore = ClipboardStore()
    private let pasteContext = PasteContext()
    private let networkMonitor = NetworkMonitor()
    private var mode: LaunchMode {
        get { navigation.mode }
        set { navigation.mode = newValue }
    }

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
        installMainMenu()
        DebugLog.log("didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")
        appStore.reload()
        DebugLog.log("apps=\(appStore.apps.count)")
        buildStatusItem()
        DebugLog.log("statusItem built")

        // The store owns the opt-in preference observer; disabled means no pasteboard polling.
        clipboardStore.start()
        preferences.refreshLoginItemStatus()
        configureHotKeys()
        UpdateChecker.shared.checkAutomaticallyIfNeeded()
        preferences.$shortcutErrors
            .sink { [weak self] errors in self?.shortcutWarningMenuItem?.isHidden = errors.isEmpty }
            .store(in: &cancellables)
        preferences.$networkEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySurfaceActivation() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("LaunchGridAppInspectionChanged"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.inspectionActive = notification.userInfo?["active"] as? Bool ?? false
                self?.applySurfaceActivation()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.preferences.refreshLoginItemStatus() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("LaunchGridShowSettings"))
            .sink { [weak self] _ in self?.showSettings() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("LaunchGridCheckForUpdates"))
            .sink { [weak self] _ in self?.checkForUpdates() }
            .store(in: &cancellables)

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
        monitor.setActive(false)
        networkMonitor.setActive(false)
        removeEscMonitor()
        hotKeys.values.forEach { $0.unregister() }
        hotKeys.removeAll()
        preferences.shortcutRegistrationHandler = nil
        preferences.shortcutRecordingHandler = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isSurfaceVisible { showSurface(mode: lastMode, presentation: presentation) }
        return false
    }

    // MARK: - Status item

    /// AppKit dispatches standard editing shortcuts through these first-responder actions,
    /// including when SwiftUI text fields live inside an accessory application's panels.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(title: "LaunchGrid", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "LaunchGrid")
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "退出 LaunchGrid",
                                           action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        let undo = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(undo)
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        // nil targets let each focused text editor, sheet, or control handle its own command.
        editMenu.items.forEach { $0.target = nil }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2",
                                   accessibilityDescription: "LaunchGrid")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        addShortcutMenuItem(.apps, action: #selector(toggleAppGrid), to: menu)
        addShortcutMenuItem(.processes, action: #selector(toggleProcessPanel), to: menu)
        addShortcutMenuItem(.clipboard, action: #selector(toggleClipboardPanel), to: menu)
        addShortcutMenuItem(.network, action: #selector(toggleNetworkPanel), to: menu)
        menu.addItem(.separator())
        addShortcutMenuItem(.window, action: #selector(showWindowMode), to: menu)
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
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: ""))
        let shortcutWarning = NSMenuItem(title: "快捷键冲突，打开设置…", action: #selector(showSettings), keyEquivalent: "")
        shortcutWarning.isHidden = preferences.shortcutErrors.isEmpty
        shortcutWarningMenuItem = shortcutWarning
        menu.addItem(shortcutWarning)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 LaunchGrid",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addShortcutMenuItem(_ shortcutAction: ShortcutAction, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        shortcutMenuItems[shortcutAction] = item
        menu.addItem(item)
        updateShortcutMenuTitles()
    }

    private func updateShortcutMenuTitles() {
        for action in ShortcutAction.allCases {
            shortcutMenuItems[action]?.title = "\(action == .window ? "" : "显示")\(action.title) (\(preferences.shortcut(for: action).displayText))"
        }
    }

    private func configureHotKeys() {
        for action in ShortcutAction.allCases {
            let hotKey = makeHotKey(for: action, shortcut: preferences.shortcut(for: action))
            hotKeys[action] = hotKey
            preferences.setShortcutError(hotKey.isRegistered ? nil : registrationError(hotKey.registrationStatus), for: action)
        }
        preferences.shortcutRegistrationHandler = { [weak self] action, shortcut in
            guard let self else { return "应用正在退出，请稍后重试。" }
            let previous = self.preferences.shortcut(for: action)
            self.hotKeys[action]?.unregister()
            let replacement = self.makeHotKey(for: action, shortcut: shortcut)
            guard replacement.isRegistered else {
                // The old combination stays saved and is restored before returning the error.
                let restored = self.makeHotKey(for: action, shortcut: previous)
                self.hotKeys[action] = restored
                let restoreMessage = restored.isRegistered ? "原快捷键已保留。" : "原快捷键也无法注册，请重新选择。"
                return self.registrationError(replacement.registrationStatus) + restoreMessage
            }
            self.hotKeys[action] = replacement
            // Preferences saves immediately after this handler succeeds.
            DispatchQueue.main.async { [weak self] in self?.updateShortcutMenuTitles() }
            return nil
        }
        preferences.shortcutRecordingHandler = { [weak self] recording in
            guard let self else { return }
            if recording { self.hotKeys.values.forEach { $0.unregister() } }
            else { self.configureHotKeys() }
        }
    }

    private func makeHotKey(for action: ShortcutAction, shortcut: KeyboardShortcut) -> HotKey {
        let hotKey = HotKey(keyCode: shortcut.keyCode, id: action.carbonID, modifiers: shortcut.modifiers)
        hotKey.onPress = { [weak self] in
            DispatchQueue.main.async {
                switch action {
                case .apps: self?.toggle(target: .apps)
                case .processes: self?.toggle(target: .processes)
                case .clipboard: self?.toggle(target: .clipboard)
                case .network: self?.toggle(target: .network)
                case .window: self?.showWindowMode()
                }
            }
        }
        return hotKey
    }

    private func registrationError(_ status: OSStatus) -> String {
        "快捷键可能已被系统或其他应用占用（错误 \(status)），请选择其他组合。"
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "LaunchGrid 设置"
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        preferences.refreshLoginItemStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkForUpdates() {
        showSettings()
        NotificationCenter.default.post(name: Notification.Name("LaunchGridShowUpdateSettings"), object: nil)
        UpdateChecker.shared.checkForUpdates()
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
        monitor.setActive(isSurfaceVisible && (mode == .processes || inspectionActive))
        networkMonitor.setActive(isSurfaceVisible && preferences.networkEnabled && (mode == .network || inspectionActive))
    }

    private func resetInspection() {
        inspectionActive = false
        navigation.inspectionRevision &+= 1
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
        resetInspection()
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
                self?.resetInspection()
                self?.applySurfaceActivation()
            }
        }
        panel?.show(on: screen)
        applySurfaceActivation()
        installEscMonitor()
        scheduleSnapshot()
    }

    private func showWindow() {
        resetInspection()
        let wasVisible = windowPanel?.isShowing ?? false
        panel?.hide()

        if !wasVisible {
            pasteContext.capture()
        }

        if windowPanel == nil {
            windowPanel = WindowPanel(rootView: makeRootView())
            windowPanel?.onHide = { [weak self] in
                self?.resetInspection()
                self?.applySurfaceActivation()
            }
        }
        windowPanel?.show()
        applySurfaceActivation()
        installEscMonitor()
        scheduleSnapshot()
    }

    private func hideCurrentSurface() {
        resetInspection()
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
                self?.applySurfaceActivation()
            }
        )
        return RootView(
            appStore: appStore,
            monitor: monitor,
            clipboardStore: clipboardStore,
            pasteContext: pasteContext,
            networkMonitor: networkMonitor,
            navigation: navigation,
            mode: modeBinding,
            onLaunch: { [weak self] app in
                self?.launch(app)
            },
            onHidePanel: { [weak self] in
                self?.resetInspection()
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
            guard event.keyCode == 53, let self else { return event } // Esc
            guard let keyWindow = NSApplication.shared.keyWindow,
                  keyWindow === self.panel || keyWindow === self.windowPanel,
                  keyWindow.attachedSheet == nil else { return event }
            if let editor = keyWindow.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            self.hideCurrentSurface()
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
        resetInspection()
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
