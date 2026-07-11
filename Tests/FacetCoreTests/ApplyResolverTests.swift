import Testing
@testable import FacetCore

/// `ApplyResolver` — the pure validator for the section-model DnD MOVE. Since
/// the section-lens type was retired (t-ec9s), a MOVE is always a workspace
/// MEMBERSHIP move (ws→ws or the §G orphan rescue onto a workspace); the dest
/// must be a `"ws:"` id, else the drop is inert. Pure; CI-only (CLT can't run
/// `swift test`).
struct ApplyResolverTests {

    private func win(_ id: Int, app: String = "App", sticky: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil,
               isMaster: false, isSticky: sticky, tags: [])
    }

    // MARK: - workspace membership move (ws → ws)

    @Test func planWorkspaceToWorkspaceMove() {
        // ws→ws: a pure membership move via destWorkspaceIndex.
        let p = ApplyResolver.plan(
            window: win(1), fromSectionID: "ws:0", toSectionID: "ws:1",
            destWorkspaceIndex: 1)
        #expect(!p.isInert)
        #expect(p.destWorkspaceIndex == 1)
    }

    @Test func planSameSectionIsInert() {
        let p = ApplyResolver.plan(
            window: win(1), fromSectionID: "ws:1", toSectionID: "ws:1",
            destWorkspaceIndex: 1)
        #expect(p.isInert)
    }

    @Test func planStickyToWorkspaceIsInert() {
        // moveWindow rejects sticky windows → snap-back rather than no-op.
        let p = ApplyResolver.plan(
            window: win(1, sticky: true), fromSectionID: "ws:0", toSectionID: "ws:1",
            destWorkspaceIndex: 1)
        #expect(p.isInert)
    }

    // MARK: - §G rescue (orphan under the unassigned receptacle → workspace)

    /// A TRUE orphan dragged OUT of the unassigned receptacle ONTO a workspace is
    /// filed there — moved via destWorkspaceIndex, never inert.
    @Test func planUnassignedToWorkspaceRescue() {
        let p = ApplyResolver.plan(
            window: win(9, app: "Chrome"), fromSectionID: "unassigned:2",
            toSectionID: "ws:1", destWorkspaceIndex: 1)
        #expect(!p.isInert,
            "rescue from the unassigned receptacle onto a workspace is allowed")
        #expect(p.destWorkspaceIndex == 1)
    }

    // MARK: - non-workspace destinations are inert (snap-back)

    @Test func planDropOntoUnassignedIsInert() {
        // Dropping a window onto the unassigned receptacle is inert (a passive
        // lost-and-found, not a move target) → snap-back.
        let p = ApplyResolver.plan(
            window: win(1), fromSectionID: "ws:0", toSectionID: "unassigned:1",
            destWorkspaceIndex: nil)
        #expect(p.isInert)
    }

    @Test func planDropOntoStaleSectionIDIsInert() {
        // A leftover `"section:"` id (there are no lens sections anymore) is not a
        // workspace dest → inert. Guards against a stale drop from an old build.
        let p = ApplyResolver.plan(
            window: win(1), fromSectionID: "ws:0", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil)
        #expect(p.isInert)
    }
}
