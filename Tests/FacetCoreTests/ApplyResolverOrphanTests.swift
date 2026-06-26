import XCTest
@testable import FacetCore

/// EX-3.2 — `ApplyResolver` symmetric-move relocation: a ws→lens MOVE leaves the
/// source workspace (`relocateSourceToOrphan`), and the dest-lens match invariant
/// is checked against the POST-orphan workspace name (""). Pure; CI-only.
final class ApplyResolverOrphanTests: XCTestCase {

    private func win(_ id: Int, app: String = "App", tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil, tags: tags)
    }
    private func wsSec() -> DesktopSection { DesktopSection(type: .workspace) }
    private func lens(_ label: String, _ match: String,
                      apply: [ApplyOp] = []) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match, apply: apply)
    }
    /// [0] workspace, [1] "Web" tag~=web → addTag(web).
    private func sections() -> [DesktopSection] {
        [wsSec(), lens("Web", "tag~=web", apply: [.addTag("web")])]
    }

    // MARK: - relocateSourceToOrphan flag

    func testWorkspaceToLensMoveRelocatesToOrphan() {
        // Drag a window FROM the workspace (ws:0) ONTO the Web lens: it leaves
        // the workspace (relocate) + gains the lens tag. No destWorkspaceIndex
        // (a lens never relocates to a workspace).
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertTrue(p.relocateSourceToOrphan, "ws→lens MOVE leaves the workspace")
        XCTAssertEqual(p.inverse, [], "a workspace source has no additive tag to reverse")
        XCTAssertEqual(p.forward, [.addTag("web")])
        XCTAssertNil(p.destWorkspaceIndex)
    }

    func testLensToLensMoveDoesNotRelocate() {
        // Web → another lens: the source section is a TAG, not the workspace,
        // so the window keeps its workspace (no orphaning).
        let secs = [wsSec(),
                    lens("Web", "tag~=web", apply: [.addTag("web")]),
                    lens("Float", "floating=true", apply: [.setFloating(true)])]
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "section:2:Float",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertFalse(p.isInert)
        XCTAssertFalse(p.relocateSourceToOrphan, "lens→lens keeps the workspace")
    }

    func testWorkspaceToWorkspaceMoveDoesNotRelocate() {
        // ws:0 → ws:1 routes via destWorkspaceIndex, never the orphan primitive.
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "ws:1",
            destWorkspaceIndex: 1, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertFalse(p.relocateSourceToOrphan)
        XCTAssertEqual(p.destWorkspaceIndex, 1)
    }

    func testAddOntoLensDoesNotRelocate() {
        // right-click ADD (fromSectionID nil): intentional multi-match — the
        // window joins the lens AND keeps its workspace (no relocation).
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: nil, toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertFalse(p.relocateSourceToOrphan, "ADD is not a MOVE — no orphaning")
    }

    // MARK: - post-orphan match invariant (workspaceName "" in the sim)

    func testWorkspaceToLensMatchCheckedAgainstPostOrphanName() {
        // A lens that requires BOTH the tag AND "no workspace". A ws→lens MOVE
        // leaves the workspace, so the post-move state DOES satisfy it. Checking
        // against the CURRENT (non-empty) workspace name would wrongly reject.
        let secs = [wsSec(),
                    lens("Loose", "tag~=x and not workspace", apply: [.addTag("x")])]
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "section:1:Loose",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertFalse(p.isInert,
                       "post-orphan name '' satisfies `not workspace`, so the move is accepted")
        XCTAssertTrue(p.relocateSourceToOrphan)
    }

    // MARK: - §G RESCUE: orphan dragged OUT of the unassigned receptacle → workspace

    /// The headline §G use case: a TRUE orphan (in no workspace, `workspaceName
    /// == nil`) shown under the `type="unassigned"` receptacle, dragged onto a
    /// workspace. The source id is `"unassigned:<declOrder>"` (NOT `section:`),
    /// which carries no apply → empty inverse, and must NOT be treated as a
    /// stale source. The plan moves it via `destWorkspaceIndex`, no relocation.
    func testUnassignedToWorkspaceRescue() {
        let secs = [wsSec(), wsSec(),
                    DesktopSection(type: .unassigned, label: "Lost")]
        let p = ApplyResolver.plan(
            window: win(9, app: "Chrome"), workspaceName: nil,   // orphan
            fromSectionID: "unassigned:2", toSectionID: "ws:1",
            destWorkspaceIndex: 1, in: secs)
        XCTAssertFalse(p.isInert, "rescue from unassigned must NOT snap back as a stale source")
        XCTAssertFalse(p.relocateSourceToOrphan, "moving INTO a workspace never orphans")
        XCTAssertEqual(p.inverse, [], "the unassigned receptacle has no apply to reverse")
        XCTAssertEqual(p.destWorkspaceIndex, 1)
    }

    /// Dropping a window BACK onto the unassigned receptacle is inert (it is a
    /// passive lost-and-found, not an apply target) → snap-back.
    func testDropOntoUnassignedIsInert() {
        let secs = [wsSec(), DesktopSection(type: .unassigned, label: "Lost")]
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "unassigned:1",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert, "the unassigned receptacle is drop-inert (no apply)")
    }
}
