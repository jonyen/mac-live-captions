import Foundation

/// Decides when caption audio is worth opening a recognition task for.
/// Silence must not spawn tasks (the recognizer fails silent streams within
/// ~200ms and constant task churn means nothing is ever heard), and the
/// utterance that opens the gate must not lose its own onset — so while
/// closed, the gate keeps a short pre-roll to hand to the task it opens.
struct EnergyGate {
    /// RMS below this is silence. Speech through the mic path measures ≥90
    /// even for soft speech; converted silence measures ≤10.
    private let threshold: Double
    /// ~300 ms at 16 kHz.
    private let prerollCapacity: Int
    private var preroll: [Int16] = []
    private(set) var isOpen = false

    init(threshold: Double = 50, prerollCapacity: Int = 4_800) {
        self.threshold = threshold
        self.prerollCapacity = prerollCapacity
    }

    /// Feed samples. Returns the samples the recognizer should receive now:
    /// nil while closed (silence), the pre-roll + onset when it opens,
    /// the samples unchanged while open.
    mutating func admit(_ samples: [Int16]) -> [Int16]? {
        guard !samples.isEmpty else { return nil }

        if isOpen { return samples }

        preroll.append(contentsOf: samples)
        if preroll.count > prerollCapacity {
            preroll.removeFirst(preroll.count - prerollCapacity)
        }

        guard Self.rms(samples) >= threshold else { return nil }

        isOpen = true
        let onset = preroll
        preroll = []
        return onset
    }

    /// Close and re-arm (the recognizer gave up or the utterance finalized).
    /// Without this, a task that dies on silence would leave the gate open,
    /// so the very next chunk — silence again — would reopen a task
    /// straight into the same ~200ms failure, which is the churn this gate
    /// exists to stop.
    mutating func rearm() {
        isOpen = false
        preroll = []
    }

    private static func rms(_ samples: [Int16]) -> Double {
        var sumSquares = 0.0
        for sample in samples { sumSquares += Double(sample) * Double(sample) }
        return (sumSquares / Double(samples.count)).squareRoot()
    }
}
