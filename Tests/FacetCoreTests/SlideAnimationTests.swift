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

    // MARK: WindowSlide.origin

    func testWindowSlideInterpolatesHorizontally() {
        let s = WindowSlide(id: WindowID(serverID: 1),
                            from: CGPoint(x: 100, y: 50),
                            to: CGPoint(x: 700, y: 50))
        XCTAssertEqual(s.origin(atEased: 0).x, 100, accuracy: 0.0001)
        XCTAssertEqual(s.origin(atEased: 1).x, 700, accuracy: 0.0001)
        XCTAssertEqual(s.origin(atEased: 0.5).x, 400, accuracy: 0.0001)
        // y is held constant — the slide is pure translation.
        XCTAssertEqual(s.origin(atEased: 0.5).y, 50, accuracy: 0.0001)
    }

    // MARK: FacetConfig [animation]

    func testAnimationDefaults() {
        let c = FacetConfig.from(toml: [:])
        XCTAssertTrue(c.effectiveAnimationsEnabled)
        XCTAssertEqual(c.effectiveAnimationDuration, 0.28, accuracy: 0.0001)
    }

    func testAnimationEnabledParsed() {
        let c = FacetConfig.from(toml: ["animation": ["enabled": .bool(false)]])
        XCTAssertFalse(c.effectiveAnimationsEnabled)
    }

    func testAnimationDurationClampsLow() {
        let c = FacetConfig.from(toml: ["animation": ["duration-ms": .int(5)]])
        XCTAssertEqual(c.effectiveAnimationDuration, 0.08, accuracy: 0.0001)
    }

    func testAnimationDurationClampsHigh() {
        let c = FacetConfig.from(toml: ["animation": ["duration-ms": .int(9999)]])
        XCTAssertEqual(c.effectiveAnimationDuration, 0.8, accuracy: 0.0001)
    }
}
