import Testing
import Foundation
import CoreGraphics
@testable import FacetCore

struct FacetConfigTests {

    // MARK: - effective accessors

    @Test func effectiveRailEdgeClampsToBottom() {
        var c = FacetConfig()
        #expect(c.effectiveRailEdge == .bottom, "unset → bottom")
        c.railEdge = "LEFT"
        #expect(c.effectiveRailEdge == .left, "case-insensitive")
        c.railEdge = "top"
        #expect(c.effectiveRailEdge == .top)
        c.railEdge = "diagonal"
        #expect(c.effectiveRailEdge == .bottom, "unknown → bottom")
    }

    @Test func effectiveRailCellsClamps() {
        var c = FacetConfig()
        #expect(c.effectiveRailCells == 7, "default")
        c.railCells = 10
        #expect(c.effectiveRailCells == 10)
        c.railCells = 0
        #expect(c.effectiveRailCells == 1, "floor 1")
        c.railCells = 999
        #expect(c.effectiveRailCells == 20, "ceiling 20")
    }

    @Test func effectiveThemeFallsBackToTerminal() {
        var c = FacetConfig()
        #expect(c.effectiveTheme == "terminal")
        c.theme = "Dracula"
        #expect(c.effectiveTheme == "dracula",
                "a known name resolves case-insensitively")
        c.theme = "nonsuch-theme"
        #expect(c.effectiveTheme == "terminal",
                "unknown theme name → default")
        c.theme = "nord"
        #expect(c.effectiveTheme == "terminal",
                "a Phase-V-cut theme name (nord) → default")
    }

    @Test func effectiveGridColsClampsAndDefaults() {
        var c = FacetConfig()
        #expect(c.effectiveGridCols == 4, "default")
        c.gridCols = 0
        #expect(c.effectiveGridCols == 1, "clamp low")
        c.gridCols = 99
        #expect(c.effectiveGridCols == 12, "clamp high")
        c.gridCols = 6
        #expect(c.effectiveGridCols == 6)
    }

    @Test func effectiveThumbnailRefreshInterval() {
        var c = FacetConfig()
        #expect(c.effectiveThumbnailRefreshInterval == 4)
        c.thumbnailRefreshSeconds = 0
        #expect(c.effectiveThumbnailRefreshInterval == nil,
                "0 disables background capture")
        c.thumbnailRefreshSeconds = 200
        #expect(c.effectiveThumbnailRefreshInterval == 60,
                "clamp high")
    }

    @Test func effectiveWorkspaceListSectionInactiveYieldsDefaults() {
        // No section model on a desktop → defaultWorkspaceCount unnamed slots.
        let c = FacetConfig()
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
        #expect(list.allSatisfy { $0.config.layout == nil })
    }

    // MARK: - [tree] line-pets

    @Test func effectiveTreeLinePetsDefaultsEmpty() {
        let c = FacetConfig()
        #expect(c.effectiveTreeLinePets == [], "unset → off")
    }

    @Test func effectiveTreeLinePetsNormalizes() {
        var c = FacetConfig()
        c.treeLinePets = ["Chomp", "  ghost ", ""]
        #expect(c.effectiveTreeLinePets == ["chomp", "ghost"],
                "lower-cased, trimmed, empty entries dropped, order kept")
    }

    @Test func treeLinePetsParsesArrayOnly() {
        let arr = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            line-pets = ["chomp", "ghost"]
            """))
        #expect(arr.effectiveTreeLinePets == ["chomp", "ghost"],
                "TOML array form")
        // The old lenient comma-string form is retired (family grammar:
        // arrays are arrays) — a string value is ignored, pets stay off.
        let csv = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            line-pets = "chomp, ghost"
            """))
        #expect(csv.effectiveTreeLinePets == [],
                "comma-string form no longer parses")
    }

    @Test func effectiveTreePetScaleDefaultsAndClamps() {
        var c = FacetConfig()
        #expect(c.effectiveTreePetScale == 0.9, "default")
        c.treePetScale = 1.5
        #expect(c.effectiveTreePetScale == 1.5)
        c.treePetScale = -3
        #expect(c.effectiveTreePetScale == 0.1, "floor 0.1")
    }

    @Test func effectiveTreePetLapSecondsDefaultsAndClamps() {
        var c = FacetConfig()
        #expect(c.effectiveTreePetLapSeconds == 8, "default")
        c.treePetLapSeconds = 12
        #expect(c.effectiveTreePetLapSeconds == 12)
        c.treePetLapSeconds = 0
        #expect(c.effectiveTreePetLapSeconds == 0.5, "floor 0.5")
    }

    @Test func treePetScaleParsesFloatViaTOML() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [tree]
            pet-scale = 1.25
            pet-lap-seconds = 6
            """))
        #expect(c.effectiveTreePetScale == 1.25,
                "fractional pet-scale survives the new .double parse")
        #expect(c.effectiveTreePetLapSeconds == 6)
    }

    // MARK: - [[exclude]] rules

    @Test func exclusionRulesParsedFromTOML() {
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
        #expect(rules.count == 3)
        #expect(rules[0].matcher.app == "com.apple.finder")
        #expect(rules[0].action == .float)
        #expect(rules[1].matcher.title == "^$")
        #expect(rules[1].matcher.maxWidth == 400)
        #expect(rules[1].action == .ignore)
        // No explicit action → defaults to float.
        #expect(rules[2].matcher.subrole == "AXDialog")
        #expect(rules[2].action == .float)
    }

    @Test func exclusionRuleWithNoMatchKeyDropped() {
        // A `[[exclude]]` with only `action` (no match key) is a
        // mistake and is dropped (it would match nothing anyway).
        let rules = FacetConfig.exclusionRules(fromTOML: """
            [[exclude]]
            action = "ignore"

            [[exclude]]
            app = "x"
            """)
        #expect(rules.count == 1)
        #expect(rules[0].matcher.app == "x")
    }

    @Test func exclusionRulesEmptyWhenAbsent() {
        let c = FacetConfig()
        #expect(c.effectiveExclusionRules.isEmpty)
        #expect(FacetConfig.exclusionRules(fromTOML: """
            [grid]
            cols = 2
            """).isEmpty)
    }

    // MARK: - TOML mapping

    @Test func fromTOMLMapsAllRecognisedKeys() {
        let parsed = parseTOMLSubset("""
            [theme]
            name = "dracula"

            [grid]
            cols = 6
            label-position = "down"
            thumbnail-refresh-seconds = 10
            theme = "github-light"
            """)
        let c = FacetConfig.from(toml: parsed)
        #expect(c.effectiveTheme == "dracula")
        #expect(c.effectiveGridTheme == "github-light",
                "per-view override parses")
        #expect(c.effectiveTreeTheme == "dracula",
                "unset per-view key inherits [theme].name")
        #expect(c.effectiveGridCols == 6)
        #expect(c.effectiveGridLabelPosition == "down")
        #expect(c.effectiveThumbnailRefreshInterval == 10)
    }

    // MARK: - Per-mac-desktop sections

    @Test func effectiveWorkspaceListPerOrdinal() {
        // Desktop 1 has a section model (2 workspace sections); desktop 2 has
        // none → its own default slots. The workspace sections carry no label,
        // so their names are EMPTY (unnamed → displayed by 1-based index, §B;
        // the `[desktop.N]` by-name seed was retired).
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace),
            DesktopSection(type: .workspace, layout: "bsp"),
        ]]

        // Section-active ordinal → one slot per workspace section.
        let configured = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(configured.count == 2)
        #expect(configured.map(\.config.layout) == [nil, "bsp"])
        #expect(configured.allSatisfy { $0.config.name.isEmpty })  // unnamed (§B)
        // Unconfigured ordinal → defaultWorkspaceCount unnamed slots.
        let unconfigured = c.effectiveWorkspaceList(forMacDesktopOrdinal: 2)
        #expect(unconfigured.count == FacetConfig.defaultWorkspaceCount)
        #expect(unconfigured.allSatisfy { $0.config.name.isEmpty })
        // nil ordinal → default slots (section model never activates).
        let nilList = c.effectiveWorkspaceList(forMacDesktopOrdinal: nil)
        #expect(nilList.count == FacetConfig.defaultWorkspaceCount)
    }

    @Test func emptyTOMLYieldsAllDefaults() {
        let c = FacetConfig.from(toml: [:])
        #expect(c.effectiveTheme == "terminal")
        #expect(c.effectiveGridCols == 4)
    }

    // MARK: - Disk loader

    @Test func loadFallsBackToDefaultsForMissingConfig() {
        let tmp = NSTemporaryDirectory()
            + "facet-test-\(UUID().uuidString)/missing.toml"
        defer {
            let dir = (tmp as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        let c = FacetConfig.load(path: tmp)
        #expect(c.effectiveTheme == "terminal",
                "missing config → default-init'd config")
    }

    // MARK: - unknownValueWarnings (silent-clamp surfacing)

    @Test func noWarningsForDefaultConfig() {
        #expect(FacetConfig().unknownValueWarnings().isEmpty,
                "every key unset → nothing was clamped")
    }

    @Test func noWarningsForValidValues() {
        var c = FacetConfig()
        c.theme = "dracula"
        c.defaultLayout = "bsp"
        c.railEdge = "left"
        c.treePreviewMode = "mirror"
        c.animationCurve = "spring"
        c.gridLabelPosition = "down"
        #expect(c.unknownValueWarnings().isEmpty,
                "all recognised → no warnings")
    }

    @Test func validValuesAreCaseInsensitive() {
        var c = FacetConfig()
        c.defaultLayout = "BSP"
        c.theme = "Dracula"
        c.railEdge = "LEFT"
        #expect(c.unknownValueWarnings().isEmpty,
                "a known name in any case is not a clamp")
    }

    @Test func unknownLayoutWarns() {
        var c = FacetConfig()
        // `tall` was renamed to `master-left` (#139); an old config
        // carrying it now silently clamps to `float`.
        c.defaultLayout = "tall"
        let w = c.unknownValueWarnings()
        #expect(w.count == 1)
        #expect(w[0].contains("layout"), "names the key")
        #expect(w[0].contains("tall"), "echoes the written value")
        #expect(w[0].contains("float"), "names the fallback")
    }

    @Test func multipleUnknownsEachWarnOnce() {
        var c = FacetConfig()
        c.defaultLayout = "nonsuch-layout"
        c.theme = "nonsuch-theme"
        c.railEdge = "diagonal"
        #expect(c.unknownValueWarnings().count == 3,
                "one warning per clamped key")
    }

    @Test func emptyStringIsNotAWarning() {
        var c = FacetConfig()
        c.defaultLayout = ""
        #expect(c.unknownValueWarnings().isEmpty,
                "empty string is treated like unset, not a typo")
    }

    // MARK: - effectiveRaiseOnOpen ([window] raise-on-open)

    private func raiseMode(_ raw: String?) -> RaiseOnOpen {
        var c = FacetConfig()
        c.raiseOnOpen = raw
        return c.effectiveRaiseOnOpen
    }

    @Test func raiseOnOpenDefaultsToRaise() {
        #expect(raiseMode(nil) == .raise)
    }

    @Test func raiseOnOpenParsesEachCase() {
        #expect(raiseMode("raise") == .raise)
        #expect(raiseMode("activate") == .activate)
        #expect(raiseMode("off") == .off)
    }

    @Test func raiseOnOpenIsCaseInsensitive() {
        #expect(raiseMode("ACTIVATE") == .activate)
        #expect(raiseMode("Off") == .off)
    }

    @Test func raiseOnOpenUnknownClampsToRaise() {
        #expect(raiseMode("bogus") == .raise)
        #expect(raiseMode("") == .raise)
    }

    // MARK: - effectiveRailStrip

    @Test func effectiveRailStripClamps() {
        var c = FacetConfig()
        #expect(c.effectiveRailStrip == 30, "default")
        c.railStrip = 20
        #expect(c.effectiveRailStrip == 20)
        c.railStrip = 1
        #expect(c.effectiveRailStrip == 8, "floor 8")
        c.railStrip = 999
        #expect(c.effectiveRailStrip == 50, "ceiling 50")
    }

    // MARK: - effectiveTreeGeometry

    @Test func effectiveTreeGeometryNeedsAllFour() {
        var c = FacetConfig()
        #expect(c.effectiveTreeGeometry == nil, "all unset → nil")
        c.treePosX = 10; c.treePosY = 20; c.treeWidth = 300; c.treeHeight = 400
        #expect(c.effectiveTreeGeometry ==
                CGRect(x: 10, y: 20, width: 300, height: 400))
        c.treeHeight = nil
        #expect(c.effectiveTreeGeometry == nil, "one missing → nil")
    }

    @Test func effectiveTreeGeometryRejectsNonPositiveSize() {
        var c = FacetConfig()
        c.treePosX = 0; c.treePosY = 0; c.treeWidth = 0; c.treeHeight = 400
        #expect(c.effectiveTreeGeometry == nil, "width 0 → nil")
        c.treeWidth = 300; c.treeHeight = 0
        #expect(c.effectiveTreeGeometry == nil, "height 0 → nil")
    }

    @Test func treeGeometryPartialWarns() {
        var c = FacetConfig()
        c.treePosX = 10   // only 1 of 4
        #expect(c.unknownValueWarnings().contains {
            $0.contains("[tree] geometry needs all of")
        }, "partial geometry warns")
        c.treePosY = 20; c.treeWidth = 300; c.treeHeight = 400
        #expect(!(c.unknownValueWarnings().contains {
            $0.contains("[tree] geometry needs all of")
        }), "all four → no warning")
    }

    // MARK: - allow-list accessors (border effect / tree preview mode)

    @Test func effectiveBorderEffectAllowList() {
        var c = FacetConfig()
        #expect(c.effectiveBorderEffect == "off", "default")
        c.borderEffect = "NEON"
        #expect(c.effectiveBorderEffect == "neon", "case-insensitive")
        c.borderEffect = "sparkle"
        #expect(c.effectiveBorderEffect == "off", "unknown → off")
    }

    @Test func effectiveTreePreviewModeAllowList() {
        var c = FacetConfig()
        #expect(c.effectiveTreePreviewMode == "popover", "default")
        c.treePreviewMode = "Mirror"
        #expect(c.effectiveTreePreviewMode == "mirror", "case-insensitive")
        c.treePreviewMode = "fullscreen"
        #expect(c.effectiveTreePreviewMode == "popover", "unknown → popover")
    }

    // MARK: - border / cycle numeric clamps

    @Test func effectiveBorderWidthClamps() {
        var c = FacetConfig()
        #expect(abs(c.effectiveBorderWidth - 1.5) < 0.0001, "default")
        c.borderWidth = 4
        #expect(abs(c.effectiveBorderWidth - 4) < 0.0001)
        c.borderWidth = 0.1
        #expect(abs(c.effectiveBorderWidth - 0.5) < 0.0001, "floor")
        c.borderWidth = 99
        #expect(abs(c.effectiveBorderWidth - 30) < 0.0001, "ceiling")
    }

    @Test func borderAndThemeCycleClampIndependently() {
        var c = FacetConfig()
        #expect(abs(c.effectiveBorderCycleSeconds - 6) < 0.0001,
                "border default (6000 ms)")
        #expect(abs(c.effectiveThemeCycleSeconds - 6) < 0.0001,
                "theme default (6000 ms)")
        c.borderColorCycleMs = 200_000   // over ceiling (120000 ms)
        c.themeColorCycleMs = 0          // under floor (1000 ms)
        #expect(abs(c.effectiveBorderCycleSeconds - 120) < 0.0001,
                "border ceiling")
        #expect(abs(c.effectiveThemeCycleSeconds - 1) < 0.0001,
                "theme floor — independent of the border cycle")
    }

    @Test func perViewThemeInheritsAndOverrides() {
        var c = FacetConfig()
        c.theme = "dracula"
        #expect(c.effectiveTreeTheme == "dracula", "unset → inherit")
        c.gridTheme = ""
        #expect(c.effectiveGridTheme == "dracula", "\"\" → inherit")
        c.railTheme = "github-light"
        #expect(c.effectiveRailTheme == "github-light", "override wins")
        c.treeTheme = "drakula"   // typo
        #expect(c.effectiveTreeTheme == "dracula",
                "unknown → inherit (warned via unknownValueWarnings)")
    }

    @Test func effectiveBorderBreathWidthsOptionalClamp() {
        var c = FacetConfig()
        #expect(c.effectiveBorderMinWidth == nil, "unset → nil")
        #expect(c.effectiveBorderMaxWidth == nil, "unset → nil")
        c.borderMinWidth = 0    // below floor
        c.borderMaxWidth = 99   // above ceiling
        // Exact (0.5 / 30 are representable); CGFloat(...) keeps the
        // Optional comparison unambiguous — no `accuracy:` on Optionals.
        #expect(c.effectiveBorderMinWidth == CGFloat(0.5))
        #expect(c.effectiveBorderMaxWidth == CGFloat(30))
        // Fractional in-range values survive (the fields are CGFloat,
        // like the sibling `width` — a `.5` is no longer dropped by an
        // integer decode). Regression pin for config-01.
        c.borderMinWidth = 1.5
        c.borderMaxWidth = 4.5
        #expect(c.effectiveBorderMinWidth == CGFloat(1.5))
        #expect(c.effectiveBorderMaxWidth == CGFloat(4.5))
    }

    @Test func fromTOMLDecodesFractionalBorderBreathWidths() {
        // config-01: the DECODE path is the real bug site — when these
        // were `.int`/asInt, a fractional `min-width = 0.5` was silently
        // dropped (asInt returns nil for a TOML double). As `.cgDbl`
        // they decode like the sibling `width`.
        let parsed = parseTOMLSubset("""
            [border]
            min-width = 0.5
            max-width = 4.5
            """)
        let c = FacetConfig.from(toml: parsed)
        #expect(c.borderMinWidth == CGFloat(0.5),
                "fractional min-width decodes (was dropped under .int)")
        #expect(c.borderMaxWidth == CGFloat(4.5))
    }
}
