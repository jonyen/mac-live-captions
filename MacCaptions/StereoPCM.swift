import Foundation

/// The capture pipeline's wire format: interleaved stereo Int16 little-endian
/// frames, channel 0 = microphone, channel 1 = system audio.
enum StereoPCM {
    /// Split into (mic, system) sample arrays. A trailing partial frame is dropped.
    static func split(_ data: Data) -> ([Int16], [Int16]) {
        let frames = data.count / 4
        guard frames > 0 else { return ([], []) }
        var mic = [Int16](repeating: 0, count: frames)
        var system = [Int16](repeating: 0, count: frames)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                mic[f] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: f * 4, as: Int16.self))
                system[f] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: f * 4 + 2, as: Int16.self))
            }
        }
        return (mic, system)
    }
}
