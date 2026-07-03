import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for directional focus/move neighbour-finding (②). Frames
/// are AX-style (y DOWN: up = smaller y). A simple 2×2 grid of 100×100
/// cells on a 200×200 screen keeps the geometry obvious:
///   id 1 = top-left, 2 = top-right, 3 = bottom-left, 4 = bottom-right.
struct DirectionalGeometryTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let tl = CGRect(x: 0,   y: 0,   width: 100, height: 100)
    private let tr = CGRect(x: 100, y: 0,   width: 100, height: 100)
    private let bl = CGRect(x: 0,   y: 100, width: 100, height: 100)
    private let br = CGRect(x: 100, y: 100, width: 100, height: 100)

    private func others(_ pairs: [(Int, CGRect)]) -> [(id: WindowID, frame: CGRect)] {
        pairs.map { (id: wid($0.0), frame: $0.1) }
    }

    @Test func neighboursFromTopLeft() {
        let rest = others([(2, tr), (3, bl), (4, br)])
        // right of TL = TR(2); down from TL = BL(3).
        #expect(nearestWindow(to: tl, among: rest, direction: .right) == wid(2))
        #expect(nearestWindow(to: tl, among: rest, direction: .down) == wid(3))
        // up / left of TL = nothing → edge no-op.
        #expect(nearestWindow(to: tl, among: rest, direction: .up) == nil)
        #expect(nearestWindow(to: tl, among: rest, direction: .left) == nil)
    }

    @Test func neighboursFromBottomRight() {
        let rest = others([(1, tl), (2, tr), (3, bl)])
        // up from BR = TR(2); left of BR = BL(3).
        #expect(nearestWindow(to: br, among: rest, direction: .up) == wid(2))
        #expect(nearestWindow(to: br, among: rest, direction: .left) == wid(3))
        #expect(nearestWindow(to: br, among: rest, direction: .down) == nil)
        #expect(nearestWindow(to: br, among: rest, direction: .right) == nil)
    }

    @Test func alignedBeatsDiagonal() {
        // Going right from TL with BOTH the aligned TR and the diagonal
        // BR present: the squarely-aligned TR wins (perp penalty).
        let rest = others([(2, tr), (4, br)])
        #expect(nearestWindow(to: tl, among: rest, direction: .right) == wid(2))
    }

    @Test func nearerOfTwoInLineWins() {
        // Two windows due right; the closer one wins.
        let near = CGRect(x: 100, y: 0, width: 100, height: 100)
        let far  = CGRect(x: 400, y: 0, width: 100, height: 100)
        let rest = others([(2, far), (3, near)])
        #expect(nearestWindow(to: tl, among: rest, direction: .right) == wid(3))
    }

    @Test func empty() {
        #expect(nearestWindow(to: tl, among: [], direction: .right) == nil)
    }

    @Test func directionRawValuesMatchCLI() {
        #expect(Direction(rawValue: "up") == .up)
        #expect(Direction(rawValue: "down") == .down)
        #expect(Direction(rawValue: "left") == .left)
        #expect(Direction(rawValue: "right") == .right)
        #expect(Direction(rawValue: "north") == nil)
    }
}
