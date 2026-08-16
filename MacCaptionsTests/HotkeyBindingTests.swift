import XCTest
import Carbon.HIToolbox
@testable import Captions

final class HotkeyBindingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "HotkeyBindingTests")!
        defaults.removePersistentDomain(forName: "HotkeyBindingTests")
    }

    func testDisplayOrdersModifiersCanonically() {
        // control, option, shift, command — the order macOS renders everywhere
        let b = HotkeyBinding(keyCode: 8, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), keyLabel: "c")
        XCTAssertEqual(b.display, "⌃⌥⇧⌘C")
    }

    func testDefaultIsControlOptionCommandC() {
        XCTAssertEqual(HotkeyBinding.default.display, "⌃⌥⌘C")
    }

    func testRoundTripsThroughDefaults() {
        let b = HotkeyBinding(keyCode: 40, modifiers: UInt32(cmdKey), keyLabel: "K")
        b.store(in: defaults)
        XCTAssertEqual(HotkeyBinding.stored(in: defaults), b)
    }

    func testAbsentMeansDefault() {
        XCTAssertEqual(HotkeyBinding.stored(in: defaults), .default)
    }

    func testClearedMeansNone() {
        HotkeyBinding.storeDisabled(in: defaults)
        XCTAssertNil(HotkeyBinding.stored(in: defaults))
    }
}
