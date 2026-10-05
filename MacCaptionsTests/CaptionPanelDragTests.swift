import XCTest
@testable import Captions

final class CaptionPanelDragTests: XCTestCase {
    /// SwiftUI translation grows downward; AppKit window origins grow upward.
    func testDragMovesTheWindowWithTheCursor() {
        let moved = CaptionPanelController.draggedOrigin(
            from: NSPoint(x: 100, y: 200), translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(moved.x, 130)
        XCTAssertEqual(moved.y, 160)
    }

    func testDragUpRaisesTheWindow() {
        let moved = CaptionPanelController.draggedOrigin(
            from: NSPoint(x: 0, y: 0), translation: CGSize(width: -5, height: -25))
        XCTAssertEqual(moved.x, -5)
        XCTAssertEqual(moved.y, 25)
    }
}
