import Testing
@testable import FacetCore

/// `FacetConfig.lensDesktopSections` (board abolition, t-0sbm) — a `type="lens"`
/// mac desktop synthesizes the `[DesktopSection]` list `FilterProjection.project`
/// consumes: ONE `.lens` section (matched windows), plus an `unassigned`
/// receptacle when `show-non-matching` is set (the non-matching "holding" set =
/// the projection's leftover). Proven END TO END against the real projection so
/// the `show-non-matching` toggle rides the existing leftover pass, not new code.
/// Pure FacetCore; CI-only.
struct LensDesktopProjectionTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    private func ws(_ index: Int, _ wins: [Window]) -> Workspace {
        Workspace(index: index, name: "", isActive: index == 0,
                  layoutMode: "float", windows: wins)
    }

    private func lensConfig(show: Bool) -> FacetConfig {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .lens, label: "Web", match: "app~=Chrome",
            layout: "bsp", showNonMatching: show)]
        return c
    }

    // MARK: - section synthesis

    @Test func showFalseYieldsOneLensSection() {
        let secs = lensConfig(show: false).lensDesktopSections(ordinal: 1)
        #expect(secs.count == 1)
        #expect(secs[0].type == .lens)
        #expect(secs[0].match == "app~=Chrome")
    }

    @Test func showTrueAppendsUnassignedReceptacle() {
        let secs = lensConfig(show: true).lensDesktopSections(ordinal: 1)
        #expect(secs.count == 2)
        #expect(secs[0].type == .lens)
        #expect(secs[1].unassigned)
    }

    @Test func nonLensDesktopYieldsEmpty() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .workspace)]
        #expect(c.lensDesktopSections(ordinal: 1).isEmpty)
        #expect(c.lensDesktopSections(ordinal: 2).isEmpty)
    }

    // MARK: - end-to-end through the real projection

    @Test func projectionShowsOnlyMatchedWhenHidingNonMatching() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Code"),
                          win(3, app: "Terminal")])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: lensConfig(show: false).lensDesktopSections(ordinal: 1))
        #expect(r.sections.count == 1)
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])   // Chrome only
    }

    @Test func projectionHoldsNonMatchingWhenShowing() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Code"),
                          win(3, app: "Terminal")])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: lensConfig(show: true).lensDesktopSections(ordinal: 1))
        #expect(r.sections.count == 2)
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])   // matched
        #expect(r.sections[1].sectionType == .unassigned)
        // The holding section = leftover (universe − matched) = the non-Chrome.
        #expect(Set(r.sections[1].windows.map(\.id.serverID)) == [2, 3])
    }

    @Test func lensSectionIdIsStableChangeMatchHandle() {
        let wss = [ws(0, [win(1, app: "Google Chrome")])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: lensConfig(show: true).lensDesktopSections(ordinal: 1))
        // declOrder 0 → the runtime change-match keys on this id.
        #expect(r.sections[0].id == "section:0:Web")
    }
}
