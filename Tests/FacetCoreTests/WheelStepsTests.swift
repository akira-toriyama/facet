import Testing
import CoreGraphics
@testable import FacetCore

/// `wheelSteps` (t-9amp / R1) — the pure scroll-wheel → integer-step math lifted
/// out of the view-side switchers (today the `RailView` section carousel;
/// originally also the retired board bands), which previously held
/// three byte-identical copies. Precise (trackpad) deltas accumulate into an
/// inout `accum` and drain one ±1 step per `threshold`; a notched wheel is a flat
/// ±1 per detent. Sign: a NEGATIVE `deltaY` (content scrolled DOWN, natural-scroll
/// sign already baked in) → +1 ("next"); positive → -1 ("prev"). Pure; CI-only.
struct WheelStepsTests {

    // MARK: - notched wheel (no accumulation, flat ±1)

    @Test func notchedDownIsForward() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: -3, accum: &accum, threshold: 14,
                       precise: false, gestureBegan: false) == 1)
        #expect(accum == 0, "notched wheel must not touch the accumulator")
    }

    @Test func notchedUpIsBackward() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: 3, accum: &accum, threshold: 14,
                       precise: false, gestureBegan: false) == -1)
    }

    // MARK: - zero delta

    @Test func zeroDeltaIsNoStep() {
        var accum: CGFloat = 5
        #expect(
            wheelSteps(deltaY: 0, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 0)
        #expect(accum == 5, "a zero delta leaves the accumulator untouched")
    }

    // MARK: - precise (trackpad) accumulation

    @Test func preciseSubThresholdAccumulatesNoStep() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: -10, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 0)
        #expect(accum == -10, "sub-threshold travel is banked, not stepped")
    }

    /// A delta EXACTLY equal to the threshold drains one step and leaves the
    /// accumulator at 0. Pins the `while abs(accum) >= threshold` boundary:
    /// flipping `>=` to `>` would make an exact-threshold gesture return 0 (no
    /// board switch). The other precise rows only exercise sub-threshold /
    /// non-exact residuals, so this is the one that would catch that off-by-one.
    @Test func exactThresholdYieldsOneStepAndDrainsToZero() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: -14, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 1)
        #expect(accum == 0, "an exact-threshold delta drains fully, no remainder")
    }

    @Test func preciseLeftoverCarriesToNextCall() {
        var accum: CGFloat = -10            // banked from a previous call
        #expect(
            wheelSteps(deltaY: -10, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 1)
        #expect(abs(accum - (-6)) < 0.0001,
                "one threshold drained, remainder carried")
    }

    @Test func preciseNetMultiStepInOneCall() {
        var accum: CGFloat = 0
        // -30 over a 14 threshold drains twice (-30→-16→-2), both forward.
        #expect(
            wheelSteps(deltaY: -30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 2)
        #expect(abs(accum - (-2)) < 0.0001)
    }

    @Test func preciseUpIsNegativeNet() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: 30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == -2)
        #expect(abs(accum - 2) < 0.0001)
    }

    /// `.began` resets the accumulator first, so a stale sub-threshold leftover
    /// from an earlier, unrelated gesture cannot bias the new one.
    @Test func gestureBeganResetsAccumulator() {
        var accum: CGFloat = 13             // stale leftover, just under threshold
        #expect(
            wheelSteps(deltaY: -2, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: true) == 0,
            "the stale +13 is cleared, so -2 alone is sub-threshold")
        #expect(abs(accum - (-2)) < 0.0001)
    }

    // MARK: - the carousel's load-bearing invariant (RailView.scrollRotate)

    /// The rail SECTION carousel uses its OWN threshold (`railScrollStep` = 30)
    /// and, unlike the bands, emits PER drained step
    /// (`for _ in 0..<abs(steps) { kbMoveSelection(...) }`). That loop is only
    /// correct because the returned NET magnitude equals the number of ±1 drains
    /// (all sharing one sign). Pin that invariant at the carousel's threshold so
    /// a future "clamp the return to ±1" regression is caught, not swallowed.
    @Test func netMagnitudeEqualsDrainCountAtCarouselThreshold() {
        var accum: CGFloat = 0
        // -95 over a 30 threshold drains 3× (-95 → -65 → -35 → -5), all forward.
        #expect(
            wheelSteps(deltaY: -95, accum: &accum, threshold: 30,
                       precise: true, gestureBegan: false) == 3)
        #expect(abs(accum - (-5)) < 0.0001, "sub-threshold residual carries")
    }

    @Test func netMagnitudeNegativeAtCarouselThreshold() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: 95, accum: &accum, threshold: 30,
                       precise: true, gestureBegan: false) == -3)
        #expect(abs(accum - 5) < 0.0001)
    }

    /// The diagnostic case for the no-sign-flip invariant the carousel net-loop
    /// relies on: a banked leftover of the OPPOSITE sign from a prior gesture (no
    /// `.began` reset). `+5` then `deltaY -30` must absorb into a single forward
    /// step (net +1, accum -11) — within one call the drains never flip sign, even
    /// starting from an opposite-sign bank. A future "optimize" that keyed off
    /// `deltaY.signum()` instead of the per-iteration `accum` sign would diverge
    /// precisely here.
    @Test func oppositeSignLeftoverAbsorbsInOneCall() {
        var accum: CGFloat = 5
        #expect(
            wheelSteps(deltaY: -30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false) == 1)
        #expect(abs(accum - (-11)) < 0.0001,
                "opposite-sign bank is absorbed; drains never flip sign")
    }

    // MARK: - defensive (the helper stays total)

    /// A zero / negative threshold would make the drain loop never terminate;
    /// the helper guards it and reports no step instead of hanging.
    @Test func nonPositiveThresholdIsNoStep() {
        var accum: CGFloat = 0
        #expect(
            wheelSteps(deltaY: -50, accum: &accum, threshold: 0,
                       precise: true, gestureBegan: false) == 0)
    }
}
