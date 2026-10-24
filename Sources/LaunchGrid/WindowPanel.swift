import AppKit
import SwiftUI

/// 浮层的两种呈现方式
///
/// - `fullscreen`：无边框全屏面板，盖住 Dock 与菜单栏，行为对齐旧 Launchpad
/// - `window`：标准 macOS 窗口，可拖动可缩放，能和别的应用并排干活
enum LauncherPresentation: String, CaseIterable {
    case fullscreen = "全屏"
    case window = "窗口"

    /// 调试环境变量用的英文标识，避免和界面显示名耦合
    var debugKey: String {
        switch self {
        case .fullscreen: return "fullscreen"
        case .window: return "window"
        }
    }

    init?(debugKey: String) {
        let key = debugKey.lowercased()
        guard let match = LauncherPresentation.allCases.first(where: { $0.debugKey == key }) else { return nil }
        self = match
    }
}

/// 窗口模式：标准 macOS 窗口
///
/// 与全屏浮层共用同一套 RootView，只是承载它的窗口不同：
/// 带标题栏、可拖动、可缩放，位置与大小由 AppKit 自动记进 UserDefaults。
final class WindowPanel: NSWindow {
    /// 收起时的回调，用于停掉进程轮询
    var onHide: (() -> Void)?

    /// 记住窗口位置与大小用的 autosave 名字
    private static let frameAutosaveName = "LaunchGridWindowPanel"

    /// 首次打开时的默认内容尺寸
    private static let defaultContentSize = NSSize(width: 1040, height: 700)

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "LaunchGrid"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 780, height: 480)

        // 直接把 NSHostingView 当 contentView：NSHostingController 会按内容的
        // fitting size 反过来收窗口，窗口模式必须自己说了算
        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        // 位置与大小：优先用上次记住的，没有就按默认尺寸居中
        setFrameAutosaveName(Self.frameAutosaveName)
        if !setFrameUsingName(Self.frameAutosaveName) {
            setContentSize(Self.defaultContentSize)
            center()
        }

        // 跨桌面显示，但不抢其它全屏 app 的位置
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isRestorable = false
    }

    /// 关闭按钮走「收起」而不是销毁，app 留在菜单栏继续待命
    override func close() {
        hide()
    }

    func show() {
        DebugLog.log("window.show frame=\(frame)")
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.log("window shown isVisible=\(isVisible)")
    }

    func hide() {
        orderOut(nil)
        onHide?()
    }

    var isShowing: Bool { isVisible }
}
