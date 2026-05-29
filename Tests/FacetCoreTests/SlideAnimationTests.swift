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
