import Carbon
import Cocoa

/// A Carbon registration owns its event handler for exactly the same lifetime.
final class HotKey {
    static let signature = OSType(0x4C_47_52_47) // 'LGRG'
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let hotKeyID: EventHotKeyID
    private(set) var registrationStatus: OSStatus = noErr
    var onPress: (() -> Void)?

    var isRegistered: Bool { registrationStatus == noErr && hotKeyRef != nil }

    init(keyCode: UInt32 = UInt32(kVK_F4), id: UInt32 = 1, modifiers: UInt32 = 0) {
        hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            guard status == noErr,
                  HotKey.matches(receivedID, expected: hotKey.hotKeyID) else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.onPress?()
            return noErr
        }, 1, &eventType, selfPtr, &eventHandler)
        guard handlerStatus == noErr else {
            registrationStatus = handlerStatus
            return
        }
        registrationStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        if registrationStatus != noErr {
            // A failed registration must not leave a callback with an unretained owner.
            unregister()
            DebugLog.log("RegisterEventHotKey failed keyCode=\(keyCode) id=\(id) status=\(registrationStatus)")
        }
    }

    static func matches(_ received: EventHotKeyID, expected: EventHotKeyID) -> Bool {
        received.signature == expected.signature && received.id == expected.id
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregister() }
}
