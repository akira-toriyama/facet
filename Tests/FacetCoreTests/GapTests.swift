import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for the inner-gap post-pass. 1200×600 with a
/// gap of 20 keeps every result integral (gap/2 = 10, /2 = 600,
/// /3 = 400, height /2 = 300) so frames compare exactly.
struct ApplyInnerGapTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 600)

    @Test func gapZeroIsNoOp() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600),
                 wid(2): CGRect(x: 600, y: 0, width: 600, height: 600)]
        #expect(applyInnerGap(f, in: screen, gap: 0) == f)
    }

    @Test func negativeGapIsNoOp() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600)]
        #expect(applyInnerGap(f, in: screen, gap: -10) == f)
    }

    @Test func singleWindowUntouched() {
        // Fills the rect → every edge flush with the boundary → no shrink.
        let f = [wid(1): screen]
        #expect(applyInnerGap(f, in: screen, gap: 20) == f)
    }

    @Test func twoSideBySide() {
        let f = [wid(1): CGRect(x: 0, y: 0, width: 600, height: 600),
                 wid(2): CGRect(x: 600, y: 0, width: 600, height: 600)]
        let g = applyInnerGap(f, in: screen, gap: 20)
        // Only the shared edge shrinks (10 each) → 20 apart; the three
        // outer edges of each window stay flush.
        #expect(g[wid(1)] == CGRect(x: 0, y: 0, width: 590, height: 600))
        #expect(g[wid(2)] == CGRect(x: 610, y: 0, width: 590, height: 600))
    }

    @Test func fourQuadrants() {
        let f = [wid(1): CGRect(x: 0,   y: 0,   width: 600, height: 300),
                 wid(2): CGRect(x: 600, y: 0,   width: 600, height: 300),
                 wid(3): CGRect(x: 0,   y: 300, width: 600, height: 300),
                 wid(4): CGRect(x: 600, y: 300, width: 600, height: 300)]
        let g = applyInnerGap(f, in: screen, gap: 20)
        // Each interior edge gives up 10; boundary edges stay flush.
        #expect(g[wid(1)] == CGRect(x: 0,   y: 0,   width: 590, height: 290))
        #expect(g[wid(2)] == CGRect(x: 610, y: 0,   width: 590, height: 290))
        #expect(g[wid(3)] == CGRect(x: 0,   y: 310, width: 590, height: 290))
        #expect(g[wid(4)] == CGRect(x: 610, y: 310, width: 590, height: 290))
    }
}

/// `effective*` clamping + `[layout]` parse for the gap config keys,
/// including per-edge outer-gap fallback to the all-edges default.
struct GapConfigTests {

    @Test func defaultsZero() {
        let c = FacetConfig()
        #expect(abs(c.effectiveInnerGap - 0) < 0.001)
        #expect(abs(c.effectiveOuterGapTop - 0) < 0.001)
        #expect(abs(c.effectiveOuterGapBottom - 0) < 0.001)
        #expect(abs(c.effectiveOuterGapLeft - 0) < 0.001)
        #expect(abs(c.effectiveOuterGapRight - 0) < 0.001)
    }

    @Test func clampNegativeToZero() {
        var c = FacetConfig()
        c.innerGap = -5
        c.outerGap = -50
        #expect(abs(c.effectiveInnerGap - 0) < 0.001)
        #expect(abs(c.effectiveOuterGapLeft - 0) < 0.001)
    }

    @Test func clampLargeToCeiling() {
        var c = FacetConfig()
        c.innerGap = 9999
        c.outerGap = 9999
        #expect(abs(c.effectiveInnerGap - 1000) < 0.001)
        #expect(abs(c.effectiveOuterGapTop - 1000) < 0.001)
        #expect(abs(c.effectiveOuterGapRight - 1000) < 0.001)
    }

    @Test func outerGapDefaultsAllEdges() {
        var c = FacetConfig()
        c.outerGap = 10
        #expect(abs(c.effectiveOuterGapTop - 10) < 0.001)
        #expect(abs(c.effectiveOuterGapBottom - 10) < 0.001)
        #expect(abs(c.effectiveOuterGapLeft - 10) < 0.001)
        #expect(abs(c.effectiveOuterGapRight - 10) < 0.001)
    }

    @Test func perEdgeOverridesDefault() {
        var c = FacetConfig()
        c.outerGap = 10
        c.outerGapLeft = 30
        #expect(abs(c.effectiveOuterGapLeft - 30) < 0.001)
        #expect(abs(c.effectiveOuterGapTop - 10) < 0.001)
        #expect(abs(c.effectiveOuterGapRight - 10) < 0.001)
    }

    @Test func parseFromTOML() {
        let c = FacetConfig.from(toml: [
            "layout": ["inner-gap": .int(8), "outer-gap": .int(12),
                       "outer-gap-left": .int(24)],
        ])
        #expect(abs(c.effectiveInnerGap - 8) < 0.001)
        #expect(abs(c.effectiveOuterGapTop - 12) < 0.001)
        #expect(abs(c.effectiveOuterGapLeft - 24) < 0.001)
    }

    // MARK: - Smart gaps

    @Test func smartGapsDefaultsOff() {
        #expect(!FacetConfig().effectiveSmartGaps,
                "smart gaps must be opt-in (off by default)")
    }

    @Test func smartGapsParsedFromTOML() {
        let on = FacetConfig.from(toml: ["layout": ["smart-gaps": .bool(true)]])
        #expect(on.effectiveSmartGaps)
        let off = FacetConfig.from(toml: ["layout": ["smart-gaps": .bool(false)]])
        #expect(!off.effectiveSmartGaps)
    }
}
