import Foundation
import AppKit
import Combine
import CaptionCore

@MainActor
final class AppModel: ObservableObject {
    let store = CaptionStore()
    let settings: SettingsStore
    let transcripts: TranscriptRecorder
    @Published private(set) var capturing = false
    @Published var micOn = true
    @Published var systemOn = true

    private var hub: AudioHub?
    private var controller: SessionController?
    private let panel = CaptionPanelController()
    private var stateObservation: AnyCancellable?
    private var hotkey: GlobalHotkey?
    private var hotkeyObservation: AnyCancellable?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        // The folder is read when a transcript starts, so a change in
        // Settings applies from the next Start.
        transcripts = TranscriptRecorder { TranscriptLog(directory: settings.transcriptsFolder) }
        observeStore()
        AppDelegate.onReopen = { [weak self] in self?.showPanel() }
        hotkey = GlobalHotkey { [weak self] in self?.toggle() }
        hotkeyObservation = settings.$hotkey.sink { [weak self] binding in
            if let binding { self?.hotkey?.register(binding) }
            else { self?.hotkey?.unregister() }
        }
    }

    func toggle() {
        capturing ? stop() : start()
    }

    /// Overlay ▶/⏸ control: pause ends the session (a new one starts on
    /// resume — the recognizer has no idle mode), but the panel stays up.
    func pauseResume() {
        capturing ? pause() : start()
    }

    /// Show the overlay without starting capture (Spotlight/Finder reopen).
    func showPanel() {
        panel.show(model: self)
    }

    func start() {
        guard !capturing else { return }
        panel.show(model: self)
        let hub = AudioHub(capture: DualCapture(
            micEnabled: { [weak self] in self?.micOn ?? false },
            systemEnabled: { [weak self] in self?.systemOn ?? false },
            echoCancellation: settings.echoCancellation))
        self.hub = hub
        // A resume after pause() continues the same transcript; see TranscriptRecorder.
        let engine = transcripts.beginCapture(
            wrapping: Self.makeSpeechEngine(), enabled: settings.saveTranscripts)
        let controller = SessionController(
            store: store, relay: engine, audio: hub.makeTap(),
            permission: MacPermissions())
        self.controller = controller
        capturing = true
        Task { await controller.start() }
    }

    func pause() {
        controller?.stop()
        controller = nil
        hub = nil
        capturing = false
    }

    func stop() {
        pause()
        transcripts.endSession()
        panel.hide()
    }

    /// SpeechAnalyzer on macOS 26+, which works with Siri & Dictation off;
    /// SFSpeechRecognizer before that, which requires Dictation.
    static func makeSpeechEngine() -> CaptionEngine {
        if #available(macOS 26, *) {
            return AnalyzerSpeechEngine()
        }
        return AppleSpeechEngine()
    }

    /// Open the transcripts folder in Finder, creating it on first use.
    func revealTranscriptsFolder() {
        let folder = settings.transcriptsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Reflect the store's truth: an errored session counts as ended, but the
    /// panel stays up so the user actually sees why — it's only dismissed by
    /// an explicit stop().
    private func observeStore() {
        stateObservation = store.$state.sink { [weak self] state in
            guard let self, case .error = state else { return }
            self.capturing = false
            self.controller?.stop()
            self.controller = nil
            self.hub = nil
        }
    }
}
