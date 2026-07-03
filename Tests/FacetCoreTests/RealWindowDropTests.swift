import Testing
import CoreGraphics
@testable import FacetCore

/// Pure tests for the real-window-drag resolution (枠C PR-2): which
/// window was grabbed, which it was dropped onto, and the intent zone.
/// Two side-by-side tiles on a 1600×900 screen: A = left half, B =
/// right half.
struct RealWindowDropTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let a = (id: WindowID(serverID: 1),
                     frame: CGRect(x: 0, y: 0, width: 800, height: 900))
    private let b = (id: WindowID(serverID: 2),
                     frame: CGRect(x: 800, y: 0, width: 800, height: 900))
    private var wins: [(id: WindowID, frame: CGRect)] { [a, b] }

    // MARK: - grab

    @Test func windowAtFindsContainingTile() {
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 450))
            == wid(1))
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: 1200, y: 450))
            == wid(2))
    }

    @Test func windowAtMissIsNil() {
        // Below the screen → no tile.
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 2000)) == nil)
    }

    // MARK: - grab edge band (枠C 機能2: native resize handle grabs)

    @Test func edgeGrabJustOutsideArmsNearestWindow() {
        // The native resize handle sits ON / just outside the frame edge,
        // which a plain `contains` misses. 5px outside an outer edge → that
        // window (within the 8px band).
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: -5, y: 450))
            == wid(1))
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: 1605, y: 450))
            == wid(2))
    }

    @Test func edgeGrabInGapPicksNearer() {
        // 20px inner gap: A = [0,790], B = [810,1600].
        let g = [(id: wid(1),
                  frame: CGRect(x: 0, y: 0, width: 790, height: 900)),
                 (id: wid(2),
                  frame: CGRect(x: 810, y: 0, width: 790, height: 900))]
        // 4px past A's edge (16px from B) → A; mirror → B.
        #expect(RealWindowDrop.window(g, at: CGPoint(x: 794, y: 450))
            == wid(1))
        #expect(RealWindowDrop.window(g, at: CGPoint(x: 806, y: 450))
            == wid(2))
        // Dead centre of a wide gap (>8px from either edge) → no arm.
        #expect(RealWindowDrop.window(g, at: CGPoint(x: 800, y: 450)) == nil)
    }

    @Test func grabBeyondBandIsNil() {
        // 30px below every tile → outside the 8px band → no arm.
        #expect(RealWindowDrop.window(wins, at: CGPoint(x: 400, y: 930)) == nil)
    }

    // MARK: - drop

    @Test func dropOnOtherCenterIsSwap() {
        // Drag A, drop in the center of B → swap.
        let d = RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 1200, y: 450))
        #expect(d == RealWindowDrop.Decision(
            dragged: wid(1), target: wid(2), zone: .center))
    }

    @Test func dropOnOtherEdgeIsInsert() {
        // Drag A, drop near B's right edge → insert on B's right.
        let d = RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 1580, y: 450))
        #expect(d == RealWindowDrop.Decision(
            dragged: wid(1), target: wid(2), zone: .edge(.right)))
    }

    @Test func dropOnSelfIsNil() {
        // Drop back over A itself → no decision (re-tiles in place).
        #expect(RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 400, y: 450)) == nil)
    }

    @Test func dropOnEmptyIsNil() {
        #expect(RealWindowDrop.drop(wins, dragged: wid(1),
                                    at: CGPoint(x: 400, y: 2000)) == nil)
    }
}
