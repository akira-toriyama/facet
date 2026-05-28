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

    func testEffectiveWorkspaceListDefaultWhenUnset() {
        let c = FacetConfig()
        let list = c.effectiveWorkspaceList
        XCTAssertEqual(list.count, FacetConfig.defaultWorkspaceCount)
        XCTAssertEqual(list.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertTrue(list.allSatisfy { $0.name.isEmpty })
    }

    func testEffectiveWorkspaceListReadsConfiguredEntries() {
        var c = FacetConfig()
        c.workspaceNames = [1: "dev", 3: "sns", 5: ""]
        let list = c.effectiveWorkspaceList
        XCTAssertEqual(list.map(\.index), [1, 3, 5])
        XCTAssertEqual(list.map(\.name), ["dev", "sns", ""])
    }

    func testEffectiveWorkspaceListDropsNonPositiveKeys() {
        var c = FacetConfig()
        c.workspaceNames = [0: "zero", -1: "neg", 2: "ok"]
        let list = c.effectiveWorkspaceList
        XCTAssertEqual(list.map(\.index), [2])
        XCTAssertEqual(list.map(\.name), ["ok"])
    }

    func testFromTOMLPopulatesWorkspaceNames() {
        let parsed = parseTOMLSubset("""
            [workspace]
            setupFiles = ["x.sh"]
            1 = "dev"
            2 = "sns"
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.workspaceNames[1], "dev")
        XCTAssertEqual(c.workspaceNames[2], "sns")
        // Non-int meta keys (setupFiles etc.) must not bleed into
        // workspaceNames — a parser bug that coerced unparseable
        // string keys to 0 would fail this count check (and would
        // also surface as a phantom index-0 entry).
        XCTAssertEqual(c.workspaceNames.count, 2)
        XCTAssertNil(c.workspaceNames[0])
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

    // MARK: - Per-native-Space [space.N]

    func testFromTOMLParsesPerSpaceSections() {
        let parsed = parseTOMLSubset("""
            [space.1]
            1 = "dev"
            2 = "build"

            [space.2]
            1 = "mail"
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.spaceWorkspaceNames[1], [1: "dev", 2: "build"])
        XCTAssertEqual(c.spaceWorkspaceNames[2], [1: "mail"])
        XCTAssertNil(c.spaceWorkspaceNames[3])
    }

    func testIsSpaceManagedOptInVsDefault() {
        // No [space.N] anywhere → every Space managed (default).
        let none = FacetConfig()
        XCTAssertTrue(none.isSpaceManaged(ordinal: 1))
        XCTAssertTrue(none.isSpaceManaged(ordinal: 99))
        XCTAssertTrue(none.isSpaceManaged(ordinal: nil))

        // Any [space.N] present → opt-in: only configured ordinals.
        var optIn = FacetConfig()
        optIn.spaceWorkspaceNames = [1: [1: "a"], 3: [1: "b"]]
        XCTAssertTrue(optIn.isSpaceManaged(ordinal: 1))
        XCTAssertTrue(optIn.isSpaceManaged(ordinal: 3))
        XCTAssertFalse(optIn.isSpaceManaged(ordinal: 2),
                       "unconfigured ordinal is hands-off in opt-in mode")
        XCTAssertFalse(optIn.isSpaceManaged(ordinal: 6))
        XCTAssertTrue(optIn.isSpaceManaged(ordinal: nil),
                      "SkyLight-unavailable always managed")
    }

    func testEffectiveWorkspaceListForSpaceOrdinalFallsBack() {
        var c = FacetConfig()
        c.workspaceNames = [1: "g1", 2: "g2", 3: "g3"]   // global = 3
        c.spaceWorkspaceNames = [1: [1: "a", 2: "b"]]    // space 1 = 2

        // Configured ordinal → per-space list.
        XCTAssertEqual(
            c.effectiveWorkspaceList(forSpaceOrdinal: 1).map(\.name),
            ["a", "b"])
        // Unconfigured ordinal → global fallback.
        XCTAssertEqual(
            c.effectiveWorkspaceList(forSpaceOrdinal: 2).map(\.name),
            ["g1", "g2", "g3"])
        // nil ordinal (SkyLight unavailable / single-space) → global.
        XCTAssertEqual(
            c.effectiveWorkspaceList(forSpaceOrdinal: nil).map(\.index),
            [1, 2, 3])
    }

    func testEmptyTOMLYieldsAllDefaults() {
        let c = FacetConfig.from(toml: [:])
        XCTAssertNil(c.effectiveDefaultView)
        XCTAssertEqual(c.effectiveTheme, "terminal")
        XCTAssertEqual(c.effectiveGridCols, 4)
    }

    // MARK: - setupFiles + expandPath

    func testSetupFilesParseFromTOML() {
        let parsed = parseTOMLSubset(#"""
            [workspace]
            setupFiles = ["~/foo.sh", "/etc/bar.sh"]
            """#)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.setupFiles, ["~/foo.sh", "/etc/bar.sh"])
    }

    func testEffectiveSetupFilesEmptyWhenUnset() {
        XCTAssertEqual(FacetConfig().effectiveSetupFiles, [])
    }

    func testEffectiveSetupFilesExpandsTilde() {
        var c = FacetConfig()
        c.setupFiles = ["~/foo.sh"]
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        XCTAssertEqual(c.effectiveSetupFiles, ["\(home)/foo.sh"])
    }

    func testEffectiveSetupFilesDropsEmptyAfterExpansion() {
        var c = FacetConfig()
        c.setupFiles = ["", "  ", "/keep.sh"]
        XCTAssertEqual(c.effectiveSetupFiles, ["/keep.sh"])
    }

    func testExpandPathDollarVar() {
        setenv("FACET_TEST_VAR", "/from-env", 1)
        defer { unsetenv("FACET_TEST_VAR") }
        XCTAssertEqual(expandPath("$FACET_TEST_VAR/x"),
                       "/from-env/x")
    }

    func testExpandPathBracedVar() {
        setenv("FACET_TEST_VAR", "/from-env", 1)
        defer { unsetenv("FACET_TEST_VAR") }
        XCTAssertEqual(expandPath("${FACET_TEST_VAR}-suffix"),
                       "/from-env-suffix")
    }

    func testExpandPathUnsetVarBecomesEmpty() {
        unsetenv("FACET_DEFINITELY_UNSET")
        XCTAssertEqual(expandPath("$FACET_DEFINITELY_UNSET/x"),
                       "/x")
    }

    func testExpandPathLiteralTildeMidString() {
        // Only `~` at start or `~/` expands; mid-path `~` stays
        // literal (matches sh).
        XCTAssertEqual(expandPath("/foo/~bar"), "/foo/~bar")
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
