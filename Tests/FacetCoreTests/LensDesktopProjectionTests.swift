import Testing
@testable import FacetCore

/// `FilterProjection.projectLensDesktop` (board abolition t-0sbm → section-lens
/// removal t-ec9s) — a `type="lens"` mac desktop projects DIRECTLY, without
/// synthesizing a config `DesktopSection`: ONE `.lens` section (matched windows,
/// id `section:0:<label>` — the stable change-match handle), plus a holding
/// `unassigned` receptacle when `show-non-matching` is set (the non-matching
/// leftover = universe − matched). This is the ONLY route that does lens
/// membership — since t-ec9s `project()` has none (every `[[desktop.N.section]]`
/// is a workspace cell). A non-matching window is HIDDEN from the tree (not
/// tail-appended) unless the receptacle is declared; it stays live either way
/// (anchor-parked, still on the desktop — never lost). These PIN that projection
/// so a future change can't silently flip it. Pure FacetCore; CI-only.
struct LensDesktopProjectionTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    private func ws(_ index: Int, _ wins: [Window]) -> Workspace {
        Workspace(index: index, name: "", isActive: index == 0,
                  layoutMode: "float", windows: wins)
    }

    // MARK: - projection

    @Test func showFalseYieldsOnlyTheMatchedLensSection() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Code"),
                          win(3, app: "Terminal")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, match: "app~=Chrome", label: "Web",
            showNonMatching: false)
        #expect(r.sections.count == 1)
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])   // Chrome only
    }

    @Test func showTrueHoldsNonMatchingInReceptacle() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Code"),
                          win(3, app: "Terminal")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, match: "app~=Chrome", label: "Web",
            showNonMatching: true)
        #expect(r.sections.count == 2)
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])   // matched
        #expect(r.sections[1].sectionType == .unassigned)
        // holding = leftover (universe − matched) = the non-Chrome windows.
        #expect(Set(r.sections[1].windows.map(\.id.serverID)) == [2, 3])
    }

    @Test func lensSectionIdIsStableChangeMatchHandle() {
        let wss = [ws(0, [win(1, app: "Google Chrome")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, match: "app~=Chrome", label: "Web",
            showNonMatching: true)
        // declOrder 0 → the runtime change-match keys on this id.
        #expect(r.sections[0].id == "section:0:Web")
        #expect(r.sections[1].id == "unassigned:1")
    }

    @Test func orphanWindowsMatchTheLens() {
        let wss = [ws(0, [win(1, app: "Google Chrome")])]
        let orphan = win(9, app: "Google Chrome")
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, orphans: [orphan], match: "app~=Chrome",
            label: "Web", showNonMatching: false)
        #expect(Set(r.sections[0].windows.map(\.id.serverID)) == [1, 9])
    }

    /// The receptacle catches EVERY non-matching window — multiple leftover
    /// workspace windows AND an orphan — in universe order: non-matching
    /// workspace windows first (snapshot order), the orphan appended last. Pins
    /// the core promise that a lens desktop loses no live window: reordering the
    /// universe concat or dropping subsequent leftovers would silently hide live
    /// windows undetected (the single-leftover rows can't catch a concat/order
    /// regression).
    @Test func receptacleCatchesMultipleNonMatchingInUniverseOrder() {
        let wss = [ws(0, [win(1, app: "Google Chrome"),
                          win(2, app: "Terminal"),
                          win(3, app: "Slack")])]
        let r = FilterProjection.projectLensDesktop(
            workspaces: wss, orphans: [win(9, app: "Finder")],
            match: "app~=Chrome", label: "Web", showNonMatching: true)
        #expect(r.sections.count == 2, "lens + receptacle — no workspace tail")
        let web = r.sections.first { $0.id == "section:0:Web" }
        #expect(web?.windows.map(\.id.serverID) == [1])
        let holding = r.sections.first { $0.sectionType == .unassigned }
        #expect(holding?.windows.map(\.id.serverID) == [2, 3, 9],
                "non-matching workspace windows (snapshot order) then orphan last")
    }
}
