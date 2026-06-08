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

    func testEffectiveTagModelEmptyWhenNone() {
        XCTAssertTrue(FacetConfig().effectiveTagModel.isEmpty)
    }

    // MARK: - [[assign]]

    func testAssignSingleTag() {
        let rules = FacetConfig.assignRules(fromTOML: """
        [[assign]]
        app = "com.google.Chrome"
        tag = "web"
        """)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].tags, ["web"])
        XCTAssertEqual(rules[0].matcher.app, "com.google.Chrome")
    }

    func testAssignTagsArrayAndDedup() {
        let rules = FacetConfig.assignRules(fromTOML: """
        [[assign]]
        title = "GitHub"
        tag = "work"
        tags = ["web", "work"]
        """)
        XCTAssertEqual(rules.count, 1)
        // tag + tags unioned, de-duped, order preserved.
        XCTAssertEqual(rules[0].tags, ["work", "web"])
    }

    func testAssignDropsInertRules() {
        // No match key → inert; no tag → inert. Both dropped.
        let rules = FacetConfig.assignRules(fromTOML: """
        [[assign]]
        tag = "web"
        [[assign]]
        app = "X"
        """)
        XCTAssertTrue(rules.isEmpty)
    }

    // MARK: - fatalConfigErrors (Fail Fast)

    private func tagConfig(layout: String = "grid",
                           tags: [String] = ["work", "web"],
                           assigns: [AssignRule] = []) -> FacetConfig {
        var c = FacetConfig()
        c.grouping = "tag"
        c.defaultLayout = layout
        if !tags.isEmpty { c.tagDefs = tags }
        if !assigns.isEmpty { c.assignRules = assigns }
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

    func testAssignReferencingUnknownTagIsFatal() {
        let c = tagConfig(assigns: [
            AssignRule(matcher: WindowMatcher(app: "X"), tags: ["ghost"]),
        ])
        XCTAssertTrue(c.fatalConfigErrors().contains {
            $0.contains("unknown tag") && $0.contains("ghost")
        })
    }

    func testAssignReferencingKnownTagIsClean() {
        let c = tagConfig(assigns: [
            AssignRule(matcher: WindowMatcher(app: "X"), tags: ["web"]),
        ])
        XCTAssertTrue(c.fatalConfigErrors().isEmpty)
    }
}
