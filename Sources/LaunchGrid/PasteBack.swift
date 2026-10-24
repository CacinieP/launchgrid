import AppKit
import ApplicationServices
import Carbon
import Combine

/// 记录浮层弹出前的目标 app，供「直接回贴」使用
///
/// 浮层是 non-activating panel，但它 show() 里会 `NSApp.activate`，所以
/// 必须在这之前抓一次 frontmost，否则拿到的就是 LaunchGrid 自己。
final class PasteContext: ObservableObject {
    @Published private(set) var target: NSRunningApplication?
    @Published private(set) var targetName: String?

    func capture() {
        let app = NSWorkspace.shared.frontmostApplication
        // LaunchGrid 自己（LSUIElement 菜单栏 app）不算目标。
        // 窗口模式下用户可能已经点进窗口里，这时前台就是 LaunchGrid，
        // 应当沿用上一次抓到的目标，而不是把它清空。
        if let app, app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        target = app
        targetName = app?.localizedName
    }

    func clear() {
        target = nil
        targetName = nil
    }
}

/// 直接回贴：写回剪贴板 → 激活目标 app → 发送 ⌘V
///
/// 发送 ⌘V 需要「辅助功能」权限。没权限时降级为「仅复制到剪贴板」，
/// 由用户自己按 ⌘V。
enum PasteBack {
    enum PasteError: LocalizedError {
        case notTrusted
        case noTarget
        case targetGone(String)

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "需要辅助功能权限才能直接回贴"
            case .noTarget:
                return "没有可回贴的目标应用"
            case .targetGone(let name):
                return "目标应用 \(name) 已退出"
            }
        }
    }

    // MARK: - 权限

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统的授权弹窗
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }

    /// 打开「隐私与安全性 → 辅助功能」设置页
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 回贴

    /// 只写剪贴板，不需要任何权限
    @discardableResult
    static func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// 直接回贴到目标 app
    ///
    /// - Parameters:
    ///   - text: 要粘贴的文本
    ///   - target: 回贴目标，浮层弹出前的前台 app
    ///   - onHide: 收起浮层的回调，在发 ⌘V 之前调用
    static func paste(
        _ text: String,
        into target: NSRunningApplication?,
        onHide: @escaping () -> Void
    ) throws {
        guard isTrusted else { throw PasteError.notTrusted }
        guard let target else { throw PasteError.noTarget }
        guard !target.isTerminated else {
            throw PasteError.targetGone(target.localizedName ?? "目标应用")
        }

        copyToPasteboard(text)

        // 先收起浮层，把前台让出去
        onHide()

        target.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

        // 等目标 app 真正成为前台，再发 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            sendCommandV()
        }
    }

    /// 合成一次 ⌘V
    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyCode = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
