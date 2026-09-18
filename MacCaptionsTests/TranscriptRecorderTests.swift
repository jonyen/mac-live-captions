import XCTest
import CaptionCore
@testable import Captions

private final class StubEngine: CaptionEngine {
    var onEvent: (@MainActor (CaptionEvent) -> Void)?
    var onClose: (@MainActor () -> Void)?
    func start() {}
    func send(_ audio: Data) {}
    func close() {}
}

@MainActor
final class TranscriptRecorderTests: XCTestCase {
    private var root: URL!
    private var made = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptRecorderTests-\(UUID().uuidString)")
        made = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRecorder() -> TranscriptRecorder {
        TranscriptRecorder { [unowned self] in
            self.made += 1
            return TranscriptLog(directory: self.root.appendingPathComponent("log\(self.made)"))
        }
    }

    private func final(_ engine: CaptionEngine, _ text: String, channel: Int = 0) {
        engine.onEvent?(.caption(text: text, isFinal: true, channel: channel))
    }

    func testDisabledLeavesTheEngineUntouchedAndWritesNothing() {
        let recorder = makeRecorder()
        let inner = StubEngine()
        let engine = recorder.beginCapture(wrapping: inner, enabled: false)
        XCTAssertTrue(engine === inner)
        XCTAssertNil(recorder.fileURL)
        XCTAssertEqual(made, 0)
    }

    func testEnabledRecordsFinishedCaptionsFromTheWrappedEngine() throws {
        let recorder = makeRecorder()
        let inner = StubEngine()
        let engine = recorder.beginCapture(wrapping: inner, enabled: true)
        engine.onEvent = { _ in }
        XCTAssertFalse(engine === inner)

        final(inner, "hello")
        let text = try String(contentsOf: XCTUnwrap(recorder.fileURL), encoding: .utf8)
        XCTAssertTrue(text.contains("Me: hello"), text)
    }

    func testPauseAndResumeContinueTheSameTranscript() throws {
        let recorder = makeRecorder()
        let first = StubEngine()
        _ = recorder.beginCapture(wrapping: first, enabled: true)
        final(first, "before pause")

        let second = StubEngine()
        _ = recorder.beginCapture(wrapping: second, enabled: true)
        final(second, "after pause", channel: 1)

        XCTAssertEqual(made, 1)
        let text = try String(contentsOf: XCTUnwrap(recorder.fileURL), encoding: .utf8)
        XCTAssertTrue(text.contains("before pause"))
        XCTAssertTrue(text.contains("*Resumed at "))
        XCTAssertTrue(text.contains("Them: after pause"))
    }

    func testEndingTheSessionStartsANewTranscriptNextTime() {
        let recorder = makeRecorder()
        let first = StubEngine()
        _ = recorder.beginCapture(wrapping: first, enabled: true)
        final(first, "session one")
        let firstFile = recorder.fileURL

        recorder.endSession()
        XCTAssertNil(recorder.fileURL)

        let second = StubEngine()
        _ = recorder.beginCapture(wrapping: second, enabled: true)
        final(second, "session two")
        XCTAssertEqual(made, 2)
        XCTAssertNotNil(recorder.fileURL)
        XCTAssertNotEqual(recorder.fileURL, firstFile)
    }

    func testTurningSavingOffMidSessionStopsWritingOnResume() throws {
        let recorder = makeRecorder()
        let first = StubEngine()
        _ = recorder.beginCapture(wrapping: first, enabled: true)
        final(first, "kept")
        let firstFile = try XCTUnwrap(recorder.fileURL)

        let second = StubEngine()
        let engine = recorder.beginCapture(wrapping: second, enabled: false)
        XCTAssertTrue(engine === second)
        XCTAssertNil(recorder.fileURL)
        final(first, "late event from the old engine")
        XCTAssertNil(recorder.fileURL, "a closed session's stragglers must not reopen a transcript")
        let text = try String(contentsOf: firstFile, encoding: .utf8)
        XCTAssertTrue(text.contains("kept"))
        XCTAssertFalse(text.contains("late event"), "a closed transcript must not be appended to")
    }

    func testWriteFailuresAreSurfacedAndClearOnSuccess() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        var folder = blocker
        let recorder = TranscriptRecorder { TranscriptLog(directory: folder) }

        let first = StubEngine()
        _ = recorder.beginCapture(wrapping: first, enabled: true)
        final(first, "lost")
        XCTAssertNotNil(recorder.lastError)

        recorder.endSession()
        XCTAssertNil(recorder.lastError, "a new session starts clean")
        folder = root.appendingPathComponent("ok")
        let second = StubEngine()
        _ = recorder.beginCapture(wrapping: second, enabled: true)
        final(second, "saved")
        XCTAssertNil(recorder.lastError)
        XCTAssertNotNil(recorder.fileURL)
    }

    func testFolderSettingFallsBackToDocumentsWhenUnset() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(SettingsStore.transcriptsFolder(stored: nil, home: home).path,
                       "/Users/someone/Documents/Captions Transcripts")
        XCTAssertEqual(SettingsStore.transcriptsFolder(stored: "", home: home).path,
                       "/Users/someone/Documents/Captions Transcripts")
        XCTAssertEqual(SettingsStore.transcriptsFolder(stored: "/Volumes/Notes/Calls", home: home).path,
                       "/Volumes/Notes/Calls")
    }
}

// MARK: - Through the real SessionController

private final class ScriptedEngine: CaptionEngine {
    var onEvent: (@MainActor (CaptionEvent) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var closed = false
    func start() { let e = onEvent; Task { @MainActor in e?(.ready) } }
    func send(_ audio: Data) {}
    func close() { closed = true }
}

private final class SilentAudio: AudioCapturing {
    func start(onChunk: @escaping (Data) -> Void) throws {}
    func stop() {}
}

private struct Granted: MicPermissionProviding {
    func ensureGranted() async -> Bool { true }
}

@MainActor
final class TranscriptSessionIntegrationTests: XCTestCase {
    func testCaptionsReachBothTheOverlayAndTheTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSessionIntegrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = TranscriptRecorder { TranscriptLog(directory: root) }
        let inner = ScriptedEngine()
        let store = CaptionStore()
        let controller = SessionController(
            store: store,
            relay: recorder.beginCapture(wrapping: inner, enabled: true),
            audio: SilentAudio(), permission: Granted())

        let connected = await controller.start()
        XCTAssertTrue(connected)
        for _ in 0..<50 where store.state != .listening { await Task.yield() }
        XCTAssertEqual(store.state, .listening)

        inner.onEvent?(.caption(text: "hello from me", isFinal: true, channel: 0))
        inner.onEvent?(.caption(text: "and from them", isFinal: true, channel: 1))
        controller.stop()
        recorder.endSession()

        XCTAssertTrue(inner.closed)
        XCTAssertFalse(store.paragraphs.isEmpty)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("Me: hello from me"), text)
        XCTAssertTrue(text.contains("Them: and from them"), text)
    }
}
