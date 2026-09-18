import Foundation
import AVFoundation
import Speech
import CaptionCore

/// One audio channel's transcription pipeline, abstracted so the engine's
/// orchestration is testable without audio hardware or speech models.
protocol ChannelTranscriber: AnyObject, Sendable {
    /// Prepare (downloading the speech model if needed) and begin analyzing.
    /// `onResult` receives in-progress (`isFinal == false`) and finished text.
    func start(onResult: @escaping @Sendable (_ text: String, _ isFinal: Bool) -> Void) async throws
    /// 16 kHz mono Int16 samples, contiguous with the previous call.
    func append(_ samples: [Int16])
    /// Flush the last utterance and stop.
    func finish() async
}

enum AnalyzerSetupError: Error {
    case unsupportedLanguage(String)
    case modelDownloadFailed(Error)
    case noAudioFormat

    var message: String {
        switch self {
        case .unsupportedLanguage(let language):
            return "On-device captions don't support your language (\(language)) yet."
        case .modelDownloadFailed:
            return "Couldn't download the speech model. Check your internet connection, then start captions again."
        case .noAudioFormat:
            return "The speech model can't read this audio format."
        }
    }
}

/// On-device captioning with SpeechAnalyzer (macOS 26+). Unlike
/// SFSpeechRecognizer, it works with Siri & Dictation turned off and streams
/// continuously, with no one-minute task limit and no energy gate. Each
/// channel (mic, system audio) gets its own analyzer.
@available(macOS 26, *)
final class AnalyzerSpeechEngine: CaptionEngine, @unchecked Sendable {
    var onEvent: (@MainActor (CaptionEvent) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let makeChannel: (Int) -> ChannelTranscriber
    private let lock = NSLock()
    private var channels: [ChannelTranscriber] = []
    private var stopped = false

    init(makeChannel: @escaping (Int) -> ChannelTranscriber = { _ in AnalyzerChannel() }) {
        self.makeChannel = makeChannel
    }

    func start() {
        let candidates = [0, 1].map(makeChannel)
        Task {
            var started: [ChannelTranscriber] = []
            do {
                for (index, channel) in candidates.enumerated() {
                    try await channel.start { [weak self] text, isFinal in
                        // Consecutive results carry their inter-sentence space as a
                        // leading " ", which would double up once joined.
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        self?.emit(.caption(text: trimmed, isFinal: isFinal, channel: index))
                    }
                    started.append(channel)
                }
            } catch {
                for channel in started { await channel.finish() }
                let message = (error as? AnalyzerSetupError)?.message
                    ?? "Captions couldn't start: \(error.localizedDescription)"
                emit(.error(message: message))
                return
            }
            let superseded: Bool = lock.withLock {
                if stopped { return true }
                channels = started
                return false
            }
            if superseded {
                for channel in started { await channel.finish() }
                return
            }
            emit(.ready)
        }
    }

    func send(_ audio: Data) {
        let current = lock.withLock { stopped ? [] : channels }
        guard current.count == 2 else { return }
        let (mic, system) = StereoPCM.split(audio)
        current[0].append(mic)
        current[1].append(system)
    }

    func close() {
        let current: [ChannelTranscriber] = lock.withLock {
            stopped = true
            defer { channels = [] }
            return channels
        }
        Task {
            for channel in current { await channel.finish() }
        }
    }

    private func emit(_ event: CaptionEvent) {
        guard let onEvent else { return }
        Task { @MainActor in onEvent(event) }
    }
}

/// A SpeechTranscriber + SpeechAnalyzer fed by a stream of 16 kHz mono buffers.
@available(macOS 26, *)
final class AnalyzerChannel: ChannelTranscriber, @unchecked Sendable {
    private let locale: Locale
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func start(onResult: @escaping @Sendable (String, Bool) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AnalyzerSetupError.unsupportedLanguage(locale.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            // One-time download of the on-device model for this language.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw AnalyzerSetupError.modelDownloadFailed(error)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: sourceFormat) else {
            throw AnalyzerSetupError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let results = Task {
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                // Analysis ended (finish or cancellation); nothing to report.
            }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock {
            self.analyzer = analyzer
            self.continuation = continuation
            self.analyzerFormat = format
            self.converter = format == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: format)
            self.resultsTask = results
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let (continuation, converter, format) = lock.withLock { (self.continuation, self.converter, self.analyzerFormat) }
        guard let continuation, let format,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.int16ChannelData else { return }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }

        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: source))
            return
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        guard let out = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 1) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func finish() async {
        let (continuation, analyzer, results) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?) in
            defer { self.continuation = nil; self.analyzer = nil; self.resultsTask = nil }
            return (self.continuation, self.analyzer, self.resultsTask)
        }
        continuation?.finish()
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        }
        await results?.value
    }
}
