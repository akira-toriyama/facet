import XCTest
@testable import FacetCore

final class TagConfigTests: XCTestCase {

    // MARK: - [grouping] by

    func testGroupingParseAndDefault() {
        XCTAssertEqual(FacetConfig().effectiveGrouping, .workspace) // unset
        let tag = FacetConfig.from(toml:
            parseTOMLSubset("[grouping]\nby = \"tag\"\n"))
        XCTAssertEqual(tag.effectiveGrouping, .tag)
        let ws = FacetConfig.from(toml:
            parseTOMLSubset("[grouping]\nby = \"workspace\"\n"))
        XCTAssertEqual(ws.effectiveGrouping, .workspace)
    }

    func testGroupingTypoClampsToWorkspace() {
        let c = FacetConfig.from(toml:
            parseTOMLSubset("[grouping]\nby = \"spaces\"\n"))
        // effective clamps, but fatalConfigErrors flags the typo loud.
        XCTAssertEqual(c.effectiveGrouping, .workspace)
        XCTAssertTrue(c.fatalConfigErrors().contains {
            $0.contains("unknown [grouping] by")
        })
    }

    // MARK: - [[tag]]

    func testTagDefsOrderDedupAndDropEmpty() {
        let names = FacetConfig.tagDefs(fromTOML: """
        [[tag]]
        name = "work"
        [[tag]]
        name = "web"
        [[tag]]
        name = ""
        [[tag]]
        name = "work"
        """)
        XCTAssertEqual(names, ["work", "web"])   // order kept, dup/empty dropped
    }

    /// #227: config tag names are normalized through `TagName.normalized`
    /// — an internal space becomes `-` so the tag is reachable from the
    /// space-separated CLI, and a name carrying a forbidden delimiter is
    /// dropped (like an empty one).
    func testTagDefsNormalizesSpacesAndDropsInvalid() {
        let names = FacetConfig.tagDefs(fromTOML: """
        [[tag]]
        name = "my tag"
        [[tag]]
        name = "a:b"
        [[tag]]
        name = "  spaced  out  "
        """)
        XCTAssertEqual(names, ["my-tag", "spaced-out"])  // colon-name dropped
    }

    func testEffectiveTagModelEmptyWhenNone() {
        XCTAssertTrue(FacetConfig().effectiveTagModel.isEmpty)
    }

    // MARK: - fatalConfigErrors (Fail Fast)

    private func tagConfig(layout: String = "grid",
                           tags: [String] = ["work", "web"]) -> FacetConfig {
        var c = FacetConfig()
        c.grouping = "tag"
        c.defaultLayout = layout
        if !tags.isEmpty { c.tagDefs = tags }
        return c
    }

    func testWorkspaceModeNeverFatal() {
        // Default (workspace) mode skips all tag checks even with bsp.
        var c = FacetConfig()
        c.defaultLayout = "bsp"
        XCTAssertTrue(c.fatalConfigErrors().isEmpty)
    }

    func testValidTagConfigIsClean() {
        XCTAssertTrue(tagConfig(layout: "grid").fatalConfigErrors().isEmpty)
        XCTAssertTrue(tagConfig(layout: "float").fatalConfigErrors().isEmpty)
        XCTAssertTrue(tagConfig(layout: "master-left")
            .fatalConfigErrors().isEmpty)
    }

    func testTagModeWithoutTagsIsFatal() {
        let c = tagConfig(tags: [])
        XCTAssertTrue(c.fatalConfigErrors().contains { $0.contains("no [[tag]]") })
    }

    func testTagModeWithIncompatibleLayoutIsFatal() {
        for bad in ["bsp", "stack"] {
            let errs = tagConfig(layout: bad).fatalConfigErrors()
            XCTAssertTrue(errs.contains { $0.contains("not compatible") },
                          "layout=\(bad)")
        }
    }

    // MARK: - grid/rail are workspace-only views (PR-5 gate)

    func testTagModeWithGridDefaultViewIsFatal() {
        // The grid VIEW is workspace-only. NB tagConfig() already sets the
        // `grid` *layout* (valid) — this proves the gate keys off the
        // default-view, not the layout, which share the word "grid".
        var c = tagConfig(layout: "grid")
        c.defaultView = "grid"
        XCTAssertTrue(c.fatalConfigErrors().contains {
            $0.contains("default-view") && $0.contains("workspace-only")
        })
    }

    func testTagModeTreeDefaultViewIsClean() {
        var c = tagConfig()
        c.defaultView = "tree"
        XCTAssertTrue(c.fatalConfigErrors().isEmpty)
    }

    func testGridDefaultViewIsFineInWorkspaceMode() {
        // The grid view is workspace-only, so in workspace mode it's valid.
        var c = FacetConfig()
        c.defaultView = "grid"
        XCTAssertTrue(c.fatalConfigErrors().isEmpty)
    }

    func testTagModeAccumulatesBothLayoutAndViewErrors() {
        // fatalConfigErrors is Fail Fast: it surfaces EVERY problem at once,
        // never short-circuits after the first. A bsp layout (incompatible)
        // AND a grid default-view (workspace-only) must yield two distinct
        // errors — guards against a future early-return / substring-dedupe
        // regression (both messages share "workspace-only").
        var c = tagConfig(layout: "bsp")
        c.defaultView = "grid"
        let errs = c.fatalConfigErrors()
        XCTAssertEqual(errs.count, 2)
        XCTAssertTrue(errs.contains { $0.contains("not compatible") })
        XCTAssertTrue(errs.contains { $0.contains("default-view") })
    }

    func testTagModeRailDefaultViewClampsToAgentOnly() {
        // Prong 3 only flags grid because `effectiveDefaultView` clamps an
        // unknown/rail value to nil (→ agent-only), so rail can never reach
        // a workspace-only-view-at-startup state. Pin that assumption: if a
        // future change adds "rail" to the effectiveDefaultView allowlist,
        // this fails and forces a deliberate prong-3 update.
        var c = tagConfig()
        c.defaultView = "rail"
        XCTAssertNil(c.effectiveDefaultView)
        XCTAssertTrue(c.fatalConfigErrors().isEmpty)
    }
}
