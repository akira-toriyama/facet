import XCTest
@testable import FacetCore

/// The two projection `WindowFields` adapters that overlay extra context onto
/// a bare `Window` before a `FacetFilter` evaluates it:
///
/// - `ProjectedWindowFields` (FilterProjection / the section-lens park scan) —
///   adds the containing workspace NAME; everything else delegates to `Window`.
/// - `ApplyPlanWindowFields` (ApplyResolver) — replays an ordered `ApplyOp`
///   list onto the base window (tags + last-writer-wins floating/sticky/master
///   overlays) so the post-apply state is filtered, not the pre-apply one.
///
/// These tests pin the FALLBACK / coalescing branches (`?? base`, empty →
/// nil-vs-"" , unknown field → delegate) — including the deliberate asymmetry
/// where an empty workspace name reads back as `""` from the projection but
/// `nil` from the apply-plan. Pure; CI-only (CLT can't run `swift test`).
final class WindowFieldsFallbackTests: XCTestCase {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false,
                     sticky: Bool = false, master: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil,
               isMaster: master, isSticky: sticky, tags: tags)
    }

    // MARK: - ProjectedWindowFields

    func testProjectedWorkspaceOverlay() {
        let f = ProjectedWindowFields(window: win(1), workspaceName: "Dev")
        XCTAssertEqual(f.filterValue("workspace"), "Dev")
        XCTAssertTrue(f.filterHas("workspace"))
    }

    func testProjectedEmptyWorkspaceReadsAsEmptyStringAndHasTrue() {
        // EX-3 迷子: presence is ASSIGNMENT-gated (`workspaceName != nil`), NOT
        // emptiness-gated. An assigned-but-UNNAMED workspace (name `""`) reads
        // its name back verbatim as `""` AND is PRESENT (`filterHas == true`),
        // so a `not workspace` lens does NOT catch it — only a true orphan
        // (`nil`) does. This is the deliberate nil-vs-`""` distinction (the
        // 迷子 receptacle keys off the ASSIGNMENT, never the display name). It
        // still differs from ApplyPlanWindowFields below, which coalesces the
        // empty name to `nil` (so `filterHas == false` there).
        let f = ProjectedWindowFields(window: win(1), workspaceName: "")
        XCTAssertEqual(f.filterValue("workspace"), "")
        XCTAssertTrue(f.filterHas("workspace"))
    }

    func testProjectedDelegatesNonWorkspaceFields() {
        let f = ProjectedWindowFields(window: win(1, app: "Safari", tags: ["web"]),
                                      workspaceName: "Dev")
        XCTAssertEqual(f.filterValue("app"), "Safari")          // → Window
        XCTAssertEqual(f.filterValue("tag"), "web")
        XCTAssertTrue(f.filterHas("tag"))
        XCTAssertNil(f.filterValue("bogus"))                    // unknown → nil
        XCTAssertFalse(f.filterHas("bogus"))
    }

    // MARK: - ApplyPlanWindowFields — empty / unknown fallbacks

    func testApplyPlanEmptyWorkspaceIsNil() {
        // Unlike the projection, the apply-plan coalesces an empty name to nil.
        let f = ApplyPlanWindowFields(base: win(1), workspaceName: "", applying: [])
        XCTAssertNil(f.filterValue("workspace"))
        XCTAssertFalse(f.filterHas("workspace"))
    }

    func testApplyPlanEmptyTagsAreNil() {
        let f = ApplyPlanWindowFields(base: win(1, tags: []), workspaceName: "Dev",
                                      applying: [])
        XCTAssertNil(f.filterValue("tag"))
        XCTAssertFalse(f.filterHas("tag"))
    }

    func testApplyPlanDelegatesUnknownFieldToBase() {
        let f = ApplyPlanWindowFields(base: win(1, app: "Safari"),
                                      workspaceName: "Dev", applying: [])
        XCTAssertEqual(f.filterValue("app"), "Safari")          // → base
        XCTAssertTrue(f.filterHas("app"))
        XCTAssertNil(f.filterValue("bogus"))
        XCTAssertFalse(f.filterHas("bogus"))
    }

    // MARK: - ApplyPlanWindowFields — overlay coalescing (`?? base`)

    func testApplyPlanFloatingFallsBackToBaseWhenNoOp() {
        // No setFloating op → overlay is nil → reads the BASE value.
        let onBase = ApplyPlanWindowFields(base: win(1, floating: true),
                                           workspaceName: "Dev", applying: [])
        XCTAssertEqual(onBase.filterValue("floating"), "true")
        XCTAssertTrue(onBase.filterHas("floating"))
    }

    func testApplyPlanFloatingOverlayWinsOverBase() {
        // setFloating(false) overrides a base that is floating=true.
        let overridden = ApplyPlanWindowFields(base: win(1, floating: true),
                                               workspaceName: "Dev",
                                               applying: [.setFloating(false)])
        XCTAssertEqual(overridden.filterValue("floating"), "false")
        XCTAssertFalse(overridden.filterHas("floating"))
    }

    func testApplyPlanStickyAndMasterCoalesce() {
        let base = win(1, sticky: true, master: false)
        let noOps = ApplyPlanWindowFields(base: base, workspaceName: "Dev",
                                          applying: [])
        XCTAssertTrue(noOps.filterHas("sticky"))                // base true
        XCTAssertFalse(noOps.filterHas("master"))               // base false
        let setMa = ApplyPlanWindowFields(base: base, workspaceName: "Dev",
                                          applying: [.setMaster(true),
                                                     .setSticky(false)])
        XCTAssertEqual(setMa.filterValue("master"), "true")     // overlay
        XCTAssertEqual(setMa.filterValue("sticky"), "false")    // overlay
    }

    // MARK: - ApplyPlanWindowFields — ordered tag ops

    func testApplyPlanTagOpsApplyInOrder() {
        // MOVE replay: removeTag(inverse) THEN addTag(forward) — a tag pulled
        // by the inverse and re-added by the forward resolves to PRESENT.
        let f = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                      workspaceName: "Dev",
                                      applying: [.removeTag("web"), .addTag("web")])
        XCTAssertEqual(f.filterValue("tag"), "web")
        XCTAssertTrue(f.filterHas("tag"))
    }

    func testApplyPlanAddTagIsIdempotentAndRemoveClears() {
        let dup = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                        workspaceName: "Dev",
                                        applying: [.addTag("web")])
        XCTAssertEqual(dup.filterValue("tag"), "web")           // no duplicate
        let cleared = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                            workspaceName: "Dev",
                                            applying: [.removeTag("web")])
        XCTAssertNil(cleared.filterValue("tag"))                // empty → nil
        XCTAssertFalse(cleared.filterHas("tag"))
    }
}
