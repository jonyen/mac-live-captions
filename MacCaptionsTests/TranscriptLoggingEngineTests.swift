import XCTest
import CaptionCore
@testable import Captions

private final class FakeEngine: CaptionEngine {
    var onEvent: (@MainActor (CaptionEvent) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var started = 0
    var closed = 0
    var sent: [Data] = []

    func start() { started += 1 }
    func send(_ audio: Data) { sent.append(audio) }
    func close() { closed += 1 }
}

@MainActor
final class TranscriptLoggingEngineTests: XCTestCase {
    func testForwardsEveryEventUnchanged() {
        let inner = FakeEngine()
        let engine = TranscriptLoggingEngine(inner: inner) { _, _ in }
        var seen: [CaptionEvent] = []
        engine.onEvent = { seen.append($0) }

        let events: [CaptionEvent] = [
            .ready,
            .caption(text: "hel", isFinal: false, channel: 0),
            .caption(text: "hello", isFinal: true, channel: 0),
            .error(message: "boom"),
        ]
        events.forEach { inner.onEvent?($0) }

        XCTAssertEqual(seen, events)
    }

    func testLogsOnlyFinishedNonEmptyCaptionsWithTheirChannel() {
        let inner = FakeEngine()
        var logged: [(String, Int?)] = []
        let engine = TranscriptLoggingEngine(inner: inner) { logged.append(($0, $1)) }
        engine.onEvent = { _ in }

        inner.onEvent?(.ready)
        inner.onEvent?(.caption(text: "partial words", isFinal: false, channel: 1))
        inner.onEvent?(.caption(text: "final from them", isFinal: true, channel: 1))
        inner.onEvent?(.caption(text: "", isFinal: true, channel: 0))
        inner.onEvent?(.caption(text: "final from me", isFinal: true, channel: 0))
        inner.onEvent?(.error(message: "boom"))

        XCTAssertEqual(logged.map(\.0), ["final from them", "final from me"])
        XCTAssertEqual(logged.map(\.1), [1, 0])
    }

    func testLogsEvenBeforeTheSessionAttachesItsHandler() {
        let inner = FakeEngine()
        var logged: [String] = []
        let engine = TranscriptLoggingEngine(inner: inner) { text, _ in logged.append(text) }
        inner.onEvent?(.caption(text: "early", isFinal: true, channel: 0))
        XCTAssertEqual(logged, ["early"])
        XCTAssertNil(engine.onEvent)
    }

    func testStartSendCloseAndOnCloseAreDelegated() {
        let inner = FakeEngine()
        let engine = TranscriptLoggingEngine(inner: inner) { _, _ in }
        var closedCallbacks = 0
        engine.onClose = { closedCallbacks += 1 }

        engine.start()
        engine.send(Data([1, 2, 3, 4]))
        engine.close()
        inner.onClose?()

        XCTAssertEqual(inner.started, 1)
        XCTAssertEqual(inner.sent, [Data([1, 2, 3, 4])])
        XCTAssertEqual(inner.closed, 1)
        XCTAssertEqual(closedCallbacks, 1)
    }
}
