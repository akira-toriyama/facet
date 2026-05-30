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

    func testEffectiveWorkspaceListReadsConfiguredSpaceEntries() {
        var c = FacetConfig()
        c.spaceWorkspaceNames = [1: [1: "dev", 3: "sns", 5: ""]]
        let list = c.effectiveWorkspaceList(forSpaceOrdinal: 1)
        XCTAssertEqual(list.map(\.index), [1, 3, 5])
        XCTAssertEqual(list.map(\.name), ["dev", "sns", ""])
    }

    func testEffectiveWorkspaceListDropsNonPositiveKeys() {
        var c = FacetConfig()
        c.spaceWorkspaceNames = [1: [0: "zero", -1: "neg", 2: "ok"]]
        let list = c.effectiveWorkspaceList(forSpaceOrdinal: 1)
        XCTAssertEqual(list.map(\.index), [2])
        XCTAssertEqual(list.map(\.name), ["ok"])
    }

    func testFromTOMLPopulatesSpaceWorkspaceNames() {
        let parsed = parseTOMLSubset("""
            [space.1]
            1 = "dev"
            2 = "sns"
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.spaceWorkspaceNames[1]?[1], "dev")
        XCTAssertEqual(c.spaceWorkspaceNames[1]?[2], "sns")
        XCTAssertEqual(c.spaceWorkspaceNames[1]?.count, 2)
    }

    // MARK: - [[exclude]] rules

    func testExclusionRulesParsedFromTOML() {
        let rules = FacetConfig.exclusionRules(fromTOML: """
            [[exclude]]
            app = "com.apple.finder"
            action = "float"

            [[exclude]]
            title = "^$"
            max_width = 400
            action = "ignore"

            [[exclude]]
            subrole = "AXDialog"
            """)
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].app, "com.apple.finder")
        XCTAssertEqual(rules[0].action, .float)
        XCTAssertEqual(rules[1].title, "^$")
        XCTAssertEqual(rules[1].maxWidth, 400)
        XCTAssertEqual(rules[1].action, .ignore)
        // No explicit action → defaults to float.
        XCTAssertEqual(rules[2].subrole, "AXDialog")
        XCTAssertEqual(rules[2].action, .float)
    }

    func testExclusionRuleWithNoMatchKeyDropped() {
        // A `[[exclude]]` with only `action` (no match key) is a
        // mistake and is dropped (it would match nothing anyway).
        let rules = FacetConfig.exclusionRules(fromTOML: """
            [[exclude]]
            action = "ignore"

            [[exclude]]
            app = "x"
            """)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].app, "x")
    }

    func testExclusionRulesEmptyWhenAbsent() {
        let c = FacetConfig()
        XCTAssertTrue(c.effectiveExclusionRules.isEmpty)
        XCTAssertTrue(FacetConfig.exclusionRules(fromTOML: """
            [grid]
            cols = 2
            """).isEmpty)
    }

    // MARK: - TOML mapping

    func testFromTOMLMapsAllRecognisedKeys() {
        let parsed = parseTOMLSubset("""
            default-view = "tree"
            theme = "cute"

            [grid]
            cols = 6
            label-position = "down"
            thumbnail-refresh-seconds = 10
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.effectiveDefaultView, "tree")
        XCTAssertEqual(c.effectiveTheme, "cute")
        XCTAssertEqual(c.effectiveGridCols, 6)
        XCTAssertEqual(c.effectiveGridLabelPosition, "down")
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

    func testEffectiveWorkspaceListForSpaceOrdinal() {
        var c = FacetConfig()
        c.spaceWorkspaceNames = [1: [1: "a", 2: "b"]]    // space 1 = 2

        // Configured ordinal → per-space list.
        XCTAssertEqual(
            c.effectiveWorkspaceList(forSpaceOrdinal: 1).map(\.name),
            ["a", "b"])
        // Unconfigured ordinal → defaultWorkspaceCount unnamed slots.
        let unconfigured = c.effectiveWorkspaceList(forSpaceOrdinal: 2)
        XCTAssertEqual(unconfigured.count, FacetConfig.defaultWorkspaceCount)
        XCTAssertTrue(unconfigured.allSatisfy { $0.name.isEmpty })
        // nil ordinal → default slots.
        let nilList = c.effectiveWorkspaceList(forSpaceOrdinal: nil)
        XCTAssertEqual(nilList.count, FacetConfig.defaultWorkspaceCount)
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
