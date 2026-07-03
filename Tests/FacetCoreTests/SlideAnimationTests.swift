import Testing
import CoreGraphics
@testable import FacetCore

/// Pure-logic tests for the workspace-switch slide (枠 E). The clock +
/// AX writes live in the adapter; only the easing + interpolation are
/// testable here. Accuracy literals are non-Optional FloatingPoint so
/// these compile under CI's XCTest (CLT-only setups can't run them).
struct SlideAnimationTests {

    // MARK: SlideCurve.easeOutCubic

    @Test func easeOutCubicEndpoints() {
        #expect(abs(SlideCurve.easeOutCubic(0) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeOutCubic(1) - 1) < 0.0001)
    }

    @Test func easeOutCubicClampsOutOfRange() {
        #expect(abs(SlideCurve.easeOutCubic(-1) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeOutCubic(2) - 1) < 0.0001)
    }

    @Test func easeOutCubicLeadsLinearEarly() {
        // Ease-OUT starts fast: the eased value sits above the diagonal.
        #expect(SlideCurve.easeOutCubic(0.25) > 0.25)
        #expect(SlideCurve.easeOutCubic(0.5) > 0.5)
    }

    @Test func easeOutCubicMonotonic() {
        var prev = SlideCurve.easeOutCubic(0)
        for i in 1...20 {
            let v = SlideCurve.easeOutCubic(Double(i) / 20)
            #expect(v >= prev)
            prev = v
        }
    }

    // MARK: SlideCurve.easeOutQuint

    @Test func easeOutQuintEndpointsAndClamp() {
        #expect(abs(SlideCurve.easeOutQuint(0) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeOutQuint(1) - 1) < 0.0001)
        #expect(abs(SlideCurve.easeOutQuint(-1) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeOutQuint(2) - 1) < 0.0001)
    }

    @Test func easeOutQuintMonotonic() {
        var prev = SlideCurve.easeOutQuint(0)
        for i in 1...20 {
            let v = SlideCurve.easeOutQuint(Double(i) / 20)
            #expect(v >= prev)
            prev = v
        }
    }

