import XCTest
import Carbon.HIToolbox
@testable import EmojiBako

final class HotKeyTests: XCTestCase {

    func testDefaultIsCommandPeriod() {
        XCTAssertEqual(HotKey.defaultValue, HotKey(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey)))
        XCTAssertEqual(HotKey.defaultValue.displayString, "⌘.")
    }

    func testDisplayStringOrdersModifiersLikeMenus() {
        let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(hotKey.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringForSpecialKey() {
        XCTAssertEqual(HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).displayString, "⌥Space")
    }

    func testInitFromEventConvertsModifiers() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift, .capsLock], timestamp: 0,
            windowNumber: 0, context: nil, characters: "E", charactersIgnoringModifiers: "e", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_E)
        ))
        // Caps Lockはホットキーの判定に使わない
        XCTAssertEqual(HotKey(event: event), HotKey(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(cmdKey | shiftKey)))
    }

    func testRejectsShiftOnlyAndNoModifier() {
        XCTAssertEqual(HotKeyValidator.validate(HotKey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey))), .missingModifier)
        XCTAssertEqual(HotKeyValidator.validate(HotKey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0)), .missingModifier)
    }

    func testFunctionKeysAboveF12HaveNames() {
        XCTAssertEqual(HotKey(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(cmdKey)).displayString, "⌘F18")
        XCTAssertEqual(HotKey(keyCode: UInt32(kVK_ANSI_KeypadEnter), carbonModifiers: UInt32(cmdKey)).displayString, "⌘⌤")
    }

    /// どのキーを押しても表示でクラッシュせず、表示名のないキーは記録前に拒否される
    func testEveryKeyCodeIsDisplayableOrRejected() {
        for keyCode in UInt32(0)...127 {
            let hotKey = HotKey(keyCode: keyCode, carbonModifiers: UInt32(cmdKey))
            XCTAssertFalse(hotKey.displayString.isEmpty)
            if !hotKey.hasDisplayableKey {
                XCTAssertEqual(HotKeyValidator.validate(hotKey), .unsupportedKey, "keyCode \(keyCode)")
            }
        }
    }

    func testStoreUsesDefaultUntilSavedAndPersists() throws {
        let suiteName = "EmojiBakoTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(HotKeyStore(defaults: defaults).hotKey, .defaultValue)

        let custom = HotKey(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey))
        HotKeyStore(defaults: defaults).save(custom)
        XCTAssertEqual(HotKeyStore(defaults: defaults).hotKey, custom)
    }
}
