import Testing
import CoreGraphics
@testable import FacetCore

struct OverviewModelsTests {
    private func cell(_ type: ProjectedSectionType, id: String) -> OverviewCell {
        OverviewCell(wsIndex: -1, rect: .zero, headerRect: .zero,
                     isActive: false, label: "L", mode: "", windows: [],
                     sectionType: type, sectionID: id)
    }

    @Test func defaultsAreWorkspaceKind() {
        // The legacy 8-arg call site (no sectionType/sectionID) must still
        // compile + default to the workspace kind.
        let c = OverviewCell(wsIndex: 0, rect: .zero, headerRect: .zero,
                             isActive: true, label: "W", mode: "bsp", windows: [])
        #expect(c.sectionType == .workspace)
        #expect(c.sectionID == "")
        #expect(!(c.isLens))
    }

    @Test func lensKindFlag() {
        let l = cell(.lens, id: "section:1:Web")
        #expect(l.isLens)
        #expect(l.sectionID == "section:1:Web")
        #expect(l.sectionType == .lens)
    }

    @Test func workspaceKindIsNotLens() {
        #expect(!(cell(.workspace, id: "ws:0").isLens))
    }

    private func win(_ id: Int) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "App", title: "",
               isFocused: false, isFloating: false, frame: nil, tags: [])
    }

    /// `ProjectedSection.==` compares the ORDERED window-id list, not the
    /// window set — the source names this "the projection's actual contract:
    /// which windows land in which section". Two sections that hold the same
    /// windows in a different order must be unequal. Regression pin: swapping
    /// the ordered compare for a Set-based one would flip this to equal.
    @Test func windowOrderMakesSectionsUnequal() {
        let a = ProjectedSection(id: "a", label: "L", windows: [win(1), win(2)],
                                 sourceWorkspaceIndex: 0)
        let b = ProjectedSection(id: "a", label: "L", windows: [win(2), win(1)],
                                 sourceWorkspaceIndex: 0)
        #expect(a != b)
    }
}
