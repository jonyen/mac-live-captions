import XCTest
@testable import Captions

final class MeetingDebouncerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func debouncer() -> MeetingDebouncer {
        MeetingDebouncer(startDelay: 3, endDelay: 15)
    }

    func testAMeetingStartsOnlyAfterInputStaysOnForTheStartDelay() {
        var d = debouncer()
        XCTAssertNil(d.update(active: true, now: at(0)))
        XCTAssertNil(d.update(active: true, now: at(2.9)))
        XCTAssertEqual(d.update(active: true, now: at(3)), .started)
        XCTAssertTrue(d.inMeeting)
    }

    func testABriefInputBlipNeverStartsAMeeting() {
        var d = debouncer()
        _ = d.update(active: true, now: at(0))
        XCTAssertNil(d.update(active: false, now: at(1)))
        XCTAssertNil(d.update(active: false, now: at(10)))
        XCTAssertFalse(d.inMeeting)
    }

    func testAShortDropoutDuringAMeetingDoesNotEndIt() {
        var d = debouncer()
        _ = d.update(active: true, now: at(0))
        _ = d.update(active: true, now: at(3))
        XCTAssertNil(d.update(active: false, now: at(10)))
        XCTAssertNil(d.update(active: true, now: at(20)))
        XCTAssertNil(d.update(active: true, now: at(40)))
        XCTAssertTrue(d.inMeeting)
    }

    func testTheMeetingEndsAfterInputStaysOffForTheEndDelay() {
        var d = debouncer()
        _ = d.update(active: true, now: at(0))
        _ = d.update(active: true, now: at(3))
        XCTAssertNil(d.update(active: false, now: at(10)))
        XCTAssertNil(d.update(active: false, now: at(24.9)))
        XCTAssertEqual(d.update(active: false, now: at(25)), .ended)
        XCTAssertFalse(d.inMeeting)
    }

    func testNextCheckIsWhenThePendingTransitionWouldFire() {
        var d = debouncer()
        XCTAssertNil(d.nextCheck)
        _ = d.update(active: true, now: at(0))
        XCTAssertEqual(d.nextCheck, at(3))
        _ = d.update(active: true, now: at(3))
        XCTAssertNil(d.nextCheck)
        _ = d.update(active: false, now: at(10))
        XCTAssertEqual(d.nextCheck, at(25))
    }
}

final class AutoSessionOwnershipTests: XCTestCase {
    func testAMeetingStartsCaptionsWhenNothingIsRunning() {
        var o = AutoSessionOwnership()
        XCTAssertTrue(o.meetingStarted(capturing: false))
        XCTAssertTrue(o.meetingEnded())
    }

    func testAMeetingNeverTakesOverCaptionsTheUserStarted() {
        var o = AutoSessionOwnership()
        XCTAssertFalse(o.meetingStarted(capturing: true))
        XCTAssertFalse(o.meetingEnded(), "the user's own session must survive the meeting ending")
    }

    func testAUserStopMeansTheMeetingEndHasNothingToStop() {
        var o = AutoSessionOwnership()
        _ = o.meetingStarted(capturing: false)
        o.userStopped()
        XCTAssertFalse(o.meetingEnded())
    }

    func testTheNextMeetingStartsAgainAfterAUserStop() {
        var o = AutoSessionOwnership()
        _ = o.meetingStarted(capturing: false)
        o.userStopped()
        _ = o.meetingEnded()
        XCTAssertTrue(o.meetingStarted(capturing: false))
    }
}

final class GranolaBundleTests: XCTestCase {
    func testGranolaProcessesMatch() {
        XCTAssertTrue(GranolaWatcher.isGranola(bundleID: "com.granola.app.helper"))
        XCTAssertTrue(GranolaWatcher.isGranola(bundleID: "com.granola.app"))
    }

    func testOtherProcessesDoNot() {
        XCTAssertFalse(GranolaWatcher.isGranola(bundleID: "com.jonyen.watchcaptions.mac"))
        XCTAssertFalse(GranolaWatcher.isGranola(bundleID: nil))
    }
}
