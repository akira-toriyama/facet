import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for the real-window-drag resolution (枠C PR-2): which
/// window was grabbed, which it was dropped onto, and the intent zone.
/// Two side-by-side tiles on a 1600×900 screen: A = left half, B =
/// right half.
final class RealWindowDropTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let a = (id: WindowID(serverID: 1),
                     frame: CGRect(x: 0, y: 0, width: 800, height: 900))
    private let b = (id: WindowID(serverID: 2),
                     frame: CGRect(x: 800, y: 0, width: 800, height: 900))
    private lazy var wins = [a, b]

    // MARK: - grab

    func testWindowAtFindsContainingTile() {
        XCTAssertEqual(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 450)),
                       wid(1))
        XCTAssertEqual(RealWindowDrop.window(wins, at: CGPoint(x: 1200, y: 450)),
                       wid(2))
    }

    func testWindowAtMissIsNil() {
        // Below the screen → no tile.
        XCTAssertNil(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 2000)))
    }

    // MARK: - drop

    func testDropOnOtherCenterIsSwap() {
        // Drag A, drop in the center of B → swap.
        let d = RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 1200, y: 450))
        XCTAssertEqual(d, RealWindowDrop.Decision(
            dragged: wid(1), target: wid(2), zone: .center))
    }

    func testDropOnOtherEdgeIsInsert() {
        // Drag A, drop near B's right edge → insert on B's right.
        let d = RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 1580, y: 450))
        XCTAssertEqual(d, RealWindowDrop.Decision(
            dragged: wid(1), target: wid(2), zone: .edge(.right)))
    }

    func testDropOnSelfIsNil() {
        // Drop back over A itself → no decision (re-tiles in place).
        XCTAssertNil(RealWindowDrop.drop(wins, dragged: wid(1),
                                         at: CGPoint(x: 400, y: 450)))
    }

    func testDropOnEmptyIsNil() {
        XCTAssertNil(RealWindowDrop.drop(wins, dragged: wid(1),
                                         at: CGPoint(x: 400, y: 2000)))
    }
}
