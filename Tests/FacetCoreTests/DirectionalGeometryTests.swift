import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for directional focus/move neighbour-finding (②). Frames
/// are AX-style (y DOWN: north = smaller y). A simple 2×2 grid of
/// 100×100 cells on a 200×200 screen keeps the geometry obvious:
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

    func testCardinalNeighboursFromTopLeft() {
        let rest = others([(2, tr), (3, bl), (4, br)])
        // east of TL = TR(2); south of TL = BL(3).
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .east), wid(2))
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .south), wid(3))
        // north / west of TL = nothing → edge no-op.
        XCTAssertNil(nearestWindow(to: tl, among: rest, direction: .north))
        XCTAssertNil(nearestWindow(to: tl, among: rest, direction: .west))
    }

    func testCardinalNeighboursFromBottomRight() {
        let rest = others([(1, tl), (2, tr), (3, bl)])
        // north of BR = TR(2); west of BR = BL(3).
        XCTAssertEqual(nearestWindow(to: br, among: rest, direction: .north), wid(2))
        XCTAssertEqual(nearestWindow(to: br, among: rest, direction: .west), wid(3))
        XCTAssertNil(nearestWindow(to: br, among: rest, direction: .south))
        XCTAssertNil(nearestWindow(to: br, among: rest, direction: .east))
    }

    func testAlignedBeatsDiagonal() {
        // Going east from TL with BOTH the aligned TR and the diagonal BR
        // present: the squarely-aligned TR wins (perp penalty).
        let rest = others([(2, tr), (4, br)])
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .east), wid(2))
    }

    func testNearerOfTwoInLineWins() {
        // Two windows due east; the closer one wins.
        let near = CGRect(x: 100, y: 0, width: 100, height: 100)
        let far  = CGRect(x: 400, y: 0, width: 100, height: 100)
        let rest = others([(2, far), (3, near)])
        XCTAssertEqual(nearestWindow(to: tl, among: rest, direction: .east), wid(3))
    }

    func testEmptyAndSelfOnly() {
        XCTAssertNil(nearestWindow(to: tl, among: [], direction: .east))
    }

    func testDirectionRawValuesMatchCLI() {
        XCTAssertEqual(CardinalDirection(rawValue: "north"), .north)
        XCTAssertEqual(CardinalDirection(rawValue: "east"), .east)
        XCTAssertEqual(CardinalDirection(rawValue: "south"), .south)
        XCTAssertEqual(CardinalDirection(rawValue: "west"), .west)
        XCTAssertNil(CardinalDirection(rawValue: "up"))
    }
}
