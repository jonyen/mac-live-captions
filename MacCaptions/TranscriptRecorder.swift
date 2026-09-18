import Foundation
import Combine
import CaptionCore

/// Decides which transcript file a captioning session writes to.
///
/// A "session" runs from Start until Stop. Pausing from the overlay ends the
/// speech session (the recognizer has no idle mode) but not the conversation,
/// so a resume keeps writing to the same file with a "Resumed at" marker.
/// Stop, or turning saving off, closes the transcript; the next Start opens a
/// new file.
@MainActor
final class TranscriptRecorder: ObservableObject {
    /// The most recent write failure in this session, for the UI. Cleared by
    /// a successful write and when the session ends.
    @Published private(set) var lastError: String?

    var fileURL: URL? { log?.fileURL }

    private let makeLog: () -> TranscriptLog
    private var log: TranscriptLog?

    init(makeLog: @escaping () -> TranscriptLog) {
        self.makeLog = makeLog
    }

    /// Call on every Start/resume with the speech engine about to be used.
    /// Returns the engine the session should drive: `inner` itself when
    /// saving is off, otherwise a wrapper that records finished captions.
    func beginCapture(wrapping inner: CaptionEngine, enabled: Bool) -> CaptionEngine {
        guard enabled else {
            endSession()
            return inner
        }
        if let log {
            log.noteResumed()
        } else {
            log = makeLog()
        }
        let sessionLog = log
        return TranscriptLoggingEngine(inner: inner) { [weak self] text, channel in
            // An engine from a closed session can still deliver a last final
            // (close() flushes in-progress speech); it must not write into a
            // transcript that has since ended or been replaced.
            guard let self, let sessionLog, self.log === sessionLog else { return }
            sessionLog.record(text: text, channel: channel)
            self.lastError = sessionLog.lastError.map(Self.describe)
        }
    }

    /// Call on Stop: the next Start writes a new transcript.
    func endSession() {
        log = nil
        lastError = nil
    }

    private static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}
