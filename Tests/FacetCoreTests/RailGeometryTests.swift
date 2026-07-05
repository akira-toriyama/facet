import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for the rail's edge-neutral band split,
/// active-centred carousel offsets (2-b), and responsive
/// (short-edge-scaled) pads. A clean 1600×1000 bounds keeps the
/// arithmetic exact: thickness 300, outerPad 40, heroGap 16.
struct RailGeometryTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let t: CGFloat = 300, pad: CGFloat = 40, gap: CGFloat = 16

    private func bands(_ edge: RailEdge) -> (strip: CGRect, hero: CGRect) {
        railBands(in: bounds, edge: edge, thickness: t, outerPad: pad, heroGap: gap)
    }

    @Test func axisForEdges() {
        #expect(RailEdge.top.axis == .horizontal)
        #expect(RailEdge.bottom.axis == .horizontal)
        #expect(RailEdge.left.axis == .vertical)
        #expect(RailEdge.right.axis == .vertical)
    }

    @Test func bottomBands() {
        let (s, h) = bands(.bottom)
        #expect(s == CGRect(x: 0, y: 700, width: 1600, height: 300))
        #expect(h == CGRect(x: 40, y: 40, width: 1520, height: 644))
    }

    @Test func topBands() {
        let (s, h) = bands(.top)
        #expect(s == CGRect(x: 0, y: 0, width: 1600, height: 300))
        #expect(h == CGRect(x: 40, y: 316, width: 1520, height: 644))
    }

    @Test func leftBands() {
        let (s, h) = bands(.left)
        #expect(s == CGRect(x: 0, y: 0, width: 300, height: 1000))
        #expect(h == CGRect(x: 316, y: 40, width: 1244, height: 920))
    }

    @Test func rightBands() {
        let (s, h) = bands(.right)
        #expect(s == CGRect(x: 1300, y: 0, width: 300, height: 1000))
        #expect(h == CGRect(x: 40, y: 40, width: 1244, height: 920))
    }

    @Test func stripsAreOppositeMirrors() {
        // Opposite edges put the strip on opposite sides, same size.
        #expect(bands(.bottom).strip.height == bands(.top).strip.height)
        #expect(bands(.left).strip.width == bands(.right).strip.width)
        #expect(bands(.bottom).strip.minY == 700)
        #expect(bands(.top).strip.minY == 0)
    }

    @Test func thicknessClampedToBounds() {
        // Over-thick request is clamped so the strip never exceeds bounds.
        let (s, _) = railBands(in: bounds, edge: .bottom, thickness: 5000,
                               outerPad: pad, heroGap: gap)
        #expect(s.height == 1000)
        #expect(s.minY == 0)
    }

    /// When the strip clamps to the full cross-axis extent the hero's
    /// remaining height goes negative and `clampedHero`'s `max(0, h)`
    /// collapses it to a valid zero-height rect — never a negative-
    /// dimension CGRect handed to AppKit. Regression pins the collapse
    /// guard the sibling clamp test discards with `_`.
    @Test func heroCollapsesToZeroWhenStripFillsBounds() {
        let (_, h) = railBands(in: bounds, edge: .bottom, thickness: 5000,
                               outerPad: pad, heroGap: gap)
        // t=min(5000,1000)=1000 ⇒ raw hero height (1000-1000-16)-40=-56 → 0.
        #expect(h == CGRect(x: 40, y: 40, width: 1520, height: 0))
    }

    // MARK: - Carousel offsets (2-b)

    /// The worked example: 5 WS, ws5 (pos 4) selected → ws3 −2 … ws2 +2,
    /// i.e. displayed `[ws3][ws4][ws5][ws1][ws2]`.
    @Test func carouselWorkedExample() {
        let off = railCarouselOffsets(count: 5, selectedPos: 4)
        // off[p] is position p's slot offset from centre.
        #expect(off[2] == -2)   // ws3
        #expect(off[3] == -1)   // ws4
        #expect(off[4] == 0)    // ws5 (selected, centre)
        #expect(off[0] == 1)    // ws1 (wraps to the right)
        #expect(off[1] == 2)    // ws2
    }

    @Test func carouselSelectedAlwaysAtZero() {
        for count in 1...9 {
            for sel in 0..<count {
                let off = railCarouselOffsets(count: count, selectedPos: sel)
                #expect(off[sel] == 0, "selected must be centre (count \(count), sel \(sel))")
                // Offsets are a contiguous run around 0 (a permutation of
                // a centred range), so each value is unique.
                #expect(Set(off).count == count, "offsets must be distinct")
            }
        }
    }

    @Test func carouselEvenBiasesRight() {
        // count 4, selected pos 0 → 2 cells left of centre, 1 right
        // (floor(4/2)=2 ⇒ selected sits one slot right of dead-centre).
        let off = railCarouselOffsets(count: 4, selectedPos: 0)
        #expect(off[0] == 0)
        #expect(off.filter { $0 < 0 }.count == 2)
        #expect(off.filter { $0 > 0 }.count == 1)
    }

    @Test func carouselWrapsBothSides() {
        // count 5, selected centre pos 2 → symmetric −2…+2.
        #expect(railCarouselOffsets(count: 5, selectedPos: 2).sorted() == [-2, -1, 0, 1, 2])
    }

    @Test func carouselEmpty() {
        #expect(railCarouselOffsets(count: 0, selectedPos: 0) == [])
    }

    /// A large out-of-range `selectedPos` (>= count) is normalized into
    /// range via `((selectedPos % count) + count) % count`, centring exactly
    /// like the equivalent in-range position. Regression pins that the
    /// normalization is actually applied: dropping it (`p0 = selectedPos`)
    /// drives the offset map's dividend negative for a large position and
    /// mis-places every cell. A LARGE value is required — a small overflow
    /// like 7 leaves the dividend non-negative, and a bare single `% count`
    /// is indistinguishable here (the offset map's own `+ count` folds a
    /// negative remainder), so only removing normalization entirely at a
    /// large position is observable.
    @Test func carouselNormalizesLargeOutOfRangeSelectedPos() {
        // 12 → (12%5+5)%5 = 2 → same centring as selectedPos 2.
        // (regressed p0=12 would give [-2,-6,-5,-4,-3].)
        #expect(railCarouselOffsets(count: 5, selectedPos: 12) == [-2, -1, 0, 1, 2])
        // 13 → 3 → same as selectedPos 3. (regressed p0=13 → [-3,-2,-6,-5,-4].)
        #expect(railCarouselOffsets(count: 5, selectedPos: 13) == [2, -2, -1, 0, 1])
    }

    // MARK: - Responsive sizing (orientation- & display-size-aware)

    @Test func scaledPadsFromShortEdge() {
        // 1600×1000 → short edge 1000; each pad is its fraction of that.
        let p = railScaledPads(screen: CGSize(width: 1600, height: 1000),
                               edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                               outerFrac: 0.035)
        #expect(p.edgeFloat == 35)
        #expect(p.heroGap == 50)
        #expect(p.outer == 35)
    }

    @Test func scaledPadsOrientationStable() {
        // Rotating the display (swap w/h) keeps the short edge → same pads.
        let land = railScaledPads(screen: CGSize(width: 1600, height: 1000),
                                  edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                                  outerFrac: 0.035)
        let port = railScaledPads(screen: CGSize(width: 1000, height: 1600),
                                  edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                                  outerFrac: 0.035)
        #expect(land.edgeFloat == port.edgeFloat)
        #expect(land.heroGap == port.heroGap)
        #expect(land.outer == port.outer)
    }
}
