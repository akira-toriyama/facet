import XCTest
import Foundation
@testable import FacetCore

final class FacetConfigTests: XCTestCase {

    // MARK: - effective accessors

    func testEffectiveDefaultViewAcceptsTreeAndGrid() {
        var c = FacetConfig()
        c.defaultView = "tree"
        XCTAssertEqual(c.effectiveDefaultView, "tree")
        c.defaultView = "GRID"
        XCTAssertEqual(c.effectiveDefaultView, "grid",
                       "case-insensitive")
        c.defaultView = "panel"
        XCTAssertNil(c.effectiveDefaultView,
                     "unknown name treated as agent-only mode")
        c.defaultView = nil
        XCTAssertNil(c.effectiveDefaultView,
                     "missing key → agent-only mode")
    }

    func testEffectiveThemeFallsBackToTerminal() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveTheme, "terminal")
        c.theme = "Cute"
        XCTAssertEqual(c.effectiveTheme, "cute")
        c.theme = "neon"
        XCTAssertEqual(c.effectiveTheme, "terminal",
                       "unknown theme name → default")
    }

    func testEffectiveGridColsClampsAndDefaults() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveGridCols, 4, "default")
        c.gridCols = 0
        XCTAssertEqual(c.effectiveGridCols, 1, "clamp low")
        c.gridCols = 99
        XCTAssertEqual(c.effectiveGridCols, 12, "clamp high")
        c.gridCols = 6
        XCTAssertEqual(c.effectiveGridCols, 6)
    }

    func testEffectiveGridLabelSizeClampsAndComputesBandHeight() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveGridLabelSize, 15)
        XCTAssertEqual(c.effectiveGridLabelBandHeight, 22)
        c.gridLabelSize = 4
        XCTAssertEqual(c.effectiveGridLabelSize, 8, "clamp low")
        c.gridLabelSize = 99
        XCTAssertEqual(c.effectiveGridLabelSize, 32, "clamp high")
    }

    func testEffectiveThumbnailRefreshInterval() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveThumbnailRefreshInterval, 4)
        c.thumbnailRefreshSeconds = 0
        XCTAssertNil(c.effectiveThumbnailRefreshInterval,
                     "0 disables background capture")
        c.thumbnailRefreshSeconds = 200
        XCTAssertEqual(c.effectiveThumbnailRefreshInterval, 60,
                       "clamp high")
    }

    // MARK: - TOML mapping

    func testFromTOMLMapsAllRecognisedKeys() {
        let parsed = parseTOMLSubset("""
            default_view = "tree"
            theme = "cute"

            [grid]
            cols = 6
            label-position = "down"
            label-size = 18
            thumbnail-refresh-seconds = 10
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.effectiveDefaultView, "tree")
        XCTAssertEqual(c.effectiveTheme, "cute")
        XCTAssertEqual(c.effectiveGridCols, 6)
        XCTAssertEqual(c.effectiveGridLabelPosition, "down")
        XCTAssertEqual(c.effectiveGridLabelSize, 18)
        XCTAssertEqual(c.effectiveThumbnailRefreshInterval, 10)
    }

    func testEmptyTOMLYieldsAllDefaults() {
        let c = FacetConfig.from(toml: [:])
        XCTAssertNil(c.effectiveDefaultView)
        XCTAssertEqual(c.effectiveTheme, "terminal")
        XCTAssertEqual(c.effectiveGridCols, 4)
    }

    // MARK: - Disk loader

    func testLoadFallsBackToDefaultsForMissingConfig() {
        let tmp = NSTemporaryDirectory()
            + "facet-test-\(UUID().uuidString)/missing.toml"
        defer {
            let dir = (tmp as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        let c = FacetConfig.load(path: tmp)
        XCTAssertNil(c.effectiveDefaultView,
                     "missing config → agent-only mode by default")
    }
}
