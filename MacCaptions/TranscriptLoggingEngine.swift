import Foundation
import CaptionCore

/// Wraps a `CaptionEngine` and reports every finished, non-empty caption to
/// `onFinal` before passing all events through unchanged. Decorating the
/// engine keeps transcript logging out of `SessionController` (which lives in
/// the shared caption-core package) and out of the speech engine itself.
final class TranscriptLoggingEngine: CaptionEngine {
    var onEvent: (@MainActor (CaptionEvent) -> Void)?
    var onClose: (@MainActor () -> Void)? {
        get { inner.onClose }
        set { inner.onClose = newValue }
    }

    private let inner: CaptionEngine

    init(inner: CaptionEngine, onFinal: @escaping @MainActor (String, Int?) -> Void) {
        self.inner = inner
        inner.onEvent = { [weak self] event in
            if case .caption(let text, true, let channel) = event, !text.isEmpty {
                onFinal(text, channel)
            }
            self?.onEvent?(event)
        }
    }

    func start() { inner.start() }
    func send(_ audio: Data) { inner.send(audio) }
    func close() { inner.close() }
}
