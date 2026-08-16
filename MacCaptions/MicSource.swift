import AVFoundation

/// Mic capture producing 16 kHz mono Int16 samples (same conversion approach
/// as the watch AudioCapture, minus AVAudioSession, which doesn't exist on macOS).
final class MicSource {
    private let engine = AVAudioEngine()
    // Not `private`: exposed at file-crossing (internal) visibility so
    // MicSourceTests can inject a pre-built converter and drive `convert(_:)`
    // directly, without spinning up AVAudioEngine (which needs live hardware).
    var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func start(onSamples: @escaping ([Int16]) -> Void) throws {
        let input = engine.inputNode
        // Echo cancellation: without it, speaker playback (already captured on
        // the system-audio channel) bleeds into the mic and the same speech is
        // transcribed twice, once per channel. Best-effort — some devices
        // don't support voice processing, and plain capture still works.
        if !input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(true)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        // Build the converter from a mono Float32 intermediate format, NOT
        // directly from inputFormat. See the WHY comment on monoChannel0(_:)
        // below — AVAudioConverter silently zero-fills a direct multichannel
        // -> mono conversion on modern mic arrays, so we extract channel 0
        // ourselves and only ask the converter to do rate/bit-depth work.
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
            channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        // Belt-and-braces: a stray tap from a prior start() (if stop() was
        // skipped) would make installTap raise an uncatchable NSException.
        // Safe to call even when no tap is installed.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_600, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let samples = self.convert(buffer), !samples.isEmpty else { return }
            onSamples(samples)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    /// Extract channel 0 of `buffer` into a new mono Float32 buffer at the
    /// same sample rate.
    ///
    /// WHY: AVAudioConverter silently zero-fills a direct multichannel
    /// deinterleaved -> mono conversion on modern mic arrays. Proven live on
    /// this machine's 9-channel M4 Pro mic array with voice processing
    /// enabled: `AVAudioConverter(from: 9ch deinterleaved Float32 48kHz, to:
    /// 16kHz mono Int16)` reports status `.haveData`, no error, but every
    /// sample is 0 — while channel 0 of the raw input buffer carries real
    /// voice (RMS 89-5874, tracking speech). Extracting channel 0 first and
    /// converting *that* mono buffer works correctly. Handles both
    /// deinterleaved (the common case for AVAudioEngine's inputNode) and
    /// interleaved layouts — don't assume which one a given input format uses.
    static func monoChannel0(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = Int(buffer.frameLength)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
            channels: 1, interleaved: false),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let monoData = mono.floatChannelData?[0]
        else { return nil }

        if buffer.format.isInterleaved {
            guard let raw = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
            let stride = Int(buffer.format.channelCount)
            let source = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount {
                monoData[i] = source[i * stride]
            }
        } else {
            guard let source = buffer.floatChannelData?[0] else { return nil }
            monoData.update(from: source, count: frameCount)
        }
        mono.frameLength = buffer.frameLength
        return mono
    }

    // Not `private`: see the note on `converter` above — same testability seam.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let converter, let mono = MicSource.monoChannel0(buffer) else { return nil }
        let ratio = targetFormat.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let channel = out.int16ChannelData, out.frameLength > 0 else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    enum CaptureError: Error { case converterUnavailable }
}
