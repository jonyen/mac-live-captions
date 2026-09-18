import XCTest
@testable import Captions

@MainActor
final class TranscriptLogTests: XCTestCase {
    private var root: URL!
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-16 11:00:05 UTC
    private let start = Date(timeIntervalSince1970: 1_789_556_405)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLog(folder: URL? = nil, clock: @escaping () -> Date) -> TranscriptLog {
        TranscriptLog(directory: folder ?? root.appendingPathComponent("nested/Transcripts"),
                      startedAt: start, now: clock, timeZone: utc)
    }

    private func contents(_ log: TranscriptLog) throws -> String {
        let url = try XCTUnwrap(log.fileURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoFileIsCreatedUntilTheFirstLine() {
        let log = makeLog(clock: { self.start })
        XCTAssertNil(log.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testBlankTextIsIgnored() {
        let log = makeLog(clock: { self.start })
        log.record(text: "   \n", channel: 0)
        log.record(text: "", channel: 1)
        XCTAssertNil(log.fileURL)
    }

    func testFirstLineCreatesTheFolderAndANamedFileWithAHeader() throws {
        let log = makeLog(clock: { self.start.addingTimeInterval(2) })
        log.record(text: "hello there", channel: 0)

        let url = try XCTUnwrap(log.fileURL)
        XCTAssertEqual(url.lastPathComponent, "2026-09-16 11.00.05 Captions.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Transcripts")
        let text = try contents(log)
        XCTAssertTrue(text.hasPrefix("# Captions transcript, 2026-09-16 11:00:05 GMT\n\n"), text)
    }

    func testMicIsMeAndSystemAudioIsThemWithArrivalTime() throws {
        var clock = start.addingTimeInterval(7)
        let log = makeLog(clock: { clock })
        log.record(text: "Can you hear me?", channel: 0)
        clock = start.addingTimeInterval(9)
        log.record(text: "Yes, loud and clear.", channel: 1)
        clock = start.addingTimeInterval(12)
        log.record(text: "Mono caption", channel: nil)

        let text = try contents(log)
        XCTAssertTrue(text.contains("[11:00:17] Speaker: Mono caption\n\n"), text)
        XCTAssertTrue(text.contains("[11:00:12] Me: Can you hear me?\n\n"), text)
        XCTAssertTrue(text.contains("[11:00:14] Them: Yes, loud and clear.\n\n"), text)
        let me = try XCTUnwrap(text.range(of: "Me: Can you hear me?"))
        let them = try XCTUnwrap(text.range(of: "Them: Yes, loud and clear."))
        XCTAssertLessThan(me.lowerBound, them.lowerBound)
    }

    func testTextIsTrimmedButOtherwiseVerbatim() throws {
        let log = makeLog(clock: { self.start })
        log.record(text: "  **not bold** & <kept>  ", channel: 0)
        XCTAssertTrue(try contents(log).contains("Me: **not bold** & <kept>\n\n"))
    }

    func testResumeMarkerOnlyAppearsOnceSomethingWasWritten() throws {
        var clock = start
        let log = makeLog(clock: { clock })
        log.noteResumed()
        XCTAssertNil(log.fileURL, "a resume before any speech must not create a file")

        log.record(text: "before pause", channel: 0)
        clock = start.addingTimeInterval(300)
        log.noteResumed()
        log.record(text: "after pause", channel: 1)

        let text = try contents(log)
        let marker = try XCTUnwrap(text.range(of: "*Resumed at 11:05:05*\n\n"), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "before pause")).lowerBound, marker.lowerBound)
        XCTAssertGreaterThan(try XCTUnwrap(text.range(of: "after pause")).lowerBound, marker.lowerBound)
    }

    func testTwoSessionsStartingTheSameSecondDoNotOverwriteEachOther() throws {
        let folder = root.appendingPathComponent("same")
        let first = makeLog(folder: folder, clock: { self.start })
        first.record(text: "first session", channel: 0)
        let second = makeLog(folder: folder, clock: { self.start })
        second.record(text: "second session", channel: 0)

        XCTAssertEqual(try XCTUnwrap(second.fileURL).lastPathComponent, "2026-09-16 11.00.05 Captions 2.md")
        XCTAssertTrue(try contents(first).contains("first session"))
        XCTAssertFalse(try contents(first).contains("second session"))
        XCTAssertTrue(try contents(second).contains("second session"))
    }

    func testAnUnwritableFolderRecordsAnErrorInsteadOfCrashing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)

        let log = makeLog(folder: blocker, clock: { self.start })
        log.record(text: "lost", channel: 0)

        XCTAssertNil(log.fileURL)
        XCTAssertNotNil(log.lastError)
    }
}
