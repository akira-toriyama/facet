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

    // MARK: - grab edge band (枠C 機能2: native resize handle grabs)

    func testEdgeGrabJustOutsideArmsNearestWindow() {
        // The native resize handle sits ON / just outside the frame edge,
        // which a plain `contains` misses. 5px outside an outer edge → that
        // window (within the 8px band).
        XCTAssertEqual(RealWindowDrop.window(wins, at: CGPoint(x: -5, y: 450)),
                       wid(1))
        XCTAssertEqual(RealWindowDrop.window(wins, at: CGPoint(x: 1605, y: 450)),
                       wid(2))
    }

    func testEdgeGrabInGapPicksNearer() {
        // 20px inner gap: A = [0,790], B = [810,1600].
        let g = [(id: wid(1),
                  frame: CGRect(x: 0, y: 0, width: 790, height: 900)),
                 (id: wid(2),
                  frame: CGRect(x: 810, y: 0, width: 790, height: 900))]
        // 4px past A's edge (16px from B) → A; mirror → B.
        XCTAssertEqual(RealWindowDrop.window(g, at: CGPoint(x: 794, y: 450)),
                       wid(1))
        XCTAssertEqual(RealWindowDrop.window(g, at: CGPoint(x: 806, y: 450)),
                       wid(2))
        // Dead centre of a wide gap (>8px from either edge) → no arm.
        XCTAssertNil(RealWindowDrop.window(g, at: CGPoint(x: 800, y: 450)))
    }

    func testGrabBeyondBandIsNil() {
        // 30px below every tile → outside the 8px band → no arm.
        XCTAssertNil(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 930)))
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
