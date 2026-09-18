import XCTest
import CaptionCore
@testable import Captions

final class StereoPCMTests: XCTestCase {
    func testSplitsInterleavedFramesIntoMicAndSystem() {
        let frames: [Int16] = [1, 10, 2, 20, -3, -30]
        let data = frames.withUnsafeBufferPointer { Data(buffer: $0) }
        let (mic, system) = StereoPCM.split(data)
        XCTAssertEqual(mic, [1, 2, -3])
        XCTAssertEqual(system, [10, 20, -30])
    }

    func testEmptyAndPartialFramesYieldNothingExtra() {
        XCTAssertEqual(StereoPCM.split(Data()).0, [])
        let (mic, system) = StereoPCM.split(Data([1, 0, 2, 0, 9]))  // one frame + a stray byte
        XCTAssertEqual(mic, [1])
        XCTAssertEqual(system, [2])
    }
}

/// Stands in for one SpeechAnalyzer-backed channel.
private final class FakeChannel: ChannelTranscriber, @unchecked Sendable {
    let channel: Int
    var startError: Error?
    private(set) var appended: [[Int16]] = []
    private(set) var finished = false
    private(set) var onResult: (@Sendable (String, Bool) -> Void)?

    init(channel: Int) { self.channel = channel }

    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        if let startError { throw startError }
        self.onResult = onResult
    }
    func append(_ samples: [Int16]) { appended.append(samples) }
    func finish() async {
        finished = true
        onResult?("flushed on finish", true)
    }
}

@available(macOS 26, *)
@MainActor
final class AnalyzerSpeechEngineTests: XCTestCase {
    private var channels: [FakeChannel] = []
    private var events: [CaptionEvent] = []

    private func makeEngine(failing: Error? = nil) -> AnalyzerSpeechEngine {
        channels = [FakeChannel(channel: 0), FakeChannel(channel: 1)]
        channels[1].startError = failing
        let engine = AnalyzerSpeechEngine { [unowned self] index in self.channels[index] }
        engine.onEvent = { [unowned self] in self.events.append($0) }
        return engine
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testReadyOnlyAfterBothChannelsStart() async {
        let engine = makeEngine()
        engine.start()
        await waitFor { self.events.contains(.ready) }
        XCTAssertNotNil(channels[0].onResult)
        XCTAssertNotNil(channels[1].onResult)
    }

    func testSetupFailureIsReportedAsAnErrorNotReady() async {
        let engine = makeEngine(failing: AnalyzerSetupError.unsupportedLanguage("xx-YY"))
        engine.start()
        await waitFor { self.events.contains { if case .error = $0 { return true }; return false } }
        XCTAssertFalse(events.contains(.ready))
        guard case .error(let message)? = events.last else { return XCTFail("no error") }
        XCTAssertTrue(message.contains("xx-YY"), message)
    }

    func testAudioIsSplitPerChannel() async {
        let engine = makeEngine()
        engine.start()
        await waitFor { self.events.contains(.ready) }
        let frames: [Int16] = [5, 50, 6, 60]
        engine.send(frames.withUnsafeBufferPointer { Data(buffer: $0) })
        XCTAssertEqual(channels[0].appended, [[5, 6]])
        XCTAssertEqual(channels[1].appended, [[50, 60]])
    }

    func testAudioBeforeReadyIsDropped() {
        let engine = makeEngine()
        engine.send(Data([1, 0, 2, 0]))
        XCTAssertTrue(channels[0].appended.isEmpty)
    }

    func testResultsBecomeCaptionsOnTheirChannel() async {
        let engine = makeEngine()
        engine.start()
        await waitFor { self.events.contains(.ready) }
        channels[0].onResult?("hello wor", false)
        channels[1].onResult?("hi there.", true)
        channels[1].onResult?("", true)
        await waitFor { self.events.count >= 3 }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let a wrongly forwarded empty caption land
        XCTAssertTrue(events.contains(.caption(text: "hello wor", isFinal: false, channel: 0)))
        XCTAssertTrue(events.contains(.caption(text: "hi there.", isFinal: true, channel: 1)))
        XCTAssertFalse(events.contains(.caption(text: "", isFinal: true, channel: 1)))
    }

    func testResultTextIsTrimmedAndWhitespaceOnlyIsDropped() async {
        // Live SpeechAnalyzer output: a second sentence arrived as " caption should see the sentence."
        let engine = makeEngine()
        engine.start()
        await waitFor { self.events.contains(.ready) }
        channels[1].onResult?("  caption should see the sentence.\n", true)
        channels[1].onResult?("   ", true)
        await waitFor { self.events.count >= 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(events.dropFirst().map { $0 }, [.caption(text: "caption should see the sentence.", isFinal: true, channel: 1)])
    }

    func testCloseFinishesBothChannelsAndStopsFeedingThem() async {
        let engine = makeEngine()
        engine.start()
        await waitFor { self.events.contains(.ready) }
        engine.close()
        await waitFor { self.channels.allSatisfy(\.finished) }
        engine.send(Data([1, 0, 2, 0]))
        XCTAssertTrue(channels[0].appended.isEmpty)
        // The final flush still reaches listeners (the transcript logger needs it).
        await waitFor { self.events.contains(.caption(text: "flushed on finish", isFinal: true, channel: 0)) }
    }

    func testCloseDuringSetupFinishesTheChannelsInsteadOfGoingReady() async {
        let engine = makeEngine()
        engine.close()
        engine.start()
        await waitFor { self.channels.allSatisfy(\.finished) || self.events.contains(.ready) }
        XCTAssertFalse(events.contains(.ready))
    }

    func testSetupErrorMessagesSayWhatToDo() {
        XCTAssertTrue(AnalyzerSetupError.unsupportedLanguage("fr-CA").message.contains("fr-CA"))
        let download = AnalyzerSetupError.modelDownloadFailed(NSError(domain: "net", code: -1009)).message
        XCTAssertTrue(download.localizedCaseInsensitiveContains("download"), download)
    }
}
