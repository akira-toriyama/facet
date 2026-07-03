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
}
