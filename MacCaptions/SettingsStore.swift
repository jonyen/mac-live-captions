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

    /// Save a Markdown transcript of each captioning session. Off by default:
    /// captions are otherwise never kept.
    @Published var saveTranscripts: Bool {
        didSet { UserDefaults.standard.set(saveTranscripts, forKey: "saveTranscripts") }
    }

    /// Apple voice processing on the microphone. Removes speaker echo from
    /// the mic channel but lowers every other app's audio while captioning,
    /// so it is opt-in. Takes effect at the next Start.
    @Published var echoCancellation: Bool {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation") }
    }

    /// Where transcripts are written. Takes effect at the next Start.
    @Published var transcriptsFolder: URL {
        didSet { UserDefaults.standard.set(transcriptsFolder.path, forKey: "transcriptsFolder") }
    }

    init() {
        let storedSize = UserDefaults.standard.double(forKey: "captionFontSize")
        fontSize = storedSize > 0 ? storedSize : Self.defaultFontSize
        hotkey = HotkeyBinding.stored()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        saveTranscripts = UserDefaults.standard.bool(forKey: "saveTranscripts")
        echoCancellation = Self.echoCancellation(
            stored: UserDefaults.standard.object(forKey: "echoCancellation") as? Bool)
        transcriptsFolder = Self.transcriptsFolder(
            stored: UserDefaults.standard.string(forKey: "transcriptsFolder"),
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Off unless the user turned it on.
    static func echoCancellation(stored: Bool?) -> Bool {
        stored ?? false
    }

    /// The stored folder path, or ~/Documents/Captions Transcripts when unset.
    static func transcriptsFolder(stored: String?, home: URL) -> URL {
        if let stored, !stored.isEmpty { return URL(fileURLWithPath: stored, isDirectory: true) }
        return home.appendingPathComponent("Documents/Captions Transcripts", isDirectory: true)
    }
}
