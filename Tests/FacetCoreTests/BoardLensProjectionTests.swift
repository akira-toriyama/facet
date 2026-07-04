import Testing
@testable import FacetCore

/// N6 (board review follow-up): these test `FilterProjection.project` DIRECTLY
/// with a lens-only `sections` list — the exact input a SELECTED lens board
/// feeds it under the board model (t-wrd2), a combination the old workspace-tail
/// invariant comment assumed impossible (the Controller routes it at
/// `Controller.swift` apply() when the board is lens-only but the model is
/// active). A lens board is a FILTERED view: a workspace window matching no lens
/// on the board is HIDDEN (not tail-appended), unless the board declares an
/// `unassigned` receptacle (W2.6). The window stays live (it is not lost —
/// switching back to the workspace board shows it). These tests PIN that
/// intended projection behavior so a future change can't silently flip it.
/// Pure; CI-only (CLT can't run `swift test`).
struct BoardLensProjectionTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil, tags: [])
    }
    private func ws(_ index: Int, _ windows: [Window]) -> Workspace {
        Workspace(index: index, name: "WS", isActive: index == 0,
                  layoutMode: "float", windows: windows)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    /// A lens-only board hides a window matching no lens (no workspace tail).
    @Test func lensOnlyBoardHidesUnmatchedWindow() {
        let wss = [ws(0, [win(1, app: "Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [lens("Web", "app=Chrome")])
        #expect(r.sections.count == 1, "exactly the lens — no workspace tail")
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])
        let shownIDs = r.sections.flatMap { $0.windows.map(\.id.serverID) }
        #expect(!shownIDs.contains(2),
                "a window matching no lens is hidden on a lens board")
    }

    /// An `unassigned` receptacle on the lens board catches the unmatched window
    /// (the W2.6 opt-in lost-and-found).
    @Test func unassignedReceptacleCatchesUnmatchedOnLensBoard() {
        let wss = [ws(0, [win(1, app: "Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [lens("Web", "app=Chrome"),
                       DesktopSection(type: .lens, label: "Other", unassigned: true)])
        let other = r.sections.first { $0.sectionType == .unassigned }
        #expect(other?.windows.map(\.id.serverID) == [2],
                "the unassigned receptacle catches the unmatched window")
    }

    /// The receptacle catches EVERY unmatched window — multiple leftover
    /// workspace windows AND an orphan — in universe order: unmatched workspace
    /// windows first (snapshot order), the orphan appended last. Pins the core
    /// board promise that a lens board loses no live window: reordering the
    /// universe concat or dropping subsequent unmatched windows would silently
    /// hide live windows undetected (the one-window sibling test can't catch a
    /// concat/order regression).
    @Test func lensBoardReceptacleCatchesMultipleUnmatchedInUniverseOrder() {
        let wss = [ws(0, [win(1, app: "Chrome"),
                          win(2, app: "Terminal"),
                          win(3, app: "Slack")])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [lens("Web", "app=Chrome"),
                       DesktopSection(type: .lens, label: "Lost", unassigned: true)],
            orphans: [win(9, app: "Finder")])
        #expect(r.sections.count == 2, "lens + receptacle — no workspace tail")
        let web = r.sections.first { $0.id == "section:0:Web" }
        #expect(web?.windows.map(\.id.serverID) == [1])
        let lost = r.sections.first { $0.sectionType == .unassigned }
        #expect(lost?.windows.map(\.id.serverID) == [2, 3, 9],
                "unmatched workspace windows (snapshot order) then orphan last")
    }
}
