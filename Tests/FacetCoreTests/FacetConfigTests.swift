import XCTest
import Foundation
import CoreGraphics
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

    func testEffectiveRailEdgeClampsToBottom() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveRailEdge, .bottom, "unset → bottom")
        c.railEdge = "LEFT"
        XCTAssertEqual(c.effectiveRailEdge, .left, "case-insensitive")
        c.railEdge = "top"
        XCTAssertEqual(c.effectiveRailEdge, .top)
        c.railEdge = "diagonal"
        XCTAssertEqual(c.effectiveRailEdge, .bottom, "unknown → bottom")
    }

    func testEffectiveRailCellsClamps() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveRailCells, 7, "default")
        c.railCells = 10
        XCTAssertEqual(c.effectiveRailCells, 10)
        c.railCells = 0
        XCTAssertEqual(c.effectiveRailCells, 1, "floor 1")
        c.railCells = 999
        XCTAssertEqual(c.effectiveRailCells, 20, "ceiling 20")
    }

    func testEffectiveThemeFallsBackToTerminal() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveTheme, "terminal")
        c.theme = "Dracula"
        XCTAssertEqual(c.effectiveTheme, "dracula",
                       "a known name resolves case-insensitively")
        c.theme = "nonsuch-theme"
        XCTAssertEqual(c.effectiveTheme, "terminal",
                       "unknown theme name → default")
        c.theme = "nord"
        XCTAssertEqual(c.effectiveTheme, "terminal",
                       "a Phase-V-cut theme name (nord) → default")
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

    // MARK: - [tree] line-pets

    func testEffectiveTreeLinePetsDefaultsEmpty() {
        let c = FacetConfig()
        XCTAssertEqual(c.effectiveTreeLinePets, [], "unset → off")
    }

    func testEffectiveTreeLinePetsNormalizes() {
        var c = FacetConfig()
        c.treeLinePets = ["Chomp", "  ghost ", ""]
        XCTAssertEqual(c.effectiveTreeLinePets, ["chomp", "ghost"],
                       "lower-cased, trimmed, empty entries dropped, order kept")
    }

    func testTreeLinePetsParsesArrayOnly() {
        let arr = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            line-pets = ["chomp", "ghost"]
            """))
        XCTAssertEqual(arr.effectiveTreeLinePets, ["chomp", "ghost"],
                       "TOML array form")
        // The old lenient comma-string form is retired (family grammar:
        // arrays are arrays) — a string value is ignored, pets stay off.
        let csv = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            line-pets = "chomp, ghost"
            """))
        XCTAssertEqual(csv.effectiveTreeLinePets, [],
                       "comma-string form no longer parses")
    }

    func testEffectiveTreePetScaleDefaultsAndClamps() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveTreePetScale, 0.9, "default")
        c.treePetScale = 1.5
        XCTAssertEqual(c.effectiveTreePetScale, 1.5)
        c.treePetScale = -3
        XCTAssertEqual(c.effectiveTreePetScale, 0.1, "floor 0.1")
    }

    func testEffectiveTreePetLapSecondsDefaultsAndClamps() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveTreePetLapSeconds, 8, "default")
        c.treePetLapSeconds = 12
        XCTAssertEqual(c.effectiveTreePetLapSeconds, 12)
        c.treePetLapSeconds = 0
        XCTAssertEqual(c.effectiveTreePetLapSeconds, 0.5, "floor 0.5")
    }

    func testTreePetScaleParsesFloatViaTOML() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            pet-scale = 1.25
            pet-lap-seconds = 6
            """))
        XCTAssertEqual(c.effectiveTreePetScale, 1.25,
                       "fractional pet-scale survives the new .double parse")
        XCTAssertEqual(c.effectiveTreePetLapSeconds, 6)
    }

    // MARK: - [[exclude]] rules

    func testExclusionRulesParsedFromTOML() {
        let rules = FacetConfig.exclusionRules(fromTOML: """
            [[exclude]]
            app = "com.apple.finder"
            action = "float"

            [[exclude]]
            title = "^$"
            max-width = 400
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

            [theme]
            name = "dracula"

            [grid]
            cols = 6
            label-position = "down"
            thumbnail-refresh-seconds = 10
            theme = "github-light"
            """)
        let c = FacetConfig.from(toml: parsed)
        XCTAssertEqual(c.effectiveDefaultView, "tree")
        XCTAssertEqual(c.effectiveTheme, "dracula")
        XCTAssertEqual(c.effectiveGridTheme, "github-light",
                       "per-view override parses")
        XCTAssertEqual(c.effectiveTreeTheme, "dracula",
                       "unset per-view key inherits [theme].name")
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

    // MARK: - unknownValueWarnings (silent-clamp surfacing)

    func testNoWarningsForDefaultConfig() {
        XCTAssertTrue(FacetConfig().unknownValueWarnings().isEmpty,
                      "every key unset → nothing was clamped")
    }

    func testNoWarningsForValidValues() {
        var c = FacetConfig()
        c.theme = "dracula"
        c.defaultLayout = "bsp"
        c.railEdge = "left"
        c.treePreviewMode = "mirror"
        c.animationCurve = "spring"
        c.gridLabelPosition = "down"
        c.defaultView = "grid"
        XCTAssertTrue(c.unknownValueWarnings().isEmpty,
                      "all recognised → no warnings")
    }

    func testValidValuesAreCaseInsensitive() {
        var c = FacetConfig()
        c.defaultLayout = "BSP"
        c.theme = "Dracula"
        c.railEdge = "LEFT"
        XCTAssertTrue(c.unknownValueWarnings().isEmpty,
                      "a known name in any case is not a clamp")
    }

    func testUnknownLayoutWarns() {
        var c = FacetConfig()
        // `tall` was renamed to `master-left` (#139); an old config
        // carrying it now silently clamps to `float`.
        c.defaultLayout = "tall"
        let w = c.unknownValueWarnings()
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("layout"), "names the key")
        XCTAssertTrue(w[0].contains("tall"), "echoes the written value")
        XCTAssertTrue(w[0].contains("float"), "names the fallback")
    }

    func testUnknownViewWarnsAgentOnly() {
        var c = FacetConfig()
        c.defaultView = "panel"
        let w = c.unknownValueWarnings()
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("view"))
        XCTAssertTrue(w[0].contains("agent-only"),
                      "unknown view degrades to agent-only mode, not a value")
    }

    func testMultipleUnknownsEachWarnOnce() {
        var c = FacetConfig()
        c.defaultLayout = "nonsuch-layout"
        c.theme = "nonsuch-theme"
        c.railEdge = "diagonal"
        XCTAssertEqual(c.unknownValueWarnings().count, 3,
                       "one warning per clamped key")
    }

    func testEmptyStringIsNotAWarning() {
        var c = FacetConfig()
        c.defaultLayout = ""
        XCTAssertTrue(c.unknownValueWarnings().isEmpty,
                      "empty string is treated like unset, not a typo")
    }

    // MARK: - effectiveRaiseOnOpen ([window] raise-on-open)

    private func raiseMode(_ raw: String?) -> RaiseOnOpen {
        var c = FacetConfig()
        c.raiseOnOpen = raw
        return c.effectiveRaiseOnOpen
    }

    func testRaiseOnOpenDefaultsToRaise() {
        XCTAssertEqual(raiseMode(nil), .raise)
    }

    func testRaiseOnOpenParsesEachCase() {
        XCTAssertEqual(raiseMode("raise"), .raise)
        XCTAssertEqual(raiseMode("activate"), .activate)
        XCTAssertEqual(raiseMode("off"), .off)
    }

    func testRaiseOnOpenIsCaseInsensitive() {
        XCTAssertEqual(raiseMode("ACTIVATE"), .activate)
        XCTAssertEqual(raiseMode("Off"), .off)
    }

    func testRaiseOnOpenUnknownClampsToRaise() {
        XCTAssertEqual(raiseMode("bogus"), .raise)
        XCTAssertEqual(raiseMode(""), .raise)
    }

    // MARK: - effectiveRailStrip

    func testEffectiveRailStripClamps() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveRailStrip, 30, "default")
        c.railStrip = 20
        XCTAssertEqual(c.effectiveRailStrip, 20)
        c.railStrip = 1
        XCTAssertEqual(c.effectiveRailStrip, 8, "floor 8")
        c.railStrip = 999
        XCTAssertEqual(c.effectiveRailStrip, 50, "ceiling 50")
    }

    // MARK: - effectiveTreeGeometry

    func testEffectiveTreeGeometryNeedsAllFour() {
        var c = FacetConfig()
        XCTAssertNil(c.effectiveTreeGeometry, "all unset → nil")
        c.treePosX = 10; c.treePosY = 20; c.treeWidth = 300; c.treeHeight = 400
        XCTAssertEqual(c.effectiveTreeGeometry,
                       CGRect(x: 10, y: 20, width: 300, height: 400))
        c.treeHeight = nil
        XCTAssertNil(c.effectiveTreeGeometry, "one missing → nil")
    }

    func testEffectiveTreeGeometryRejectsNonPositiveSize() {
        var c = FacetConfig()
        c.treePosX = 0; c.treePosY = 0; c.treeWidth = 0; c.treeHeight = 400
        XCTAssertNil(c.effectiveTreeGeometry, "width 0 → nil")
        c.treeWidth = 300; c.treeHeight = 0
        XCTAssertNil(c.effectiveTreeGeometry, "height 0 → nil")
    }

    func testTreeGeometryPartialWarns() {
        var c = FacetConfig()
        c.treePosX = 10   // only 1 of 4
        XCTAssertTrue(c.unknownValueWarnings().contains {
            $0.contains("[tree] geometry needs all of")
        }, "partial geometry warns")
        c.treePosY = 20; c.treeWidth = 300; c.treeHeight = 400
        XCTAssertFalse(c.unknownValueWarnings().contains {
            $0.contains("[tree] geometry needs all of")
        }, "all four → no warning")
    }

    // MARK: - allow-list accessors (border effect / tree preview mode)

    func testEffectiveBorderEffectAllowList() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveBorderEffect, "off", "default")
        c.borderEffect = "NEON"
        XCTAssertEqual(c.effectiveBorderEffect, "neon", "case-insensitive")
        c.borderEffect = "sparkle"
        XCTAssertEqual(c.effectiveBorderEffect, "off", "unknown → off")
    }

    func testEffectiveTreePreviewModeAllowList() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveTreePreviewMode, "popover", "default")
        c.treePreviewMode = "Mirror"
        XCTAssertEqual(c.effectiveTreePreviewMode, "mirror", "case-insensitive")
        c.treePreviewMode = "fullscreen"
        XCTAssertEqual(c.effectiveTreePreviewMode, "popover", "unknown → popover")
    }

    // MARK: - border / cycle numeric clamps

    func testEffectiveBorderWidthClamps() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveBorderWidth, 1.5, accuracy: 0.0001, "default")
        c.borderWidth = 4
        XCTAssertEqual(c.effectiveBorderWidth, 4, accuracy: 0.0001)
        c.borderWidth = 0.1
        XCTAssertEqual(c.effectiveBorderWidth, 0.5, accuracy: 0.0001, "floor")
        c.borderWidth = 99
        XCTAssertEqual(c.effectiveBorderWidth, 30, accuracy: 0.0001, "ceiling")
    }

    func testBorderAndThemeCycleClampIndependently() {
        var c = FacetConfig()
        XCTAssertEqual(c.effectiveBorderCycleSeconds, 6, accuracy: 0.0001,
                       "border default (6000 ms)")
        XCTAssertEqual(c.effectiveThemeCycleSeconds, 6, accuracy: 0.0001,
                       "theme default (6000 ms)")
        c.borderColorCycleMs = 200_000   // over ceiling (120000 ms)
        c.themeColorCycleMs = 0          // under floor (1000 ms)
        XCTAssertEqual(c.effectiveBorderCycleSeconds, 120, accuracy: 0.0001,
                       "border ceiling")
        XCTAssertEqual(c.effectiveThemeCycleSeconds, 1, accuracy: 0.0001,
                       "theme floor — independent of the border cycle")
    }

    func testPerViewThemeInheritsAndOverrides() {
        var c = FacetConfig()
        c.theme = "dracula"
        XCTAssertEqual(c.effectiveTreeTheme, "dracula", "unset → inherit")
        c.gridTheme = ""
        XCTAssertEqual(c.effectiveGridTheme, "dracula", "\"\" → inherit")
        c.railTheme = "github-light"
        XCTAssertEqual(c.effectiveRailTheme, "github-light", "override wins")
        c.treeTheme = "drakula"   // typo
        XCTAssertEqual(c.effectiveTreeTheme, "dracula",
                       "unknown → inherit (warned via unknownValueWarnings)")
    }

    func testEffectiveBorderBreathWidthsOptionalClamp() {
        var c = FacetConfig()
        XCTAssertNil(c.effectiveBorderMinWidth, "unset → nil")
        XCTAssertNil(c.effectiveBorderMaxWidth, "unset → nil")
        c.borderMinWidth = 0    // below floor
        c.borderMaxWidth = 99   // above ceiling
        // Exact (0.5 / 30 are representable); CGFloat(...) keeps the
        // Optional comparison unambiguous — no `accuracy:` on Optionals.
        XCTAssertEqual(c.effectiveBorderMinWidth, CGFloat(0.5))
        XCTAssertEqual(c.effectiveBorderMaxWidth, CGFloat(30))
    }
}
