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

/// t-j7ps / (c) — the trap the rename would have sprung, and the cut that removed it.
///
/// `[desktop.N] label` used to name the isolate desktop's single workspace as well
/// as the desktop. `workspace` is a FIELD a `match` can compare against. So the
/// label was a display name masquerading as data, and `facet section --rename` —
/// which persists `[desktop.N] label` — could silently break the desktop's own
/// match.
///
/// The insidious part: it did NOT break the running session (the catalog is seeded
/// once at launch and keeps the old name). It broke the NEXT LAUNCH. Cause and
/// effect sat on opposite sides of a restart, so nobody could ever have connected
/// them.
struct IsolateLabelIsNotAMatchableFieldTests {

    private func win(_ id: Int, app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    private func filter(_ src: String) -> FacetFilter {
        guard case .success(let f) = FacetFilter.parse(src) else {
            Issue.record("unparseable: \(src)"); return .all
        }
        return f
    }

    /// ⬅ THE regression pin, driven exactly as the daemon drives it: config →
    /// `effectiveWorkspaceList` → the workspace NAME → `IsolatePark.parkSet`.
    ///
    /// Before the cut, this test's `after` case parked BOTH windows (the desktop
    /// tiled nothing — dead). Now the label simply cannot reach the park set.
    @Test func renamingTheDesktopCannotChangeWhatGetsParked() {
        let windows = [win(1, app: "Safari"), win(2, app: "Xcode")]

        func parkSet(label: String, match: String) -> [Int] {
            var c = FacetConfig()
            c.macDesktopMetaConfigs = [2: DesktopMeta(
                type: .isolate, label: label, match: match)]
            let ws = c.effectiveWorkspaceList(forMacDesktopOrdinal: 2)
            return IsolatePark.parkSet(
                windows: windows,
                inWorkspaceNamed: ws.first?.config.name,
                match: filter(match), sticky: []
            ).map(\.serverID).sorted()
        }

        // A real, content-based match: Safari tiles, Xcode parks. The label is
        // irrelevant to it — before AND after a rename.
        #expect(parkSet(label: "Web", match: "app~=Safari") == [2])
        #expect(parkSet(label: "Editors", match: "app~=Safari") == [2],
                "renaming the desktop must not move a single window")
    }

    /// And the config that USED to lean on the coupling is now loud rather than
    /// silently dead. `match = 'workspace=Web'` on a desktop labelled "Web" tiled
    /// everything before; it selects nothing now — so facet says so, and
    /// `config --validate` exits 1. (This is the one breaking change in t-j7ps.)
    @Test func aWorkspaceFieldInAnIsolateMatchIsALoudError() {
        let c = FacetConfig.load(source: """
        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'workspace=Web'
        """)
        #expect(c.diagnostics.hasErrors)
        #expect(c.diagnostics.contains { $0.message.contains("is a CONSTANT") },
                "\(c.diagnostics.map(\.message))")
        // The desktop still decodes — the daemon is permissive, as always.
        #expect(c.desktopIsolate(ordinal: 2) != nil)
    }

    /// A content-based match on the same desktop is clean — no false alarm.
    @Test func aContentBasedIsolateMatchIsClean() {
        let c = FacetConfig.load(source: """
        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app~=Chrome or app=Safari'
        """)
        #expect(c.diagnostics.isEmpty, "\(c.diagnostics.map(\.message))")
    }

    /// `[[rule]]` matches are UNAFFECTED — they run on workspace desktops, where
    /// `workspace` is a real, user-owned field. Only an ISOLATE desktop's match is
    /// flagged.
    @Test func ruleMatchesMayStillReferenceWorkspace() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Dev"

        [[rule]]
        match = 'workspace=Dev'
        tags = ["work"]
        """)
        #expect(!c.diagnostics.hasErrors, "\(c.diagnostics.map(\.message))")
    }
}
