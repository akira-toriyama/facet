import XCTest
import CoreGraphics
@testable import FacetCore

/// Pure-logic tests for the workspace-switch slide (枠 E). The clock +
/// AX writes live in the adapter; only the easing + interpolation are
/// testable here. Accuracy literals are non-Optional FloatingPoint so
/// these compile under CI's XCTest (CLT-only setups can't run them).
final class SlideAnimationTests: XCTestCase {

    // MARK: SlideCurve.easeOutCubic

    func testEaseOutCubicEndpoints() {
        XCTAssertEqual(SlideCurve.easeOutCubic(0), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeOutCubic(1), 1, accuracy: 0.0001)
    }

    func testEaseOutCubicClampsOutOfRange() {
        XCTAssertEqual(SlideCurve.easeOutCubic(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeOutCubic(2), 1, accuracy: 0.0001)
    }

    func testEaseOutCubicLeadsLinearEarly() {
        // Ease-OUT starts fast: the eased value sits above the diagonal.
        XCTAssertGreaterThan(SlideCurve.easeOutCubic(0.25), 0.25)
        XCTAssertGreaterThan(SlideCurve.easeOutCubic(0.5), 0.5)
    }

    func testEaseOutCubicMonotonic() {
        var prev = SlideCurve.easeOutCubic(0)
        for i in 1...20 {
            let v = SlideCurve.easeOutCubic(Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
    }

    // MARK: SlideCurve.easeOutQuint

    func testEaseOutQuintEndpointsAndClamp() {
        XCTAssertEqual(SlideCurve.easeOutQuint(0), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeOutQuint(1), 1, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeOutQuint(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeOutQuint(2), 1, accuracy: 0.0001)
    }

    func testEaseOutQuintMonotonic() {
        var prev = SlideCurve.easeOutQuint(0)
        for i in 1...20 {
            let v = SlideCurve.easeOutQuint(Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
    }

    func testEaseOutQuintSnappierThanCubic() {
        // "キレ": quint settles faster, so it sits above cubic mid-tween.
        for i in 1...19 {
            let t = Double(i) / 20
            XCTAssertGreaterThan(SlideCurve.easeOutQuint(t),
                                 SlideCurve.easeOutCubic(t))
        }
    }

    // MARK: SlideCurve.easeInOutCubic

    func testEaseInOutCubicEndpointsAndClamp() {
        XCTAssertEqual(SlideCurve.easeInOutCubic(0), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeInOutCubic(1), 1, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeInOutCubic(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.easeInOutCubic(2), 1, accuracy: 0.0001)
    }

    func testEaseInOutCubicSymmetricMidpoint() {
        // Eased at both ends → passes exactly through the centre.
        XCTAssertEqual(SlideCurve.easeInOutCubic(0.5), 0.5, accuracy: 0.0001)
    }

    func testEaseInOutCubicEasesInThenOut() {
        // First half below the diagonal (slow start), second half above.
        XCTAssertLessThan(SlideCurve.easeInOutCubic(0.25), 0.25)
        XCTAssertGreaterThan(SlideCurve.easeInOutCubic(0.75), 0.75)
    }

    func testEaseInOutCubicMonotonic() {
        var prev = SlideCurve.easeInOutCubic(0)
        for i in 1...20 {
            let v = SlideCurve.easeInOutCubic(Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
    }

    // MARK: SlideCurve.spring

    func testSpringEndpointsAndClamp() {
        XCTAssertEqual(SlideCurve.spring(0), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.spring(1), 1, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.spring(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(SlideCurve.spring(2), 1, accuracy: 0.0001)
    }

    func testSpringOvershootsAboveOne() {
        // Underdamped: the response rises past 1 before settling — the
        // "弾む高級感" bounce. Scan the whole tween for the peak.
        var peak = 0.0
        for i in 0...100 { peak = max(peak, SlideCurve.spring(Double(i) / 100)) }
        XCTAssertGreaterThan(peak, 1.0,
                             "underdamped spring should overshoot above 1")
    }

    // MARK: WindowSlide.frame

    func testWindowSlideTranslationKeepsSize() {
        // Pure translation (WS-switch slide): size constant, origin
        // tweens, resizes == false so the adapter skips setSize.
        let move = WindowSlide(id: WindowID(serverID: 1),
                               from: CGRect(x: 100, y: 50, width: 300, height: 200),
                               to: CGRect(x: 700, y: 50, width: 300, height: 200))
        XCTAssertFalse(move.resizes)
        XCTAssertEqual(move.frame(atEased: 0).minX, 100, accuracy: 0.0001)
        XCTAssertEqual(move.frame(atEased: 1).minX, 700, accuracy: 0.0001)
        XCTAssertEqual(move.frame(atEased: 0.5).minX, 400, accuracy: 0.0001)
        XCTAssertEqual(move.frame(atEased: 0.5).width, 300, accuracy: 0.0001)
    }

    func testWindowSlideResizeInterpolatesSize() {
        // Retile / layout-change: size tweens too; resizes == true.
        let grow = WindowSlide(id: WindowID(serverID: 2),
                               from: CGRect(x: 0, y: 0, width: 200, height: 100),
                               to: CGRect(x: 0, y: 0, width: 600, height: 500))
        XCTAssertTrue(grow.resizes)
        XCTAssertEqual(grow.frame(atEased: 0.5).width, 400, accuracy: 0.0001)
        XCTAssertEqual(grow.frame(atEased: 0.5).height, 300, accuracy: 0.0001)
        XCTAssertEqual(grow.frame(atEased: 1).width, 600, accuracy: 0.0001)
    }

    // MARK: FacetConfig [animation]

    func testAnimationDefaultsOff() {
        // Opt-in: a fresh install animates nothing until enabled = true.
        let c = FacetConfig.from(toml: [:])
        XCTAssertFalse(c.effectiveAnimationsEnabled)
    }

    func testAnimationEnabledParsed() {
        let on = FacetConfig.from(toml: ["animation": ["enabled": .bool(true)]])
        XCTAssertTrue(on.effectiveAnimationsEnabled)
        let off = FacetConfig.from(toml: ["animation": ["enabled": .bool(false)]])
        XCTAssertFalse(off.effectiveAnimationsEnabled)
    }

    func testAnimationCurveDefaultsToCubic() {
        XCTAssertEqual(FacetConfig.from(toml: [:]).effectiveAnimationCurve, "cubic")
    }

    func testAnimationCurveParsedAndClamped() {
        func curve(_ s: String) -> String {
            FacetConfig.from(toml: ["animation": ["curve": .string(s)]])
                .effectiveAnimationCurve
        }
        XCTAssertEqual(curve("spring"), "spring")
        XCTAssertEqual(curve("RANDOM"), "random")   // case-insensitive
        XCTAssertEqual(curve("bogus"), "cubic")     // unknown → default
        XCTAssertEqual(curve("none"), "cubic")      // "none" dropped → default
    }

    func testAnimationEventDrivenFollowsMasterByDefault() {
        // Sub-key unset: tracks master `enabled`.
        let off = FacetConfig.from(toml: [:])
        XCTAssertFalse(off.effectiveAnimationEventDriven)
        let on = FacetConfig.from(toml: ["animation": ["enabled": .bool(true)]])
        XCTAssertTrue(on.effectiveAnimationEventDriven)
    }

    func testAnimationEventDrivenOptOut() {
        // Master on + sub-key off → master animations work but
        // background open/close stays a snap.
        let c = FacetConfig.from(toml: ["animation": [
            "enabled": .bool(true),
            "event-driven": .bool(false),
        ]])
        XCTAssertTrue(c.effectiveAnimationsEnabled)
        XCTAssertFalse(c.effectiveAnimationEventDriven)
    }

    func testAnimationEventDrivenCannotOverrideMasterOff() {
        // Sub-key alone can't turn animation on — master is the floor.
        let c = FacetConfig.from(toml: ["animation": [
            "enabled": .bool(false),
            "event-driven": .bool(true),
        ]])
        XCTAssertFalse(c.effectiveAnimationEventDriven)
    }
}
