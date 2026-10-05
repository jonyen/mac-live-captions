import XCTest
@testable import Captions

final class SettingsStoreTests: XCTestCase {
    func testCaptureSourcesAreOnUntilTheUserTurnsOneOff() {
        XCTAssertTrue(SettingsStore.captureEnabled(stored: nil))
    }

    func testAStoredOffSurvivesRelaunch() {
        XCTAssertFalse(SettingsStore.captureEnabled(stored: false))
    }

    func testAStoredOnIsKept() {
        XCTAssertTrue(SettingsStore.captureEnabled(stored: true))
    }
}
