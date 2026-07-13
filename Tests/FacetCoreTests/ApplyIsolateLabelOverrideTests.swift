import Testing
@testable import FacetCore

/// `applyIsolateLabelOverride` — the pure display-label overlay for an isolate
/// desktop's matched section (§E / t-j7ps). Successor to `applyLabelOverrides`,
/// which was id-keyed and guarded on the NEGATIVE (`sectionType != .workspace`).
///
/// Two things changed, and both are structural rather than cosmetic:
///
/// 1. **ORDINAL-keyed, not id-keyed.** The matched section's id is
///    `"section:0:<label>"` — the CONFIG label is baked into it. An id-keyed
///    rename therefore MOVES ITS OWN KEY: the next reconcile mints a different
///    id, the override stops matching itself, and the rename evaporates. That
///    desync already happened once in this codebase (it is why the `match`
///    override is ordinal-keyed). The ordinal is the one handle a rename cannot
///    move, so the override lives out here — keyed by the caller, applied to the
///    projection's OUTPUT.
///
/// 2. **`.matched` ONLY.** The old negative guard would happily relabel a
///    `.holding` section — a section synthesized by SUBTRACTION from the match,
///    whose label is a hardcoded `""` with no config key anywhere to write a name
///    to. Naming it would invent a name with nowhere to live. The reject is now
///    structural: this function simply cannot do it.
struct ApplyIsolateLabelOverrideTests {

    private func win(_ id: Int) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "App", title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    private func sec(_ id: String, _ label: String, _ type: ProjectedSectionType,
                     _ windows: [Window] = []) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: windows,
                         sourceWorkspaceIndex: type == .workspace ? 0 : nil,
                         sectionType: type)
    }

    /// The real shape: what `projectIsolateDesktop` emits.
    private func isolateSections() -> [ProjectedSection] {
        FilterProjection.projectIsolateDesktop(
            workspaces: [Workspace(index: 0, name: "", isActive: true,
                                   layoutMode: "bsp",
                                   windows: [win(1), win(2)])],
            match: "app~=Chrome", label: "Web", showNonMatching: true).sections
    }

    // MARK: - no override

    @Test func nilOrEmptyLabelIsANoOp() {
        let secs = isolateSections()
        #expect(applyIsolateLabelOverride(secs, label: nil) == secs)
        #expect(applyIsolateLabelOverride(secs, label: "") == secs,
                "an empty label is a REVERT, not a blank header")
    }

    // MARK: - the matched section, and only it

    @Test func relabelsTheMatchedSectionAndFreezesItsID() {
        let secs = isolateSections()
        let matchedID = secs[0].id
        #expect(matchedID == "section:0:Web", "the config label is baked into the id")

        let out = applyIsolateLabelOverride(secs, label: "Editors")
        #expect(out[0].label == "Editors")
        #expect(out[0].id == matchedID,
                "the id must NOT follow the label — an id-keyed override would lose itself")
        #expect(out[0].sectionType == .matched)
        #expect(out[0].windows.map(\.id.serverID) == secs[0].windows.map(\.id.serverID))
    }

    /// ⬅ The hole in the old `applyLabelOverrides`, closed structurally.
    @Test func neverTouchesTheHoldingSection() {
        let secs = isolateSections()
        #expect(secs[1].sectionType == .holding)
        #expect(secs[1].label == "", "holding has no label of its own")

        let out = applyIsolateLabelOverride(secs, label: "Editors")
        #expect(out[1].label == "", "the holding section has nowhere to put a name")
        #expect(out[1].id == "holding:1")
        #expect(out[1].windows.map(\.id.serverID) == secs[1].windows.map(\.id.serverID))
    }

    /// A workspace section's name lives in the catalog, so a workspace rename
    /// routes to `renameWorkspace` and never reaches here. Belt and braces: even
    /// handed one, this function leaves it alone.
    @Test func neverTouchesAWorkspaceSection() {
        let secs = [sec("ws:0", "Dev", .workspace, [win(1)])]
        #expect(applyIsolateLabelOverride(secs, label: "Nope") == secs)
    }

    /// The override survives a MATCH retarget: the id is minted from the config
    /// label, which the retarget does not touch, so the ordinal-keyed override
    /// still lands. (Under the old id-keyed scheme this pairing is what produced
    /// the D6 desync.)
    @Test func survivesAMatchRetarget() {
        let wss = [Workspace(index: 0, name: "", isActive: true, layoutMode: "bsp",
                             windows: [win(1), win(2)])]
        let before = FilterProjection.projectIsolateDesktop(
            workspaces: wss, match: "app~=Chrome", label: "Web",
            showNonMatching: false).sections
        let after = FilterProjection.projectIsolateDesktop(
            workspaces: wss, match: "app~=Code", label: "Web",
            showNonMatching: false).sections
        #expect(before[0].id == after[0].id, "a retarget does not move the id")
        #expect(applyIsolateLabelOverride(after, label: "Editors")[0].label == "Editors")
    }
}
