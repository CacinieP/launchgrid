import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: OverlayPanel?
    private var hotKey: HotKey?
    private var apps: [AppItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")
        apps = AppLibrary.apps()
        DebugLog.log("apps=\(apps.count)")
        buildStatusItem()
        DebugLog.log("statusItem built")

        let hotKey = HotKey()
        hotKey.onPress = { [weak self] in
            DispatchQueue.main.async { self?.togglePanel() }
        }
        self.hotKey = hotKey

        let showOnLaunch = ProcessInfo.processInfo.environment["LAUNCHGRID_SHOW_ON_LAUNCH"] == "1"
        DebugLog.log("env LAUNCHGRID_SHOW_ON_LAUNCH=\(showOnLaunch)")
        if showOnLaunch {
            DispatchQueue.main.async {
                DebugLog.log("calling showPanel")
                self.showPanel()
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
                                action: #selector(togglePanel),
                                keyEquivalent: ""))
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

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            panel.hide()
            return
        }
        showPanel()
    }

    private func showPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        DebugLog.log("showPanel screens=\(NSScreen.screens.count) main=\(NSScreen.main != nil)")
        guard let screen else { DebugLog.log("no screen"); return }
        if panel == nil {
            panel = OverlayPanel(rootView: GridContentView(apps: apps) { [weak self] app in
                self?.launch(app)
            })
        }
        panel?.show(on: screen)
    }

    private func launch(_ app: AppItem) {
        panel?.hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, _ in }
    }

    @objc private func reloadApps() {
        apps = AppLibrary.apps()
        panel = nil
        showPanel()
    }
}
