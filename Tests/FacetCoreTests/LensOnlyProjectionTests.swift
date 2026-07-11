import Testing
@testable import FacetCore

/// These pin the LENS DESKTOP projection route (t-0sbm → t-ec9s):
/// `FilterProjection.projectLensDesktop` — the dedicated path a `[desktop.N]
/// type=lens` mac desktop feeds. Section-lens is retired (t-ec9s: `project()`
/// no longer does lens membership; every `[[desktop.N.section]]` is a workspace
/// cell), so lens matching lives ONLY here now. A lens desktop is a FILTERED
/// view: a window matching the lens is shown, one matching nothing is HIDDEN
/// (not tail-appended) unless `show-non-matching` declares the holding
/// `unassigned` receptacle (W2.6). The window stays live (parked, still on the
/// desktop — not lost). These PIN that intended projection so a future change
/// can't silently flip it. Pure; CI-only (CLT can't run `swift test`).
struct LensOnlyProjectionTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil, tags: [])
    }
    private func ws(_ index: Int, _ windows: [Window]) -> Workspace {
        Workspace(index: index, name: "WS", isActive: index == 0,
                  layoutMode: "float", windows: windows)
    }

    /// A lens desktop hides a window matching no lens (no workspace tail).
    @Test func lensDesktopHidesUnmatchedWindow() {
        let wss = [ws(0, [win(1, app: "Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, match: "app=Chrome", label: "Web",
            showNonMatching: false)
        #expect(r.sections.count == 1, "exactly the lens — no workspace tail")
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])
        let shownIDs = r.sections.flatMap { $0.windows.map(\.id.serverID) }
        #expect(!shownIDs.contains(2),
                "a window matching no lens is hidden on a lens desktop")
    }

    /// The `show-non-matching` receptacle on the lens desktop catches the
    /// unmatched window (the W2.6 opt-in lost-and-found).
    @Test func unassignedReceptacleCatchesUnmatchedOnLensDesktop() {
        let wss = [ws(0, [win(1, app: "Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, match: "app=Chrome", label: "Web",
            showNonMatching: true)
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
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, orphans: [win(9, app: "Finder")],
            match: "app=Chrome", label: "Web", showNonMatching: true)
        #expect(r.sections.count == 2, "lens + receptacle — no workspace tail")
        let web = r.sections.first { $0.id == "section:0:Web" }
        #expect(web?.windows.map(\.id.serverID) == [1])
        let lost = r.sections.first { $0.sectionType == .unassigned }
        #expect(lost?.windows.map(\.id.serverID) == [2, 3, 9],
                "unmatched workspace windows (snapshot order) then orphan last")
    }
}
