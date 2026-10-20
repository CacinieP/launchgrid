import Carbon
import Cocoa

/// Carbon 全局热键：默认 F4（Launchpad 移除后该键已空出，无需辅助功能权限）
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4C_47_52_47), id: 1) // 'LGRG'
    var onPress: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_F4)) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.onPress?()
            return noErr
        }, 1, &eventType, selfPtr, nil)

        RegisterEventHotKey(keyCode, 0, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
