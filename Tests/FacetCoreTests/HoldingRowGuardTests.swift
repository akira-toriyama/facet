import Testing
@testable import FacetCore

/// `isHoldingSection` — the predicate behind the tree's four inert-guards
/// (mouseUp / drag-source / handleClick / kbActivate). t-63h2 says an isolate
/// desktop's HOLDING row is DISPLAY-ONLY: no click-focus, no drag source.
///
/// This file exists because that contract shipped BROKEN. t-mqqw renamed the
/// isolate desktop's leftover bucket `.unassigned` → `.holding` but left the
/// tree's guard asking for `.unassigned` — which `projectIsolateDesktop` never
/// mints — so the predicate was CONSTANT-FALSE and every holding row was
/// clickable and draggable. Nothing caught it because the predicate lived as a
/// method on an untestable `SidebarView`.
///
/// So the last test here is the load-bearing one: it feeds the guard the REAL
/// projection output rather than a hand-built section, which is the exact seam
/// that drifted. A pure unit test over hand-built `ProjectedSection`s would have
/// stayed green through the whole regression.
struct HoldingRowGuardTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    private func ws(_ index: Int, _ wins: [Window]) -> Workspace {
        Workspace(index: index, name: "", isActive: index == 0,
                  layoutMode: "float", windows: wins)
    }
    private func sec(_ type: ProjectedSectionType) -> ProjectedSection {
        ProjectedSection(id: "x", label: "", windows: [],
                         sourceWorkspaceIndex: nil, sectionType: type)
    }

    @Test func onlyHoldingIsInert() {
        let sections = [sec(.workspace), sec(.matched), sec(.holding), sec(.unassigned)]
        #expect(!isHoldingSection(sections, group: 0), "workspace cells are fully interactive")
        #expect(!isHoldingSection(sections, group: 1),
                "a MATCHED row is a real tiled window — click focuses it")
        #expect(isHoldingSection(sections, group: 2))
        #expect(!isHoldingSection(sections, group: 3),
                "the §G receptacle is a rescue DRAG SOURCE — never inert")
    }

    @Test func outOfRangeGroupIsNotHolding() {
        let sections = [sec(.holding)]
        #expect(!isHoldingSection(sections, group: -1))
        #expect(!isHoldingSection(sections, group: 1))
        #expect(!isHoldingSection([], group: 0))
    }

    /// ⬅ THE regression pin. Drive the guard with what `projectIsolateDesktop`
    /// actually emits: group 0 = matched (interactive), group 1 = holding (inert).
    /// If a future change re-mints the leftover bucket as some other case, this
    /// goes red — the hand-built rows above would not.
    @Test func realIsolateProjectionMarksItsLeftoverRowInert() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.projectIsolateDesktop(
            workspaces: wss, orphans: [], match: "app~=Chrome",
            label: "Web", showNonMatching: true)
        #expect(r.sections.count == 2)
        #expect(!isHoldingSection(r.sections, group: 0), "matched row stays interactive")
        #expect(isHoldingSection(r.sections, group: 1),
                "the non-matching leftover row is display-only (t-63h2)")
    }

    /// `show-non-matching = false` → no leftover row at all, so nothing is inert.
    @Test func noHoldingRowWhenLeftoverIsHidden() {
        let wss = [ws(0, [win(1, app: "Google Chrome"), win(2, app: "Terminal")])]
        let r = FilterProjection.projectIsolateDesktop(
            workspaces: wss, orphans: [], match: "app~=Chrome",
            label: "Web", showNonMatching: false)
        #expect(r.sections.count == 1)
        #expect(!isHoldingSection(r.sections, group: 0))
    }
}
