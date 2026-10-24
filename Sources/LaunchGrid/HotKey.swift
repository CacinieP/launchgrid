import Carbon
import Cocoa

/// Carbon 全局热键
///
/// F4 单独按（Launchpad 移除后该键已空出，无需辅助功能权限）唤出应用网格；
/// ⌥F4 唤出进程管理。注册失败（键被别的应用占用）会记进 DebugLog。
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyID: EventHotKeyID
    var onPress: (() -> Void)?

    /// - Parameters:
    ///   - keyCode: 虚拟键码，如 `kVK_F4`
    ///   - id: 同一进程内必须唯一，否则后注册的会被 Carbon 拒掉
    ///   - modifiers: Carbon 修饰键，如 `optionKey`
    init(keyCode: UInt32 = UInt32(kVK_F4), id: UInt32 = 1, modifiers: UInt32 = 0) {
        hotKeyID = EventHotKeyID(signature: OSType(0x4C_47_52_47), id: id) // 'LGRG'

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.onPress?()
            return noErr
        }, 1, &eventType, selfPtr, nil)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            DebugLog.log("RegisterEventHotKey failed keyCode=\(keyCode) id=\(id) status=\(status)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
