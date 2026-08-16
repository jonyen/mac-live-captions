import XCTest
import AVFoundation
@testable import Captions

/// Regression coverage for the multichannel-mic silence bug: on this
/// machine's mic array, with voice processing enabled, AVAudioEngine hands
/// the tap 9-channel deinterleaved Float32 48kHz buffers. A direct
/// AVAudioConverter from that format straight to 16kHz mono Int16 silently
/// returns zero-filled output (status .haveData, no error) even though
/// channel 0 carries real voice. These tests drive the fixed seam —
/// `MicSource.monoChannel0` extraction followed by the real instance
/// `convert(_:)` — against a synthetic buffer shaped like that live probe.
final class MicSourceTests: XCTestCase {
    /// A 9-channel deinterleaved Float32 48kHz buffer: a 440 Hz tone
    /// (amplitude 0.3) on channel 0, silence on channels 1...8 — matching
    /// the shape probed live on this Mac's mic array.
    private func nineChannelBuffer(frames: Int = 4_800) -> AVAudioPCMBuffer {
        // The channels:9 convenience initializer returns nil — AVFoundation
        // has no standard layout for 9 channels, so an explicit discrete
        // layout is required (this is exactly the shape a mic array with
        // voice processing hands the tap: N discrete, unlabeled channels).
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)!
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel0 = buffer.floatChannelData![0]
        for i in 0..<frames {
            channel0[i] = 0.3 * sinf(2.0 * Float.pi * 440.0 * Float(i) / 48_000.0)
        }
        // Channels 1...8 are left at their zero-initialized default.
        return buffer
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    // MARK: - Extraction

    func testExtractionPreservesFrameLength() {
        let source = nineChannelBuffer(frames: 4_800)
        let mono = MicSource.monoChannel0(source)
        XCTAssertEqual(mono?.frameLength, source.frameLength)
    }

    func testExtractionCarriesChannel0SignalNotSilence() {
        let source = nineChannelBuffer(frames: 4_800)
        guard let mono = MicSource.monoChannel0(source) else {
            return XCTFail("extraction returned nil")
        }
        XCTAssertEqual(mono.format.channelCount, 1)
        let data = mono.floatChannelData![0]
        let samples = (0..<Int(mono.frameLength)).map { Double(data[$0]) }
        let sumSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rmsValue = (sumSquares / Double(samples.count)).squareRoot()
        XCTAssertGreaterThan(rmsValue, 0.1, "channel-0 signal should survive extraction")
    }

    func testExtractionHandlesInterleavedInputToo() {
        // inputNode formats are typically deinterleaved, but the extraction
        // seam must not assume that — cover the interleaved layout too.
        // (3 channels also has no standard layout — see nineChannelBuffer.)
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout)
        let frames = 1_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let raw = buffer.audioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            raw[i * 3] = 0.3 * sinf(2.0 * Float.pi * 440.0 * Float(i) / 48_000.0) // channel 0
            raw[i * 3 + 1] = 1.0 // channel 1 — must NOT leak into the mono result
            raw[i * 3 + 2] = 1.0 // channel 2 — must NOT leak into the mono result
        }
        guard let mono = MicSource.monoChannel0(buffer) else {
            return XCTFail("extraction returned nil")
        }
        XCTAssertEqual(mono.frameLength, buffer.frameLength)
        let data = mono.floatChannelData![0]
        let samples = (0..<Int(mono.frameLength)).map { Double(data[$0]) }
        let sumSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rmsValue = (sumSquares / Double(samples.count)).squareRoot()
        // A tone-only RMS is well under 1.0; if channels 1/2 (constant 1.0)
        // had leaked in via a wrong stride, RMS would be ~1.0 or higher.
        XCTAssertLessThan(rmsValue, 0.5)
        XCTAssertGreaterThan(rmsValue, 0.1)
    }

    // MARK: - End-to-end seam (extraction + real instance convert)

    func testEndToEndConversionProducesAudibleSignalNotSilence() {
        let source = nineChannelBuffer(frames: 4_800)
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            return XCTFail("converter unavailable")
        }
        let sut = MicSource()
        sut.converter = converter // seam: inject without spinning up AVAudioEngine

        let samples = sut.convert(source)

        XCTAssertNotNil(samples)
        XCTAssertFalse(samples?.isEmpty ?? true)
        XCTAssertGreaterThan(rms(samples ?? []), 1_000,
            "9-channel input's channel-0 tone must survive as real signal, not the old zero-fill")
    }
}
