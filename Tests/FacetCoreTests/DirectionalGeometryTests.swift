import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for directional focus/move neighbour-finding (②). Frames
/// are AX-style (y DOWN: up = smaller y). A simple 2×2 grid of 100×100
/// cells on a 200×200 screen keeps the geometry obvious:
///   id 1 = top-left, 2 = top-right, 3 = bottom-left, 4 = bottom-right.
final class DirectionalGeometryTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let tl = CGRect(x: 0,   y: 0,   width: 100, height: 100)
    private let tr = CGRect(x: 100, y: 0,   width: 100, height: 100)
    private let bl = CGRect(x: 0,   y: 100, width: 100, height: 100)
    private let br = CGRect(x: 100, y: 100, width: 100, height: 100)

    private func others(_ pairs: [(Int, CGRect)]) -> [(id: WindowID, frame: CGRect)] {
        pairs.map { (id: wid($0.0), frame: $0.1) }
    }

    func testNeighboursFromTopLeft() {
        let rest = others([(2, tr), (3, bl), (4, br)])
        // right of TL = TR(2); down from TL = BL(3).
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .right), wid(2))
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .down), wid(3))
        // up / left of TL = nothing → edge no-op.
        XCTAssertNil(nearestWindow(to: tl, among: rest, direction: .up))
        XCTAssertNil(nearestWindow(to: tl, among: rest, direction: .left))
    }

    func testNeighboursFromBottomRight() {
        let rest = others([(1, tl), (2, tr), (3, bl)])
        // up from BR = TR(2); left of BR = BL(3).
        XCTAssertEqual(nearestWindow(to: br, among: rest, direction: .up), wid(2))
        XCTAssertEqual(nearestWindow(to: br, among: rest, direction: .left), wid(3))
        XCTAssertNil(nearestWindow(to: br, among: rest, direction: .down))
        XCTAssertNil(nearestWindow(to: br, among: rest, direction: .right))
    }

    func testAlignedBeatsDiagonal() {
        // Going right from TL with BOTH the aligned TR and the diagonal
        // BR present: the squarely-aligned TR wins (perp penalty).
        let rest = others([(2, tr), (4, br)])
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .right), wid(2))
    }

    func testNearerOfTwoInLineWins() {
        // Two windows due right; the closer one wins.
        let near = CGRect(x: 100, y: 0, width: 100, height: 100)
        let far  = CGRect(x: 400, y: 0, width: 100, height: 100)
        let rest = others([(2, far), (3, near)])
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .right), wid(3))
    }

    func testEmpty() {
        XCTAssertNil(nearestWindow(to: tl, among: [], direction: .right))
    }

    func testDirectionRawValuesMatchCLI() {
        XCTAssertEqual(Direction(rawValue: "up"), .up)
        XCTAssertEqual(Direction(rawValue: "down"), .down)
        XCTAssertEqual(Direction(rawValue: "left"), .left)
        XCTAssertEqual(Direction(rawValue: "right"), .right)
        XCTAssertNil(Direction(rawValue: "north"))
    }
}
