import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var ignoredBundleID = ""
    @State private var ignoredBundleError: String?
    @State private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            general.tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            shortcuts.tabItem { Label("快捷键", systemImage: "keyboard") }.tag("shortcuts")
            privacy.tabItem { Label("模块与隐私", systemImage: "hand.raised") }.tag("privacy")
            about.tabItem { Label("关于", systemImage: "info.circle") }.tag("about")
        }
        .padding(18)
        .frame(width: 620, height: 510)
        .onAppear { preferences.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LaunchGridShowUpdateSettings"))) { _ in
            selectedTab = "general"
        }
    }

    private var general: some View {
        Form {
            Toggle("登录时启动 LaunchGrid", isOn: Binding(
                get: { preferences.loginItemEnabled },
                set: { preferences.setLoginItemEnabled($0) }
            ))
            Text("登录项由 macOS 管理；请从“应用程序”文件夹运行已安装的 LaunchGrid。")
                .font(.caption).foregroundStyle(.secondary)
            if preferences.loginItemNeedsApproval {
                Text("请在系统设置中允许 LaunchGrid 登录项。")
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = preferences.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider().padding(.vertical, 10)
            Text("更新").font(.headline)
            Toggle("自动检查新版本", isOn: $preferences.automaticUpdateChecks)
            Text(updater.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("检查更新") { updater.checkForUpdates() }.disabled(updater.isBusy)
                if let version = updater.availableVersion {
                    Button("下载并安装 \(version)") { updater.downloadAndInstall() }
                        .disabled(updater.isBusy || !updater.canInstall)
                }
                if updater.updateInstalled {
                    Button("重新启动使用新版") { updater.restartToApply() }
                }
                Link("发行说明", destination: AppPreferences.releasesURL)
            }
        }
        .padding(24)
    }

    private var shortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("点击快捷键后按下新组合，Esc 取消。普通按键需搭配 ⌘、⌥ 或 ⌃；功能键可单独使用。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(shortcut: preferences.shortcut(for: action),
                                             onRecord: { preferences.setShortcut($0, for: action) },
                                             onRecordingChanged: { preferences.shortcutRecordingHandler?($0) })
                                .frame(width: 210, height: 28)
                            Button("默认") { preferences.setShortcut(action.defaultShortcut, for: action) }
                        }
                        if let error = preferences.shortcutErrors[action] {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
                Text("若 F4 由系统媒体功能接管，请同时按住 fn，或更换组合。其他应用占用的快捷键无法生效，原设置会被保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var privacy: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("启用剪贴板历史", isOn: $preferences.clipboardEnabled)
                Text("开启后在后台记录新复制的文本，并在本机保留 7 天、最多 200 条。关闭后立即停止读取；已有记录可在剪贴板面板清空。")
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.clipboardUpgradeNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("检测到旧版剪贴板历史，升级后延续原有开启状态。你可以随时关闭；新安装默认关闭。")
                            .font(.callout)
                        Button("知道了") { preferences.acknowledgeClipboardUpgrade() }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("忽略以下应用复制的内容").font(.headline)
                HStack {
                    TextField("应用 Bundle ID，例如 com.apple.Safari", text: $ignoredBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIgnoredApplication)
                    Button("添加", action: addIgnoredApplication)
                }
                if let error = ignoredBundleError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(preferences.ignoredClipboardBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("移除") { preferences.ignoredClipboardBundleIDs.removeAll { $0 == bundleID } }
                    }
                }
                Text("来源按当前前台应用判断；加入忽略名单后，已有记录也会移除。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 3)
                Toggle("启用网络模块", isOn: $preferences.networkEnabled)
                Text("仅在网络面板或应用详情显示时采样。关闭后停止采样与历史记录；已有本地流量历史保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private var about: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("LaunchGrid").font(.title)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                .foregroundStyle(.secondary)
            Text("启动应用，查看运行与联网状态。")
            Link("源代码与问题反馈", destination: AppPreferences.sourceURL)
            Link("AGPL-3.0-only 许可证", destination: AppPreferences.licenseURL)
            Text("本软件按 GNU Affero General Public License v3.0 发布。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addIgnoredApplication() {
        let bundleID = ignoredBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty,
              bundleID.contains("."),
              bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            ignoredBundleError = "请输入应用 Bundle ID，例如 com.apple.Safari。"
            return
        }
        if !preferences.ignoredClipboardBundleIDs.contains(bundleID) {
            preferences.ignoredClipboardBundleIDs.append(bundleID)
        }
        ignoredBundleID = ""
        ignoredBundleError = nil
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut
    let onRecord: (KeyboardShortcut) -> Void
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(ShortcutRecorderButton.beginRecording)
        button.setAccessibilityLabel("录制全局快捷键")
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onRecord = onRecord
        button.onRecordingChanged = onRecordingChanged
        if !button.isRecording { button.title = shortcut.displayText }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.endRecording()
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut = ShortcutAction.apps.defaultShortcut
    var onRecord: ((KeyboardShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var eventMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        if isRecording { endRecording(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = "按下快捷键（Esc 取消）"
        onRecordingChanged?(true)
        resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            self?.endRecording()
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording,
                  event.window === self.window, self.window?.isKeyWindow == true else { return event }
            self.endRecording()
            if event.keyCode != 53 { self.onRecord?(KeyboardShortcut(event: event)) }
            return nil
        }
    }

    func endRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        guard isRecording else { return }
        isRecording = false
        title = shortcut.displayText
        onRecordingChanged?(false)
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }
}
