import XCTest
import CoreGraphics
@testable import FacetCore

/// `wheelSteps` (t-9amp / R1) — the pure scroll-wheel → integer-step math lifted
/// out of the three view-side switchers (the tree `BoardBand`, the rail
/// `RailBoardBand`, and the `RailView` section carousel), which previously held
/// three byte-identical copies. Precise (trackpad) deltas accumulate into an
/// inout `accum` and drain one ±1 step per `threshold`; a notched wheel is a flat
/// ±1 per detent. Sign: a NEGATIVE `deltaY` (content scrolled DOWN, natural-scroll
/// sign already baked in) → +1 ("next"); positive → -1 ("prev"). Pure; CI-only.
final class WheelStepsTests: XCTestCase {

    // MARK: - notched wheel (no accumulation, flat ±1)

    func testNotchedDownIsForward() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: -3, accum: &accum, threshold: 14,
                       precise: false, gestureBegan: false), 1)
        XCTAssertEqual(accum, 0, "notched wheel must not touch the accumulator")
    }

    func testNotchedUpIsBackward() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: 3, accum: &accum, threshold: 14,
                       precise: false, gestureBegan: false), -1)
    }

    // MARK: - zero delta

    func testZeroDeltaIsNoStep() {
        var accum: CGFloat = 5
        XCTAssertEqual(
            wheelSteps(deltaY: 0, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), 0)
        XCTAssertEqual(accum, 5, "a zero delta leaves the accumulator untouched")
    }

    // MARK: - precise (trackpad) accumulation

    func testPreciseSubThresholdAccumulatesNoStep() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: -10, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), 0)
        XCTAssertEqual(accum, -10, "sub-threshold travel is banked, not stepped")
    }

    func testPreciseLeftoverCarriesToNextCall() {
        var accum: CGFloat = -10            // banked from a previous call
        XCTAssertEqual(
            wheelSteps(deltaY: -10, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), 1)
        XCTAssertEqual(accum, -6, accuracy: 0.0001,
                       "one threshold drained, remainder carried")
    }

    func testPreciseNetMultiStepInOneCall() {
        var accum: CGFloat = 0
        // -30 over a 14 threshold drains twice (-30→-16→-2), both forward.
        XCTAssertEqual(
            wheelSteps(deltaY: -30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), 2)
        XCTAssertEqual(accum, -2, accuracy: 0.0001)
    }

    func testPreciseUpIsNegativeNet() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: 30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), -2)
        XCTAssertEqual(accum, 2, accuracy: 0.0001)
    }

    /// `.began` resets the accumulator first, so a stale sub-threshold leftover
    /// from an earlier, unrelated gesture cannot bias the new one.
    func testGestureBeganResetsAccumulator() {
        var accum: CGFloat = 13             // stale leftover, just under threshold
        XCTAssertEqual(
            wheelSteps(deltaY: -2, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: true), 0,
            "the stale +13 is cleared, so -2 alone is sub-threshold")
        XCTAssertEqual(accum, -2, accuracy: 0.0001)
    }

    // MARK: - the carousel's load-bearing invariant (RailView.scrollRotate)

    /// The rail SECTION carousel uses its OWN threshold (`railScrollStep` = 30)
    /// and, unlike the bands, emits PER drained step
    /// (`for _ in 0..<abs(steps) { kbMoveSelection(...) }`). That loop is only
    /// correct because the returned NET magnitude equals the number of ±1 drains
    /// (all sharing one sign). Pin that invariant at the carousel's threshold so
    /// a future "clamp the return to ±1" regression is caught, not swallowed.
    func testNetMagnitudeEqualsDrainCountAtCarouselThreshold() {
        var accum: CGFloat = 0
        // -95 over a 30 threshold drains 3× (-95 → -65 → -35 → -5), all forward.
        XCTAssertEqual(
            wheelSteps(deltaY: -95, accum: &accum, threshold: 30,
                       precise: true, gestureBegan: false), 3)
        XCTAssertEqual(accum, -5, accuracy: 0.0001, "sub-threshold residual carries")
    }

    func testNetMagnitudeNegativeAtCarouselThreshold() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: 95, accum: &accum, threshold: 30,
                       precise: true, gestureBegan: false), -3)
        XCTAssertEqual(accum, 5, accuracy: 0.0001)
    }

    /// The diagnostic case for the no-sign-flip invariant the carousel net-loop
    /// relies on: a banked leftover of the OPPOSITE sign from a prior gesture (no
    /// `.began` reset). `+5` then `deltaY -30` must absorb into a single forward
    /// step (net +1, accum -11) — within one call the drains never flip sign, even
    /// starting from an opposite-sign bank. A future "optimize" that keyed off
    /// `deltaY.signum()` instead of the per-iteration `accum` sign would diverge
    /// precisely here.
    func testOppositeSignLeftoverAbsorbsInOneCall() {
        var accum: CGFloat = 5
        XCTAssertEqual(
            wheelSteps(deltaY: -30, accum: &accum, threshold: 14,
                       precise: true, gestureBegan: false), 1)
        XCTAssertEqual(accum, -11, accuracy: 0.0001,
                       "opposite-sign bank is absorbed; drains never flip sign")
    }

    // MARK: - defensive (the helper stays total, like boardIndexStep)

    /// A zero / negative threshold would make the drain loop never terminate;
    /// the helper guards it and reports no step instead of hanging.
    func testNonPositiveThresholdIsNoStep() {
        var accum: CGFloat = 0
        XCTAssertEqual(
            wheelSteps(deltaY: -50, accum: &accum, threshold: 0,
                       precise: true, gestureBegan: false), 0)
    }
}
