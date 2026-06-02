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

    func testEffectiveWorkspaceListReadsConfiguredDesktopEntries() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: [
            1: WorkspaceConfig(name: "dev"),
            3: WorkspaceConfig(name: "sns"),
            5: WorkspaceConfig(name: ""),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.map(\.index), [1, 3, 5])
        XCTAssertEqual(list.map(\.config.name), ["dev", "sns", ""])
    }

    func testEffectiveWorkspaceListDropsNonPositiveKeys() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: [
            0: WorkspaceConfig(name: "zero"),
            -1: WorkspaceConfig(name: "neg"),
            2: WorkspaceConfig(name: "ok"),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.map(\.index), [2])
        XCTAssertEqual(list.map(\.config.name), ["ok"])
    }

    func testFromTOMLPopulatesMacDesktopWorkspaceConfigs() {
        let parsed = parseTOMLSubset("""
            [desktop.1]
            1 = { name = "dev" }
            2 = { name = "sns", layout = "bsp" }
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?[1],
                       WorkspaceConfig(name: "dev"))
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?[2],
                       WorkspaceConfig(name: "sns", layout: "bsp"))
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?.count, 2)
    }

    func testFromTOMLDropsNonTableDesktopEntries() {
        // Shorthand `1 = "Dev"` (post-PR2 disallowed) is silently
        // skipped: only inline-table values are accepted.
        let parsed = parseTOMLSubset("""
            [desktop.1]
            1 = "Dev"
            2 = { name = "Web" }
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?.count, 1)
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?[2]?.name, "Web")
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

    // MARK: - Per-mac-desktop [desktop.N]

    func testFromTOMLParsesPerDesktopSections() {
        let parsed = parseTOMLSubset("""
            [desktop.1]
            1 = { name = "dev" }
            2 = { name = "build", layout = "bsp" }

            [desktop.2]
            1 = { name = "mail" }
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1], [
            1: WorkspaceConfig(name: "dev"),
            2: WorkspaceConfig(name: "build", layout: "bsp"),
        ])
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[2], [
            1: WorkspaceConfig(name: "mail"),
        ])
        XCTAssertNil(c.macDesktopWorkspaceConfigs[3])
    }

    func testIsMacDesktopManagedOptInVsDefault() {
        // No [desktop.N] anywhere → every mac desktop managed (default).
        let none = FacetConfig()
        XCTAssertTrue(none.isMacDesktopManaged(ordinal: 1))
        XCTAssertTrue(none.isMacDesktopManaged(ordinal: 99))
        XCTAssertTrue(none.isMacDesktopManaged(ordinal: nil))

        // Any [desktop.N] present → opt-in: only configured ordinals.
        var optIn = FacetConfig()
        optIn.macDesktopWorkspaceConfigs = [
            1: [1: WorkspaceConfig(name: "a")],
            3: [1: WorkspaceConfig(name: "b")],
        ]
        XCTAssertTrue(optIn.isMacDesktopManaged(ordinal: 1))
        XCTAssertTrue(optIn.isMacDesktopManaged(ordinal: 3))
        XCTAssertFalse(optIn.isMacDesktopManaged(ordinal: 2),
                       "unconfigured ordinal is hands-off in opt-in mode")
        XCTAssertFalse(optIn.isMacDesktopManaged(ordinal: 6))
        XCTAssertTrue(optIn.isMacDesktopManaged(ordinal: nil),
                      "SkyLight-unavailable always managed")
    }

    func testEffectiveWorkspaceListForMacDesktopOrdinal() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: [
            1: WorkspaceConfig(name: "a"),
            2: WorkspaceConfig(name: "b"),
        ]]

        // Configured ordinal → per-mac-desktop list.
        XCTAssertEqual(
            c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name),
            ["a", "b"])
        // Unconfigured ordinal → defaultWorkspaceCount unnamed slots.
        let unconfigured = c.effectiveWorkspaceList(forMacDesktopOrdinal: 2)
        XCTAssertEqual(unconfigured.count, FacetConfig.defaultWorkspaceCount)
        XCTAssertTrue(unconfigured.allSatisfy { $0.config.name.isEmpty })
        // nil ordinal → default slots.
        let nilList = c.effectiveWorkspaceList(forMacDesktopOrdinal: nil)
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
