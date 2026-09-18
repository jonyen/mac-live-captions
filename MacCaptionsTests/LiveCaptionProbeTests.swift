import XCTest
import CaptionCore
@testable import Captions

/// Manual end-to-end probe of the real capture + recognition pipeline:
/// speaks a phrase through the speakers and reports what the mic channel
/// captions. Needs real hardware, permissions and audible output, so it only
/// runs when CAPTIONS_LIVE_PROBE=1 is set in the test environment
/// (`TEST_RUNNER_CAPTIONS_LIVE_PROBE=1 xcodebuild test ...`).
@MainActor
final class LiveCaptionProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTIONS_LIVE_PROBE"] == "1",
                          "live probe disabled")
    }

    private func run(echoCancellation: Bool, mic: Bool = true, system: Bool = false) async -> String {
        let store = CaptionStore()
        let hub = AudioHub(capture: DualCapture(
            micEnabled: { mic }, systemEnabled: { system }, echoCancellation: echoCancellation))
        var events: [String] = []
        let engine = TranscriptLoggingEngine(inner: AppModel.makeSpeechEngine()) { text, channel in
            events.append("final[\(channel ?? -1)]: \(text)")
        }
        let controller = SessionController(
            store: store, relay: engine, audio: hub.makeTap(), permission: MacPermissions())
        // Second tap on the same capture: what the speech engine is being fed.
        let meter = hub.makeTap()
        let rmsLock = NSLock()
        var ch0: [Int] = []
        var ch1: [Int] = []
        try? meter.start { data in
            let frames = data.count / 4
            guard frames > 0 else { return }
            var s0 = 0.0, s1 = 0.0
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for f in 0..<frames {
                    s0 += Double(p[f * 2]) * Double(p[f * 2]); s1 += Double(p[f * 2 + 1]) * Double(p[f * 2 + 1])
                }
            }
            rmsLock.lock(); ch0.append(Int((s0 / Double(frames)).squareRoot())); ch1.append(Int((s1 / Double(frames)).squareRoot())); rmsLock.unlock()
        }
        let connected = await controller.start()

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["The quick brown fox jumps over the lazy dog. Captions should see this sentence."]
        try? say.run()

        var sawPartial = false
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !(store.partials[0] ?? "").isEmpty || !(store.partials[1] ?? "").isEmpty { sawPartial = true }
        }
        let state = "\(store.state)"
        controller.stop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        meter.stop()
        let text = store.paragraphs.map { "\($0)" }.joined(separator: " | ")
        rmsLock.lock(); let a = ch0.sorted(); let b = ch1; rmsLock.unlock()
        let chunkInfo = "chunks=\(a.count) ch0 p50=\(a.isEmpty ? -1 : a[a.count/2]) max=\(a.last ?? -1) ch0>=50:\(a.filter { $0 >= 50 }.count) ch1max=\(b.max() ?? -1)"
        return "mic=\(mic) system=\(system) echo=\(echoCancellation) connected=\(connected) state=\(state) sawPartial=\(sawPartial) \(chunkInfo) finals=\(events) paragraphs=\(text.prefix(300))"
    }

    func testProbeSystemAudioCaptioning() async {
        let line = await run(echoCancellation: false, mic: false, system: true)
        print("LIVE_PROBE \(line)")
    }

    func testProbeMicCaptioning() async {
        for echo in [false, true] {
            let line = await run(echoCancellation: echo)
            print("LIVE_PROBE \(line)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

import AVFoundation
import Speech

/// Does SpeechAnalyzer (macOS 26+) transcribe while Siri & Dictation are off?
/// SFSpeechRecognizer does not (kLSRErrorDomain 201).
@MainActor
final class LiveSpeechAnalyzerProbeTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPTIONS_LIVE_PROBE"] == "1",
                          "live probe disabled")
    }

    func testProbeSpeechAnalyzerWithoutDictation() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000",
                         "The quick brown fox jumps over the lazy dog. Captions should see this sentence."]
        try say.run(); say.waitUntilExit()

        var report = "available=\(SpeechTranscriber.isAvailable)"
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("LIVE_PROBE analyzer \(report) no supported en-US locale"); return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        report += " locale=\(locale.identifier) status=\(await AssetInventory.status(forModules: [transcriber]))"
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                report += " downloaded"
            }
        } catch {
            print("LIVE_PROBE analyzer \(report) asset install failed: \(error)"); return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> ([String], Int) in
            var finals: [String] = []
            var volatile = 0
            for try await result in transcriber.results {
                if result.isFinal { finals.append(String(result.text.characters)) } else { volatile += 1 }
            }
            return (finals, volatile)
        }
        do {
            let file = try AVAudioFile(forReading: url)
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let (finals, volatile) = try await collector.value
            print("LIVE_PROBE analyzer \(report) volatile=\(volatile) finals=\(finals)")
        } catch {
            collector.cancel()
            let e = error as NSError
            print("LIVE_PROBE analyzer \(report) FAILED \(e.domain) \(e.code) \(e.localizedDescription)")
        }
    }
}
