import Foundation
import ServiceManagement

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

    /// Registered as a login item so the hotkey works after a reboot —
    /// a global hotkey only fires while the app is running.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !revertingLoginItem, oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Reflect reality: the toggle failed, so put it back.
                revertingLoginItem = true
                launchAtLogin = oldValue
                revertingLoginItem = false
            }
        }
    }
    private var revertingLoginItem = false

    init() {
        let storedSize = UserDefaults.standard.double(forKey: "captionFontSize")
        fontSize = storedSize > 0 ? storedSize : Self.defaultFontSize
        hotkey = HotkeyBinding.stored()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
