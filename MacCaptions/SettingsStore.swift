import Foundation

/// Overlay preferences, UserDefaults-backed.
final class SettingsStore: ObservableObject {
    static let defaultFontSize: Double = 18

    /// Overlay caption text size in points.
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "captionFontSize") }
    }

    /// The global hotkey; nil disables it. Absent-vs-cleared lives in
    /// HotkeyBinding's persistence, so first launch gets the default.
    @Published var hotkey: HotkeyBinding? {
        didSet {
            if let hotkey { hotkey.store() } else { HotkeyBinding.storeDisabled() }
        }
    }

    init() {
        let storedSize = UserDefaults.standard.double(forKey: "captionFontSize")
        fontSize = storedSize > 0 ? storedSize : Self.defaultFontSize
        hotkey = HotkeyBinding.stored()
    }
}
