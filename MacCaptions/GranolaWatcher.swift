import CoreAudio
import Foundation

/// Turns a flickering "is input running" signal into meeting start/end.
/// Starts once input has stayed on for `startDelay`, ends once it has stayed
/// off for `endDelay`, so a brief mic drop doesn't split one meeting in two.
struct MeetingDebouncer {
    enum Event: Equatable { case started, ended }

    let startDelay: TimeInterval
    let endDelay: TimeInterval
    private(set) var inMeeting = false
    /// When the input entered the state that would flip `inMeeting`; nil
    /// when the input agrees with `inMeeting`.
    private var pendingSince: Date?

    init(startDelay: TimeInterval, endDelay: TimeInterval) {
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// When the caller should call `update` again with the current input,
    /// to let a pending transition fire. Nil when nothing is pending.
    var nextCheck: Date? {
        pendingSince.map { $0.addingTimeInterval(inMeeting ? endDelay : startDelay) }
    }

    mutating func update(active: Bool, now: Date) -> Event? {
        guard active != inMeeting else {
            pendingSince = nil
            return nil
        }
        let since = pendingSince ?? now
        pendingSince = since
        guard now.timeIntervalSince(since) >= (inMeeting ? endDelay : startDelay) else { return nil }
        inMeeting = active
        pendingSince = nil
        return active ? .started : .ended
    }
}

/// Which captioning session a Granola meeting is allowed to stop: only one
/// it started itself, and only while the user hasn't stopped it by hand.
struct AutoSessionOwnership {
    private(set) var owned = false

    /// Returns whether to start captions.
    mutating func meetingStarted(capturing: Bool) -> Bool {
        guard !capturing else { return false }
        owned = true
        return true
    }

    /// Returns whether to stop captions.
    mutating func meetingEnded() -> Bool {
        defer { owned = false }
        return owned
    }

    mutating func userStopped() {
        owned = false
    }
}

/// Watches whether any Granola process is recording from an input device,
/// using CoreAudio's per-process objects (macOS 14.2+). Granola's audio
/// helper runs all the time, so process presence alone says nothing; its
/// input running is what marks a meeting being transcribed.
@MainActor
final class GranolaWatcher {
    private let onEvent: (MeetingDebouncer.Event) -> Void
    private var debouncer = MeetingDebouncer(startDelay: 3, endDelay: 15)
    private var timer: Timer?
    private var watching = false
    private var watchedProcesses: [AudioObjectID] = []
    /// Registered on the main queue, so it runs on the main actor.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }

    init(onEvent: @escaping (MeetingDebouncer.Event) -> Void) {
        self.onEvent = onEvent
    }

    nonisolated static func isGranola(bundleID: String?) -> Bool {
        bundleID?.hasPrefix("com.granola.") ?? false
    }

    func start() {
        guard !watching, #available(macOS 14.2, *) else { return }
        watching = true
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        refresh()
    }

    /// Stops watching. A meeting in progress is not reported as ended; the
    /// caller decides what to do with a session the watcher started.
    func stop() {
        guard watching, #available(macOS 14.2, *) else { return }
        watching = false
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        setWatchedProcesses([])
        timer?.invalidate()
        timer = nil
        debouncer = MeetingDebouncer(startDelay: debouncer.startDelay, endDelay: debouncer.endDelay)
    }

    private func refresh() {
        guard watching, #available(macOS 14.2, *) else { return }
        let granola = Self.processObjects().filter { Self.isGranola(bundleID: Self.bundleID(of: $0)) }
        setWatchedProcesses(granola)
        let active = granola.contains { Self.isRunningInput($0) }
        evaluate(active: active)
    }

    private func evaluate(active: Bool) {
        if let event = debouncer.update(active: active, now: Date()) { onEvent(event) }
        timer?.invalidate()
        timer = nil
        if let next = debouncer.nextCheck {
            timer = Timer.scheduledTimer(withTimeInterval: max(0, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    // MARK: CoreAudio

    @available(macOS 14.2, *)
    private func setWatchedProcesses(_ processes: [AudioObjectID]) {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        for id in watchedProcesses where !processes.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
        }
        for id in processes where !watchedProcesses.contains(id) {
            AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
        }
        watchedProcesses = processes
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}
