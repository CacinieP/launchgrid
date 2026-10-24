import AppKit
import Carbon
import Combine
import Foundation
import ServiceManagement

final class LauncherNavigation: ObservableObject {
    @Published var mode: LaunchMode = .apps
    @Published var inspectionRevision = 0
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case apps, processes, clipboard, network, window

    var id: String { rawValue }
    var carbonID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    var title: String {
        switch self {
        case .apps: return "应用网格"
        case .processes: return "进程管理"
        case .clipboard: return "剪贴板历史"
        case .network: return "网络监控"
        case .window: return "窗口模式"
        }
    }
    var defaultShortcut: KeyboardShortcut {
        let modifiers: UInt32
        switch self {
        case .apps: modifiers = 0
        case .processes: modifiers = UInt32(optionKey)
        case .clipboard: modifiers = UInt32(shiftKey)
        case .network: modifiers = UInt32(shiftKey | optionKey)
        case .window: modifiers = UInt32(cmdKey)
        }
        return KeyboardShortcut(keyCode: UInt32(kVK_F4), modifiers: modifiers)
    }
}

struct KeyboardShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let supportedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let functionKeyNames: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "空格", 50: "`",
        51: "⌫", 53: "Esc", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘",
        121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        modifiers = carbon
    }

    var validationError: String? {
        guard keyCode <= 127, modifiers & ~Self.supportedModifiers == 0 else {
            return "此按键组合不受支持，请重新录制。"
        }
        guard Self.functionKeyNames[keyCode] != nil || Self.keyNames[keyCode] != nil else {
            return "请选择一个功能键，或带 ⌘、⌥、⌃ 的按键组合。"
        }
        if Self.functionKeyNames[keyCode] == nil,
           modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 {
            return "普通按键需要搭配 ⌘、⌥ 或 ⌃，避免影响日常输入。"
        }
        return nil
    }

    var displayText: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.functionKeyNames[keyCode] ?? Self.keyNames[keyCode] ?? "键 \(keyCode)")
    }
}

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences(defaults: .standard,
                                       existingClipboardHistory: clipboardHistoryExists)
    static let releasesURL = URL(string: "https://github.com/CacinieP/launchgrid/releases/latest")!
    static let sourceURL = URL(string: "https://github.com/CacinieP/launchgrid")!
    static let licenseURL = URL(string: "https://github.com/CacinieP/launchgrid/blob/main/LICENSE")!

    private let defaults: UserDefaults
    @Published var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: "launchgrid.clipboardEnabled") }
    }
    @Published var networkEnabled: Bool {
        didSet { defaults.set(networkEnabled, forKey: "launchgrid.networkEnabled") }
    }
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: "launchgrid.automaticUpdateChecks") }
    }
    @Published var ignoredClipboardBundleIDs: [String] {
        didSet { defaults.set(ignoredClipboardBundleIDs, forKey: "launchgrid.ignoredClipboardBundleIDs") }
    }
    @Published private(set) var shortcuts: [ShortcutAction: KeyboardShortcut]
    @Published private(set) var shortcutErrors: [ShortcutAction: String] = [:]
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemError: String?
    /// Keep the upgrade behavior visible until the user acknowledges it.
    @Published private(set) var clipboardUpgradeNotice: Bool

    /// Installed by AppDelegate. Returning an error keeps both the old setting and registration.
    var shortcutRegistrationHandler: ((ShortcutAction, KeyboardShortcut) -> String?)?
    /// Recording temporarily releases app-owned shortcuts so F4 and existing bindings can be captured.
    var shortcutRecordingHandler: ((Bool) -> Void)?

    init(defaults: UserDefaults, existingClipboardHistory: Bool = false) {
        self.defaults = defaults
        let existingChoice = defaults.object(forKey: "launchgrid.clipboardEnabled") as? Bool
        clipboardEnabled = existingChoice ?? existingClipboardHistory
        networkEnabled = defaults.object(forKey: "launchgrid.networkEnabled") as? Bool ?? true
        automaticUpdateChecks = defaults.object(forKey: "launchgrid.automaticUpdateChecks") as? Bool ?? true
        ignoredClipboardBundleIDs = defaults.stringArray(forKey: "launchgrid.ignoredClipboardBundleIDs") ?? []
        clipboardUpgradeNotice = defaults.bool(forKey: "launchgrid.clipboardUpgradeNotice")
            || (existingChoice == nil && existingClipboardHistory)
        shortcuts = Self.loadShortcuts(defaults.data(forKey: "launchgrid.shortcuts"))
        // Persist the migration once: deleting old history must not change a later launch's choice.
        defaults.set(clipboardEnabled, forKey: "launchgrid.clipboardEnabled")
        defaults.set(clipboardUpgradeNotice, forKey: "launchgrid.clipboardUpgradeNotice")
    }

    func shortcut(for action: ShortcutAction) -> KeyboardShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) -> Bool {
        if let error = shortcut.validationError {
            shortcutErrors[action] = error
            return false
        }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            shortcutErrors[action] = "与「\(conflict.title)」的快捷键重复，原快捷键已保留。"
            return false
        }
        if let error = shortcutRegistrationHandler?(action, shortcut) {
            shortcutErrors[action] = error
            return false
        }
        shortcuts[action] = shortcut
        shortcutErrors.removeValue(forKey: action)
        let payload = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(payload) { defaults.set(data, forKey: "launchgrid.shortcuts") }
        return true
    }

    func setShortcutError(_ message: String?, for action: ShortcutAction) {
        shortcutErrors[action] = message
    }

    func acknowledgeClipboardUpgrade() {
        clipboardUpgradeNotice = false
        defaults.set(false, forKey: "launchgrid.clipboardUpgradeNotice")
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "登录项设置失败：\(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }

    private static func loadShortcuts(_ data: Data?) -> [ShortcutAction: KeyboardShortcut] {
        let standard = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        guard let data,
              let payload = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data) else { return standard }
        var loaded = standard
        for action in ShortcutAction.allCases {
            if let shortcut = payload[action.rawValue] { loaded[action] = shortcut }
        }
        let values = Array(loaded.values)
        // Corrupt or conflicting persisted input cannot silently disable another action.
        guard values.allSatisfy({ $0.validationError == nil }), Set(values).count == ShortcutAction.allCases.count else {
            return standard
        }
        return loaded
    }

    private static var clipboardHistoryExists: Bool {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("LaunchGrid/clipboard.json").path)
    }
}
