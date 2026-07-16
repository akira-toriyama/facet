import CoreGraphics
import Testing
@testable import FacetView

/// t-kywh (案A rework): the alias-picker CHECKLIST geometry — `panelHeight`
/// is the ONE place the panel's layout bands are summed and
/// `aliasListVisibleHeight` the one row-cap rule, shared by `show` and the
/// scroll placement, so these pin them. The toggle/derive SEMANTICS are
/// pure FacetCore (`matchTogglingAlias` / `matchCheckedAliases`) and tested
/// in `FilterAliasTests`. CI-only like the other suites.
@MainActor
struct SectionRenamePanelListTests {

    private let rowH = AliasPickListView.rowH

    @Test func visibleHeightCapsAtMaxRows() {
        #expect(SectionRenamePanel.aliasListVisibleHeight(count: 1) == rowH)
        #expect(SectionRenamePanel.aliasListVisibleHeight(count: 3) == rowH * 3)
        let cap = CGFloat(SectionRenamePanel.maxVisibleAliasRows)
        #expect(SectionRenamePanel.aliasListVisibleHeight(count: 50) == rowH * cap)
    }

    @Test func renamePanelHeightHasNoListOrErrorBand() {
        // The rename panel (no validate, no aliases) must keep its historic
        // height: header + field + paddings only.
        let h = SectionRenamePanel.panelHeight(validating: false,
                                               aliasRowsHeight: 0)
        let expected = SectionRenameContainerView.padV
            + SectionRenameContainerView.headerH
            + SectionRenameContainerView.fieldGap
            + SectionRenameContainerView.fieldH
            + SectionRenameContainerView.padV
        #expect(h == expected)
    }

    @Test func matchEditWithoutAliasesAddsOnlyTheErrorRow() {
        let base = SectionRenamePanel.panelHeight(validating: false,
                                                  aliasRowsHeight: 0)
        let h = SectionRenamePanel.panelHeight(validating: true,
                                               aliasRowsHeight: 0)
        #expect(h == base + SectionRenameContainerView.errorGap
                          + SectionRenameContainerView.errorH)
    }

    @Test func aliasListAddsItsGapPlusRows() {
        let noList = SectionRenamePanel.panelHeight(validating: true,
                                                    aliasRowsHeight: 0)
        let listH = SectionRenamePanel.aliasListVisibleHeight(count: 3)
        let h = SectionRenamePanel.panelHeight(validating: true,
                                               aliasRowsHeight: listH)
        #expect(h == noList + SectionRenamePanel.aliasListGap + listH)
    }

    @Test func listViewContentHeightTracksRows() {
        let list = AliasPickListView(frame: .zero)
        list.names = ["web", "dev", "chat"]
        #expect(list.contentHeight() == rowH * 3)
        list.names = []
        #expect(list.contentHeight() == rowH)   // empty keeps one hint row
    }
}
