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

    private var hub: AudioHub?
    private var controller: SessionController?
    private let panel = CaptionPanelController()
    private var stateObservation: AnyCancellable?
    private var hotkey: GlobalHotkey?
    private var hotkeyObservation: AnyCancellable?
    private var granola: GranolaWatcher?
    private var granolaObservation: AnyCancellable?
    private var ownership = AutoSessionOwnership()

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
        granola = GranolaWatcher { [weak self] event in self?.granolaMeeting(event) }
        granolaObservation = settings.$autoCaptionGranola.sink { [weak self] on in
            if on { self?.granola?.start() } else { self?.granola?.stop() }
        }
    }

    func toggle() {
        capturing ? stop() : start()
    }

    /// A Granola meeting starts captions only when none are running, and
    /// ends only captions it started. Its transcript is always saved: that
    /// is the point of auto-captioning a meeting. The panel stays hidden,
    /// since the meeting app shows its own captions.
    private func granolaMeeting(_ event: MeetingDebouncer.Event) {
        switch event {
        case .started:
            if ownership.meetingStarted(capturing: capturing) { start(saveTranscript: true, showPanel: false) }
        case .ended:
            if ownership.meetingEnded() { stop() }
        }
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
        start(saveTranscript: ownership.owned || settings.saveTranscripts, showPanel: true)
    }

    private func start(saveTranscript: Bool, showPanel: Bool) {
        guard !capturing else { return }
        if showPanel { panel.show(model: self) }
        let hub = AudioHub(capture: DualCapture(
            micEnabled: { [weak self] in self?.settings.micOn ?? false },
            systemEnabled: { [weak self] in self?.settings.systemOn ?? false },
            echoCancellation: settings.echoCancellation))
        self.hub = hub
        // A resume after pause() continues the same transcript; see TranscriptRecorder.
        let engine = transcripts.beginCapture(
            wrapping: Self.makeSpeechEngine(), enabled: saveTranscript)
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
        ownership.userStopped()
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
