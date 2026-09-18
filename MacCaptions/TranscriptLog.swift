import Foundation

/// Appends finished captions to one Markdown transcript file per captioning
/// session, so a conversation can be read back after the overlay is gone.
///
/// - The file is created lazily on the first non-blank line: starting and
///   stopping captions without anyone speaking leaves nothing behind.
/// - Channel 0 (microphone) is labelled "Me", channel 1 (system audio, i.e.
///   everyone on the call) "Them"; a caption without a channel is "Speaker".
/// - Every line is written and closed immediately, so quitting or crashing
///   mid-session loses at most the utterance still in progress.
/// - Write failures are recorded in `lastError` rather than thrown: losing
///   the transcript must never take captioning down with it.
@MainActor
final class TranscriptLog {
    private(set) var fileURL: URL?
    private(set) var lastError: Error?

    private let directory: URL
    private let startedAt: Date
    private let now: () -> Date
    private let fileManager: FileManager
    private let clockFormatter: DateFormatter
    private let headerFormatter: DateFormatter
    private let fileNameFormatter: DateFormatter

    init(directory: URL,
         startedAt: Date = Date(),
         now: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .current,
         fileManager: FileManager = .default) {
        self.directory = directory
        self.startedAt = startedAt
        self.now = now
        self.fileManager = fileManager
        clockFormatter = Self.formatter("HH:mm:ss", timeZone)
        headerFormatter = Self.formatter("yyyy-MM-dd HH:mm:ss zzz", timeZone)
        // Finder shows ":" as "/", so the file name uses dots.
        fileNameFormatter = Self.formatter("yyyy-MM-dd HH.mm.ss", timeZone)
    }

    /// Append one finished caption. Blank text is ignored.
    func record(text: String, channel: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = clockFormatter.string(from: now())
        append("[\(stamp)] \(Self.speaker(for: channel)): \(trimmed)\n\n")
    }

    /// Mark where captioning resumed after a pause. Written only into an
    /// existing transcript: a resume before anyone spoke is not worth a file.
    func noteResumed() {
        guard fileURL != nil else { return }
        append("*Resumed at \(clockFormatter.string(from: now()))*\n\n")
    }

    static func speaker(for channel: Int?) -> String {
        switch channel {
        case 0: return "Me"
        case 1: return "Them"
        default: return "Speaker"
        }
    }

    private func append(_ line: String) {
        do {
            let url = try fileURL ?? createFile()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            lastError = nil
        } catch {
            lastError = error
        }
    }

    private func createFile() throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(fileNameFormatter.string(from: startedAt)) Captions"
        var url = directory.appendingPathComponent("\(base).md")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(suffix).md")
            suffix += 1
        }
        let header = "# Captions transcript, \(headerFormatter.string(from: startedAt))\n\n"
        guard fileManager.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        fileURL = url
        return url
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
