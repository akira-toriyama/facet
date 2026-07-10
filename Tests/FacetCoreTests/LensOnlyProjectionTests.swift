import Testing
@testable import FacetCore

/// N6: these test `FilterProjection.project` DIRECTLY with a lens-only
/// `sections` list — the exact input a LENS DESKTOP feeds it (t-0sbm:
/// `lensDesktopSections` synthesizes one lens section, plus an `unassigned`
/// receptacle only when `show-non-matching` is set), a combination the old
/// workspace-tail invariant comment assumed impossible. A lens desktop is a
/// FILTERED view: a window matching no lens is HIDDEN (not tail-appended),
/// unless an `unassigned` receptacle is declared (W2.6). The window stays live
/// (it is not lost — it is parked, still on the desktop). These tests PIN that
/// intended projection behavior so a future change can't silently flip it.
/// Pure; CI-only (CLT can't run `swift test`).
struct LensOnlyProjectionTests {

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

    /// A lens-only list hides a window matching no lens (no workspace tail).
    @Test func lensOnlyListHidesUnmatchedWindow() {
        let wss = [ws(0, [win(1, app: "Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [lens("Web", "app=Chrome")])
        #expect(r.sections.count == 1, "exactly the lens — no workspace tail")
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])
        let shownIDs = r.sections.flatMap { $0.windows.map(\.id.serverID) }
        #expect(!shownIDs.contains(2),
                "a window matching no lens is hidden on a lens desktop")
    }

    /// An `unassigned` receptacle on the lens desktop catches the unmatched window
    /// (the W2.6 opt-in lost-and-found).
    @Test func unassignedReceptacleCatchesUnmatchedOnLensDesktop() {
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
    /// promise that a lens desktop loses no live window: reordering the
    /// universe concat or dropping subsequent unmatched windows would silently
    /// hide live windows undetected (the one-window sibling test can't catch a
    /// concat/order regression).
    @Test func lensDesktopReceptacleCatchesMultipleUnmatchedInUniverseOrder() {
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
