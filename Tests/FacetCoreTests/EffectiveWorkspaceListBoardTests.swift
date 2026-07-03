import Testing
@testable import FacetCore

/// `FacetConfig.effectiveWorkspaceList` over the BOARD model (t-wrd2 / W2.5).
/// The workspace substrate (count + per-workspace layout seed) is
/// board-INDEPENDENT: a *display-only* board switch never reshapes the tiling,
/// so the list reads the WORKSPACE-type board's sections regardless of which
/// board is currently selected (the method takes no board argument by design).
/// A tab-only config (no flat `[[desktop.N.section]]`) must still seed its
/// workspaces — otherwise the W2.5 gate activates the model but the catalog
/// seeds ZERO workspaces. Complements `EffectiveWorkspaceListSectionEdgeTests`
/// (flat edges). Pure; CI-only (CLT can't run `swift test`).
struct EffectiveWorkspaceListBoardTests {

    private func ws(_ label: String, layout: String? = nil) -> DesktopSection {
        DesktopSection(type: .workspace, label: label, layout: layout)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    /// A workspace board seeds its child workspaces (count + names + 1-based
    /// indices), with a sibling lens board present but contributing nothing.
    @Test func workspaceBoardSeedsItsWorkspaces() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Spaces",
                       sections: [ws("Main"), ws("Side")]),
            DesktopTab(type: .lens, label: "Views",
                       sections: [lens("Web", "tag~=web")]),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.map(\.config.name) == ["Main", "Side"])
        #expect(list.map(\.index) == [1, 2])
    }

    /// Board-INDEPENDENT: the lens board carries no workspaces, so the
    /// substrate is the workspace board's sections only — never the lens
    /// board's, even when the lens board comes FIRST in declaration order.
    @Test func lensBoardContributesNoWorkspaces() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .lens, label: "Views",
                       sections: [lens("Web", "tag~=web"), lens("Mail", "app=Mail")]),
            DesktopTab(type: .workspace, label: "Spaces",
                       sections: [ws("Code")]),
        ]]
        #expect(
            c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name) ==
            ["Code"])
    }

    /// The per-workspace layout seed survives the board wrapper.
    @Test func workspaceBoardCarriesLayoutSeed() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, sections: [ws("Main", layout: "bsp")]),
        ]]
        #expect(
            c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).first?.config.layout ==
            "bsp")
    }

    /// A tab config with ONLY lens boards → no workspace substrate → DEGRADES
    /// to the default unnamed slots (mirrors flat lens-only).
    @Test func lensOnlyBoardsDegradeToDefaultSlots() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .lens, sections: [lens("Web", "tag~=web")]),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }

    /// A nil ordinal never activates the model (per-ordinal opt-in) → default.
    @Test func nilOrdinalDegradesToDefault() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, sections: [ws("Main")]),
        ]]
        #expect(
            c.effectiveWorkspaceList(forMacDesktopOrdinal: nil).count ==
            FacetConfig.defaultWorkspaceCount)
    }

    /// When BOTH boards and a flat list exist for one ordinal (a contrived
    /// mixed config), the boards WIN — matching `activeBoardSections`'s
    /// precedence so the substrate and the projection can't disagree.
    @Test func boardsTakePrecedenceOverFlatForSubstrate() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, sections: [ws("Main"), ws("Side")]),
        ]]
        c.macDesktopSectionConfigs = [1: [ws("FlatOnly")]]
        #expect(
            c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name) ==
            ["Main", "Side"])
    }

    /// N5 (board review follow-up): a LENS-only board MASKS a flat workspace
    /// section at the same ordinal — boards win once present, so the substrate
    /// ignores the flat `[[desktop.N.section]]` workspace and degrades to
    /// default slots. Self-consistent (no double-SSOT: the projection ignores
    /// the flat list too); pinned here because it is surprising.
    @Test func lensOnlyBoardMasksFlatWorkspaceSubstrate() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("FlatWS")]]
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .lens, sections: [lens("Web", "tag~=web")]),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount,
                "boards win; the flat workspace section is masked")
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }
}
