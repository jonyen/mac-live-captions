import XCTest
import AVFoundation
@testable import Captions

/// Voice processing (echo cancellation) on macOS ducks every other app's
/// audio while it runs, at a level that makes calls and videos inaudible.
/// These tests pin the policy that keeps it from silencing the Mac.
private final class FakeInput: VoiceProcessingInput {
    var isVoiceProcessingEnabled = false
    var failToEnable = false
    var setCalls: [Bool] = []
    var duckingWrites: [AVAudioVoiceProcessingOtherAudioDuckingConfiguration] = []
    var voiceProcessingOtherAudioDuckingConfiguration =
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .default) {
        didSet { duckingWrites.append(voiceProcessingOtherAudioDuckingConfiguration) }
    }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if enabled && failToEnable { throw NSError(domain: "fake", code: 1) }
        isVoiceProcessingEnabled = enabled
    }
}

final class VoiceProcessingTests: XCTestCase {
    func testOffByDefaultNeverTurnsVoiceProcessingOn() {
        let input = FakeInput()
        MicSource.applyVoiceProcessing(false, to: input)
        XCTAssertFalse(input.isVoiceProcessingEnabled)
        XCTAssertFalse(input.setCalls.contains(true))
    }

    func testOffTurnsOffVoiceProcessingLeftOnByAnEarlierSession() {
        let input = FakeInput()
        input.isVoiceProcessingEnabled = true
        MicSource.applyVoiceProcessing(false, to: input)
        XCTAssertFalse(input.isVoiceProcessingEnabled)
    }

    func testOnEnablesItWithTheLightestDucking() throws {
        let input = FakeInput()
        MicSource.applyVoiceProcessing(true, to: input)
        XCTAssertTrue(input.isVoiceProcessingEnabled)
        let config = try XCTUnwrap(input.duckingWrites.last)
        XCTAssertEqual(config.duckingLevel, .min)
        XCTAssertFalse(config.enableAdvancedDucking.boolValue)
    }

    func testOnWhenTheDeviceCannotDoItLeavesDuckingAlone() {
        let input = FakeInput()
        input.failToEnable = true
        MicSource.applyVoiceProcessing(true, to: input)
        XCTAssertFalse(input.isVoiceProcessingEnabled)
        XCTAssertTrue(input.duckingWrites.isEmpty)
    }

    func testReleaseAlwaysTurnsItOffSoDuckingEndsWithTheSession() {
        let input = FakeInput()
        MicSource.applyVoiceProcessing(true, to: input)
        MicSource.releaseVoiceProcessing(input)
        XCTAssertFalse(input.isVoiceProcessingEnabled)

        let untouched = FakeInput()
        MicSource.releaseVoiceProcessing(untouched)
        XCTAssertTrue(untouched.setCalls.isEmpty, "nothing to release when it was never on")
    }

    func testEchoCancellationSettingDefaultsOff() {
        XCTAssertFalse(SettingsStore.echoCancellation(stored: nil))
        XCTAssertTrue(SettingsStore.echoCancellation(stored: true))
        XCTAssertFalse(SettingsStore.echoCancellation(stored: false))
    }
}

/// Recognizer failures that will never clear on their own must reach the
/// overlay as an error. Swallowing them showed an empty panel with no reason.
final class SpeechFailureTests: XCTestCase {
    func testDictationDisabledIsReportedWithTheSettingToChange() throws {
        let error = NSError(domain: "kLSRErrorDomain", code: 201,
                            userInfo: [NSLocalizedDescriptionKey: "Siri and Dictation are disabled"])
        let message = try XCTUnwrap(AppleSpeechEngine.blockingFailureMessage(for: error))
        XCTAssertTrue(message.contains("Dictation"), message)
        XCTAssertTrue(message.contains("System Settings"), message)
    }

    func testRoutineRecognizerEndingsAreNotReported() {
        // "No speech detected" and cancellations happen constantly between utterances.
        XCTAssertNil(AppleSpeechEngine.blockingFailureMessage(for: NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        XCTAssertNil(AppleSpeechEngine.blockingFailureMessage(for: NSError(domain: "kAFAssistantErrorDomain", code: 216)))
        XCTAssertNil(AppleSpeechEngine.blockingFailureMessage(for: NSError(domain: "kLSRErrorDomain", code: 301)))
    }
}
