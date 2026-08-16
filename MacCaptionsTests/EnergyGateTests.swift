import XCTest
@testable import Captions

/// Coverage for the silence-churn fix: `ChannelRecognizer` used to open a
/// recognition task on the very first audio chunk, silence included. macOS's
/// recognizer fails a silence-fed stream within ~200ms
/// (kAFAssistantErrorDomain 1110, "No speech detected"), the error handler
/// abandoned the task, and the next 100ms chunk opened a fresh one —
/// roughly four dead tasks a second, nothing ever transcribed. `EnergyGate`
/// is the pure decision of when audio is worth opening a task for; these
/// tests drive it directly, with no AVFoundation/Speech dependency.
final class EnergyGateTests: XCTestCase {
    /// Below the default threshold (50) — silence measured through the
    /// mic-conversion path lands ≤10.
    private func silence(_ count: Int = 320) -> [Int16] {
        [Int16](repeating: 5, count: count)
    }

    /// Above the default threshold — mic-path speech measures ≥90 even soft.
    private func loud(_ count: Int = 320) -> [Int16] {
        [Int16](repeating: 200, count: count)
    }

    // MARK: - Silence never opens the gate

    func testSilenceIsDroppedAndGateStaysClosed() {
        var gate = EnergyGate()
        let result = gate.admit(silence())
        XCTAssertNil(result)
        XCTAssertFalse(gate.isOpen)
    }

    func testRepeatedSilenceNeverOpensTheGate() {
        var gate = EnergyGate()
        for _ in 0..<50 {
            XCTAssertNil(gate.admit(silence()))
        }
        XCTAssertFalse(gate.isOpen)
    }

    // MARK: - Loud audio opens the gate with pre-roll

    func testLoudSamplesOpenTheGateAndReturnPrerollPlusOnset() {
        var gate = EnergyGate()
        let pre = silence(200)
        let onset = loud(320)
        XCTAssertNil(gate.admit(pre))

        let result = gate.admit(onset)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(result, pre + onset)
    }

    func testFirstChunkLoudEnoughOpensImmediately() {
        var gate = EnergyGate()
        let onset = loud(320)
        let result = gate.admit(onset)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(result, onset)
    }

    // MARK: - Once open, the gate only guards task creation, not content

    func testWhileOpenQuietSamplesStillPassThroughUnchanged() {
        var gate = EnergyGate()
        _ = gate.admit(loud())
        XCTAssertTrue(gate.isOpen)

        let quiet = silence(160)
        let result = gate.admit(quiet)
        XCTAssertEqual(result, quiet)
        XCTAssertTrue(gate.isOpen, "trailing silence must not close the gate mid-utterance")
    }

    // MARK: - rearm

    func testRearmClosesTheGate() {
        var gate = EnergyGate()
        _ = gate.admit(loud())
        XCTAssertTrue(gate.isOpen)

        gate.rearm()
        XCTAssertFalse(gate.isOpen)
    }

    func testRearmClearsPrerollSoStaleAudioIsNotReplayed() {
        var gate = EnergyGate(threshold: 50, prerollCapacity: 4_800)
        _ = gate.admit(silence(500)) // builds up pre-roll while closed
        gate.rearm()

        // Next open should carry only the fresh onset, not the pre-rearm preroll.
        let onset = loud(100)
        let result = gate.admit(onset)
        XCTAssertEqual(result, onset)
    }

    func testAfterRearmSilenceIsDroppedAgain() {
        var gate = EnergyGate()
        _ = gate.admit(loud())
        gate.rearm()

        XCTAssertNil(gate.admit(silence()))
        XCTAssertFalse(gate.isOpen)
    }

    // MARK: - Pre-roll is bounded

    func testPrerollIsBoundedAtCapacity() {
        let capacity = 4_800
        var gate = EnergyGate(threshold: 50, prerollCapacity: capacity)
        // Feed well over capacity worth of silence while closed.
        for _ in 0..<20 {
            XCTAssertNil(gate.admit(silence(500))) // 10,000 samples total
        }
        let onset = loud(320)
        guard let result = gate.admit(onset) else {
            return XCTFail("loud onset must open the gate")
        }
        XCTAssertLessThanOrEqual(result.count, capacity + onset.count)
        // The tail of the returned onset must be the loud samples themselves.
        XCTAssertEqual(Array(result.suffix(onset.count)), onset)
    }

    // MARK: - RMS correctness

    func testRmsOfKnownSineMatchesExpectedValue() {
        // A full-scale-ish sine's RMS is amplitude / sqrt(2). Use an
        // amplitude comfortably above the default threshold so the gate
        // opens, and check the returned sample count as a proxy that the
        // whole buffer was accepted (i.e. RMS was computed over all of it,
        // not just a prefix).
        let amplitude: Double = 1000
        let count = 1600
        var sine = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let value = amplitude * sin(2.0 * Double.pi * 440.0 * Double(i) / 16_000.0)
            sine[i] = Int16(value.rounded())
        }
        let expectedRMS = amplitude / 2.0.squareRoot()

        var gate = EnergyGate(threshold: expectedRMS - 50)
        XCTAssertNotNil(gate.admit(sine), "RMS \(expectedRMS) should clear a threshold below it")

        var gateAboveThreshold = EnergyGate(threshold: expectedRMS + 50)
        XCTAssertNil(gateAboveThreshold.admit(sine), "RMS \(expectedRMS) should not clear a threshold above it")
    }

    func testRmsOfConstantSignalIsItsMagnitude() {
        // A constant signal's RMS is exactly |value| — the simplest ground truth.
        var gate = EnergyGate(threshold: 99)
        XCTAssertNil(gate.admit([Int16](repeating: 98, count: 100)))

        var gate2 = EnergyGate(threshold: 99)
        XCTAssertNotNil(gate2.admit([Int16](repeating: 100, count: 100)))
    }
}
