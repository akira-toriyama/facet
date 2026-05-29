import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the inner-gap post-pass. 1200×600 with a
/// gap of 20 keeps every result integral (gap/2 = 10, /2 = 600,
/// /3 = 400, height /2 = 300) so frames compare exactly.
final class ApplyInnerGapTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 600)

    func testGapZeroIsNoOp() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600),
                 wid(2): CGRect(x: 600, y: 0, width: 600, height: 600)]
        XCTAssertEqual(applyInnerGap(f, in: screen, gap: 0), f)
    }

    func testNegativeGapIsNoOp() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600)]
        XCTAssertEqual(applyInnerGap(f, in: screen, gap: -10), f)
    }

    func testSingleWindowUntouched() {
        // Fills the rect → every edge flush with the boundary → no shrink.
        let f = [wid(1): screen]
        XCTAssertEqual(applyInnerGap(f, in: screen, gap: 20), f)
    }

    func testTwoSideBySide() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600),
                 wid(2): CGRect(x: 600, y: 0, width: 600, height: 600)]
        let g = applyInnerGap(f, in: screen, gap: 20)
        // Only the shared edge shrinks (10 each) → 20 apart; the three
        // outer edges of each window stay flush.
        XCTAssertEqual(g[wid(1)], CGRect(x: 0, y: 0, width: 590, height: 600))
        XCTAssertEqual(g[wid(2)], CGRect(x: 610, y: 0, width: 590, height: 600))
    }

    func testFourQuadrants() {
        let f = [wid(1): CGRect(x: 0,   y: 0,   width: 600, height: 300),
                 wid(2): CGRect(x: 600, y: 0,   width: 600, height: 300),
                 wid(3): CGRect(x: 0,   y: 300, width: 600, height: 300),
                 wid(4): CGRect(x: 600, y: 300, width: 600, height: 300)]
        let g = applyInnerGap(f, in: screen, gap: 20)
        // Each interior edge gives up 10; boundary edges stay flush.
        XCTAssertEqual(g[wid(1)], CGRect(x: 0,   y: 0,   width: 590, height: 290))
        XCTAssertEqual(g[wid(2)], CGRect(x: 610, y: 0,   width: 590, height: 290))
        XCTAssertEqual(g[wid(3)], CGRect(x: 0,   y: 310, width: 590, height: 290))
        XCTAssertEqual(g[wid(4)], CGRect(x: 610, y: 310, width: 590, height: 290))
    }
}

/// `effective*` clamping + `[layout]` parse for the gap config keys.
final class GapConfigTests: XCTestCase {

    func testDefaultsZero() {
        let c = FacetConfig()
        XCTAssertEqual(c.effectiveInnerGap, 0, accuracy: 0.001)
        XCTAssertEqual(c.effectiveOuterGap, 0, accuracy: 0.001)
    }

    func testClampNegativeToZero() {
        var c = FacetConfig()
        c.innerGap = -5
        c.outerGap = -50
        XCTAssertEqual(c.effectiveInnerGap, 0, accuracy: 0.001)
        XCTAssertEqual(c.effectiveOuterGap, 0, accuracy: 0.001)
    }

    func testClampLargeToCeiling() {
        var c = FacetConfig()
        c.innerGap = 9999
        c.outerGap = 9999
        XCTAssertEqual(c.effectiveInnerGap, 200, accuracy: 0.001)
        XCTAssertEqual(c.effectiveOuterGap, 200, accuracy: 0.001)
    }

    func testParseFromTOML() {
        let c = FacetConfig.from(toml: [
            "layout": ["inner-gap": .int(8), "outer-gap": .int(12)],
        ])
        XCTAssertEqual(c.effectiveInnerGap, 8, accuracy: 0.001)
        XCTAssertEqual(c.effectiveOuterGap, 12, accuracy: 0.001)
    }
}
