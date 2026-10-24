import Carbon
import XCTest
@testable import LaunchGrid

final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchGridTests.Settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallRequiresClipboardOptInAndPersistsChoice() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.clipboardEnabled)
        XCTAssertTrue(preferences.networkEnabled)
        XCTAssertTrue(preferences.automaticUpdateChecks)
        // An empty history file created later must not be mistaken for a legacy installation.
        XCTAssertFalse(AppPreferences(defaults: defaults, existingClipboardHistory: true).clipboardEnabled)
        preferences.clipboardEnabled = true
        preferences.networkEnabled = false
        preferences.automaticUpdateChecks = false
        preferences.ignoredClipboardBundleIDs = ["com.example.Sensitive"]
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.clipboardEnabled)
        XCTAssertFalse(reloaded.networkEnabled)
        XCTAssertFalse(reloaded.automaticUpdateChecks)
        XCTAssertEqual(reloaded.ignoredClipboardBundleIDs, ["com.example.Sensitive"])
    }

    func testLegacyClipboardMigrationPreservesCaptureAndExplainsIt() {
        let preferences = AppPreferences(defaults: defaults, existingClipboardHistory: true)
        XCTAssertTrue(preferences.clipboardEnabled)
        XCTAssertTrue(preferences.clipboardUpgradeNotice)
        preferences.acknowledgeClipboardUpgrade()
        XCTAssertFalse(AppPreferences(defaults: defaults).clipboardUpgradeNotice)
        preferences.clipboardEnabled = false
        XCTAssertFalse(AppPreferences(defaults: defaults, existingClipboardHistory: true).clipboardEnabled)
    }

    func testShortcutDuplicateIsRejectedBeforeChangingSystemRegistration() {
        let preferences = AppPreferences(defaults: defaults)
        var registrations = 0
        preferences.shortcutRegistrationHandler = { _, _ in registrations += 1; return nil }
        XCTAssertFalse(preferences.setShortcut(preferences.shortcut(for: .processes), for: .apps))
        XCTAssertEqual(registrations, 0)
        XCTAssertEqual(preferences.shortcut(for: .apps), ShortcutAction.apps.defaultShortcut)
        XCTAssertTrue(preferences.shortcutErrors[.apps]?.contains("进程管理") == true)
    }

    func testSystemConflictKeepsPreviouslySavedShortcut() {
        let preferences = AppPreferences(defaults: defaults)
        let first = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | optionKey))
        let second = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey))
        XCTAssertTrue(preferences.setShortcut(first, for: .apps))
        preferences.shortcutRegistrationHandler = { _, _ in "已被其他应用占用" }
        XCTAssertFalse(preferences.setShortcut(second, for: .apps))
        XCTAssertEqual(preferences.shortcut(for: .apps), first)
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut(for: .apps), first)
        XCTAssertEqual(preferences.shortcutErrors[.apps], "已被其他应用占用")
        preferences.shortcutRegistrationHandler = { _, _ in nil }
        XCTAssertTrue(preferences.setShortcut(second, for: .apps))
        XCTAssertNil(preferences.shortcutErrors[.apps])
    }

    func testUnsupportedShortcutDoesNotStealTypingKeys() {
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: 0).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: UInt32(shiftKey)).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 56, modifiers: UInt32(cmdKey)).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 128, modifiers: UInt32(cmdKey)).validationError)
        XCTAssertNil(KeyboardShortcut(keyCode: UInt32(kVK_F4), modifiers: 0).validationError)
        XCTAssertNil(KeyboardShortcut(keyCode: 0, modifiers: UInt32(controlKey)).validationError)
    }

    func testMalformedAndDuplicatePersistedShortcutsRestoreSafeDefaults() throws {
        defaults.set(Data("invalid".utf8), forKey: "launchgrid.shortcuts")
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcut(for: .apps), ShortcutAction.apps.defaultShortcut)
        let duplicate = ["apps": ShortcutAction.processes.defaultShortcut]
        defaults.set(try JSONEncoder().encode(duplicate), forKey: "launchgrid.shortcuts")
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(Set(ShortcutAction.allCases.map { restored.shortcut(for: $0) }).count, 5)
        XCTAssertEqual(restored.shortcut(for: .apps), ShortcutAction.apps.defaultShortcut)
    }

    func testCarbonDispatchMatchesBothApplicationSignatureAndActionID() {
        let expected = EventHotKeyID(signature: HotKey.signature, id: 1)
        XCTAssertTrue(HotKey.matches(expected, expected: expected))
        XCTAssertFalse(HotKey.matches(EventHotKeyID(signature: HotKey.signature, id: 2), expected: expected))
        XCTAssertFalse(HotKey.matches(EventHotKeyID(signature: 0, id: 1), expected: expected))
    }

    func testCarbonRegistrationReleasesShortcutForReplacement() throws {
        // Use an uncommon combination, leaving the user's normal F4 bindings untouched.
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let first = HotKey(keyCode: UInt32(kVK_F20), id: 9_101, modifiers: modifiers)
        guard first.isRegistered else {
            throw XCTSkip("WindowServer unavailable or test combination is in use: \(first.registrationStatus)")
        }
        var firstPresses = 0
        first.onPress = { firstPresses += 1 }
        try sendHotKeyEvent(id: 9_101)
        XCTAssertEqual(firstPresses, 1)
        try sendHotKeyEvent(id: 9_102)
        XCTAssertEqual(firstPresses, 1, "A handler must ignore another action's Carbon ID")
        first.unregister()
        XCTAssertFalse(first.isRegistered)
        let replacement = HotKey(keyCode: UInt32(kVK_F20), id: 9_102, modifiers: modifiers)
        XCTAssertTrue(replacement.isRegistered, "Released Carbon combination must be reusable")
        var replacementPresses = 0
        replacement.onPress = { replacementPresses += 1 }
        try sendHotKeyEvent(id: 9_102)
        XCTAssertEqual(replacementPresses, 1)
        XCTAssertEqual(firstPresses, 1, "Unregister must remove the old callback, not just the binding")
        replacement.unregister()
    }

    private func sendHotKeyEvent(id: UInt32) throws {
        var event: EventRef?
        let status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                 GetCurrentEventTime(), EventAttributes(0), &event)
        XCTAssertEqual(status, noErr)
        guard let event else { return XCTFail("Could not create Carbon event") }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: HotKey.signature, id: id)
        XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &hotKeyID), noErr)
        _ = SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}