    @Test func easeOutQuintSnappierThanCubic() {
        // "キレ": quint settles faster, so it sits above cubic mid-tween.
        for i in 1...19 {
            let t = Double(i) / 20
            #expect(SlideCurve.easeOutQuint(t) >
                                 SlideCurve.easeOutCubic(t))
        }
    }

    // MARK: SlideCurve.easeInOutCubic

    @Test func easeInOutCubicEndpointsAndClamp() {
        #expect(abs(SlideCurve.easeInOutCubic(0) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeInOutCubic(1) - 1) < 0.0001)
        #expect(abs(SlideCurve.easeInOutCubic(-1) - 0) < 0.0001)
        #expect(abs(SlideCurve.easeInOutCubic(2) - 1) < 0.0001)
    }

    @Test func easeInOutCubicSymmetricMidpoint() {
        // Eased at both ends → passes exactly through the centre.
        #expect(abs(SlideCurve.easeInOutCubic(0.5) - 0.5) < 0.0001)
    }

    @Test func easeInOutCubicEasesInThenOut() {
        // First half below the diagonal (slow start), second half above.
        #expect(SlideCurve.easeInOutCubic(0.25) < 0.25)
        #expect(SlideCurve.easeInOutCubic(0.75) > 0.75)
    }

    @Test func easeInOutCubicMonotonic() {
        var prev = SlideCurve.easeInOutCubic(0)
        for i in 1...20 {
            let v = SlideCurve.easeInOutCubic(Double(i) / 20)
            #expect(v >= prev)
            prev = v
        }
    }

    // MARK: SlideCurve.spring

    @Test func springEndpointsAndClamp() {
        #expect(abs(SlideCurve.spring(0) - 0) < 0.0001)
        #expect(abs(SlideCurve.spring(1) - 1) < 0.0001)
        #expect(abs(SlideCurve.spring(-1) - 0) < 0.0001)
        #expect(abs(SlideCurve.spring(2) - 1) < 0.0001)
    }

    @Test func springOvershootsAboveOne() {
        // Underdamped: the response rises past 1 before settling — the
        // "弾む高級感" bounce. Scan the whole tween for the peak.
        var peak = 0.0
        for i in 0...100 { peak = max(peak, SlideCurve.spring(Double(i) / 100)) }
        #expect(peak > 1.0,
                             "underdamped spring should overshoot above 1")
    }

    // MARK: WindowSlide.frame

    @Test func windowSlideTranslationKeepsSize() {
        // Pure translation (WS-switch slide): size constant, origin
        // tweens, resizes == false so the adapter skips setSize.
        let move = WindowSlide(id: WindowID(serverID: 1),
                               from: CGRect(x: 100, y: 50, width: 300, height: 200),
                               to: CGRect(x: 700, y: 50, width: 300, height: 200))
        #expect(!(move.resizes))
        #expect(abs(move.frame(atEased: 0).minX - 100) < 0.0001)
        #expect(abs(move.frame(atEased: 1).minX - 700) < 0.0001)
        #expect(abs(move.frame(atEased: 0.5).minX - 400) < 0.0001)
        #expect(abs(move.frame(atEased: 0.5).width - 300) < 0.0001)
    }

    @Test func windowSlideResizeInterpolatesSize() {
        // Retile / layout-change: size tweens too; resizes == true.
        let grow = WindowSlide(id: WindowID(serverID: 2),
                               from: CGRect(x: 0, y: 0, width: 200, height: 100),
                               to: CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(grow.resizes)
        #expect(abs(grow.frame(atEased: 0.5).width - 400) < 0.0001)
        #expect(abs(grow.frame(atEased: 0.5).height - 300) < 0.0001)
        #expect(abs(grow.frame(atEased: 1).width - 600) < 0.0001)
    }

    // MARK: FacetConfig [animation]

    @Test func animationDefaultsOff() {
        // Opt-in: a fresh install animates nothing until enabled = true.
        let c = FacetConfig.from(toml: [:])
        #expect(!(c.effectiveAnimationsEnabled))
    }

    @Test func animationEnabledParsed() {
        let on = FacetConfig.from(toml: ["animation": ["enabled": .bool(true)]])
        #expect(on.effectiveAnimationsEnabled)
        let off = FacetConfig.from(toml: ["animation": ["enabled": .bool(false)]])
        #expect(!(off.effectiveAnimationsEnabled))
    }

    @Test func animationCurveDefaultsToCubic() {
        #expect(FacetConfig.from(toml: [:]).effectiveAnimationCurve == "cubic")
    }

    @Test func animationCurveParsedAndClamped() {
        func curve(_ s: String) -> String {
            FacetConfig.from(toml: ["animation": ["curve": .string(s)]])
                .effectiveAnimationCurve
        }
        #expect(curve("spring") == "spring")
        #expect(curve("RANDOM") == "random")   // case-insensitive
        #expect(curve("bogus") == "cubic")     // unknown → default
        #expect(curve("none") == "cubic")      // "none" dropped → default
    }

    @Test func animationEventDrivenFollowsMasterByDefault() {
        // Sub-key unset: tracks master `enabled`.
        let off = FacetConfig.from(toml: [:])
        #expect(!(off.effectiveAnimationEventDriven))
        let on = FacetConfig.from(toml: ["animation": ["enabled": .bool(true)]])
        #expect(on.effectiveAnimationEventDriven)
    }

    @Test func animationEventDrivenOptOut() {
        // Master on + sub-key off → master animations work but
        // background open/close stays a snap.
        let c = FacetConfig.from(toml: ["animation": [
            "enabled": .bool(true),
            "event-driven": .bool(false),
        ]])
        #expect(c.effectiveAnimationsEnabled)
        #expect(!(c.effectiveAnimationEventDriven))
    }

    @Test func animationEventDrivenCannotOverrideMasterOff() {
        // Sub-key alone can't turn animation on — master is the floor.
        let c = FacetConfig.from(toml: ["animation": [
            "enabled": .bool(false),
            "event-driven": .bool(true),
        ]])
        #expect(!(c.effectiveAnimationEventDriven))
    }
}
