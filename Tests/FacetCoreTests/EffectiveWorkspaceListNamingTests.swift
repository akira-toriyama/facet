import Testing
@testable import FacetCore

/// The section-aware `effectiveWorkspaceList` naming seed (§A / §B). A workspace
/// cell section's name is its optional `label`; an empty label leaves the slot
/// UNNAMED (`name == ""`) — displayed by its 1-based index, since §B retired the
/// emoji auto-name pool (`WorkspaceNaming`). CI-only (CLT can't run XCTest).
/// Section-INACTIVE degrade paths live in
/// `EffectiveWorkspaceListSectionEdgeTests`.
struct EffectiveWorkspaceListNamingTests {

    /// One slot per section, in order; an unnamed (empty-label) workspace's
    /// `config.name` is EMPTY (the view renders its 1-based index).
    ///
    /// This used to declare THREE sections — the middle one an `unassigned`
    /// receptacle — and assert that only 2 seeded workspaces, because
    /// `workspaceSubstrateSections` filtered receptacles out. t-6rbc deleted that
    /// filter, which is only safe because the receptacle no longer DECODES: the
    /// row is dropped at parse. Same two workspaces, one less concept. The
    /// end-to-end proof (from real TOML, through decode) is
    /// `RetiredUnassignedKeyTests.staleUnassignedRowIsDroppedNotPromotedToAWorkspace`
    /// — this one now just pins the naming.
    @Test func sectionWorkspaceListUnnamedSlotsAreEmpty() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(layout: "bsp"),
            DesktopSection(),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 2)
        #expect(list[0].index == 1)
        #expect(list[0].config.name.isEmpty)      // unnamed → empty (§B)
        #expect(list[0].config.layout == "bsp")    // layout seed carried
        #expect(list[1].index == 2)
        #expect(list[1].config.name.isEmpty)
        #expect(list[1].config.layout == nil)
    }

    /// §A: a non-empty workspace `label` names the workspace from config; an
    /// empty label stays unnamed (empty name, §B).
    @Test func sectionWorkspaceListUsesLabelWhenSet() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(label: "Dev", layout: "bsp"),
            DesktopSection(),   // no label → unnamed
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 2)
        #expect(list[0].config.name == "Dev")      // named from config
        #expect(list[0].config.layout == "bsp")
        #expect(list[1].config.name.isEmpty)      // empty → unnamed (§B)
    }
}
