import Foundation
import SwiftUI
import Carbon.HIToolbox

/// A global hotkey: a key plus its modifiers. Pure value — Carbon appears
/// only as the stored bit values, so GlobalHotkey can pass them through and
/// tests never need an event system.
struct HotkeyBinding: Equatable, Codable {
    /// Virtual key code (kVK_*), independent of keyboard layout.
    var keyCode: UInt32
    /// Carbon modifier mask: any of cmdKey, optionKey, controlKey, shiftKey.
    var modifiers: UInt32
    /// The key as the recorder saw it, for display: "C", "5", "⎋"…
    var keyLabel: String

    static let `default` = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "C")

    /// "⌃⌥⇧⌘C" — modifiers in the order macOS renders them, then the key.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel.uppercased()
    }

    /// The SwiftUI shape of this binding, for showing it beside the menu
    /// item. Nil when the label isn't a single character SwiftUI can render.
    var keyEquivalent: (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard let c = keyLabel.lowercased().first, keyLabel.count == 1 else { return nil }
        var m: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        return (KeyEquivalent(c), m)
    }

    // MARK: - Persistence
    // Absent key: never configured — the default. Empty data: deliberately
    // cleared — no hotkey. JSON: the stored binding.

    private static let key = "hotkeyBinding"

    static func stored(in defaults: UserDefaults = .standard) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(HotkeyBinding.self, from: data)) ?? .default
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func storeDisabled(in defaults: UserDefaults = .standard) {
        defaults.set(Data(), forKey: key)
    }
}
