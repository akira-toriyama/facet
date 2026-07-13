import Testing
import Foundation
@testable import FacetCore

/// `[desktop.N]` typed-desktop table decode (t-0sbm) — the SINGLE-table
/// successor to the retired `[[desktop.N.tab]]` boards. A mac desktop is typed
/// directly (`type = "workspace" | "isolate"`); an isolate desktop carries an always-on
/// `match` + `layout` (+ `show-non-matching`) right on the table. PURE FacetCore:
/// these pin the decode plus the `desktopType` / `desktopIsolate` / workspace-seed
/// accessors that the typed-desktop runtime (projection, park, catalog seed)
/// reads.
///
/// Wire rules (FROZEN here):
///   • `type` is REQUIRED (workspace / isolate) — absent / unknown DROPS the desktop.
///   • an isolate desktop REQUIRES a non-empty `match`; `layout` + `show-non-matching`
///     are honoured. (`apply` retired with the section-lens, t-ec9s: it is not in
///     the schema, so `config --validate` rejects it outright.)
///   • a workspace desktop has NO `match` — its `[[desktop.N.section]]` rows are
///     spatial cells (`label` / `layout` / `unassigned`), and a `match` authored on
///     the table is ignored w/ caveat.
struct DesktopMetaDecodeTests {

    // MARK: - decode

    @Test func decodesIsolateDesktop() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app=Safari or app~=Chrome'
        layout = "bsp"
        show-non-matching = true
        """)
        #expect(m[2] == DesktopMeta(type: .isolate, label: "Web",
            match: "app=Safari or app~=Chrome", layout: "bsp",
            showNonMatching: true))
    }

    /// The tombstone (t-mqqw). `lens` was renamed to `isolate`; facet keeps no
    /// compatibility aliases, so the retired spelling must DROP the desktop —
    /// and it must say so BY NAME rather than falling into the generic
    /// "unknown type" message, because a silently-dropped desktop goes hands-off
    /// (no panel) and reads as "facet broke".
    @Test func retiredLensTypeIsALoudRejectNotAnAlias() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.2]
        type = "lens"
        label = "Web"
        match = 'app~=Chrome'
        """)
        #expect(m[2] == nil, "`type = \"lens\"` must NOT decode as an isolate desktop")

        // …and the drop names the rename, so the reader knows what to write.
        let (meta, note) = DesktopMeta.parse(fromTOMLRow: [
            "type": .string("lens"), "match": .string("app~=Chrome"),
        ])
        #expect(meta == nil)
        #expect(note?.contains("isolate") == true, "the note must name the new spelling")
        #expect(note?.contains("never a view") == true, "…and say why it moved")
    }

    @Test func decodesWorkspaceDesktopTypeAndLabelOnly() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "workspace"
        label = "Main"
        """)
        #expect(m[1] == DesktopMeta(type: .workspace, label: "Main"))
    }

    @Test func isolateWithoutMatchDrops() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "isolate"
        label = "Web"
        """)
        #expect(m[1] == nil)
    }

    @Test func unknownTypeDrops() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "banana"
        """)
        #expect(m[1] == nil)
    }

    @Test func missingTypeDrops() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        label = "x"
        """)
        #expect(m[1] == nil)
    }

    @Test func showNonMatchingDefaultsFalseAndLayoutOptional() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "isolate"
        match = 'app=Safari'
        """)
        #expect(m[1]?.showNonMatching == false)
        #expect(m[1]?.layout == nil)
    }

    @Test func workspaceAuthoredMatchIsIgnored() {
        // A workspace desktop has no `match` anywhere (its sections are spatial
        // cells) — dropped (loud caveat), the desktop still decodes as a bare
        // workspace.
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "workspace"
        match = 'app=Safari'
        """)
        #expect(m[1] == DesktopMeta(type: .workspace))
    }

    // MARK: - accessors

    @Test func desktopTypeExplicitWins() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, match: "app=x")]
        #expect(c.desktopType(ordinal: 1) == .isolate)
    }

    @Test func desktopTypeFallsBackToWorkspaceForSections() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [DesktopSection()]]
        #expect(c.desktopType(ordinal: 1) == .workspace)
    }

    @Test func desktopTypeNilWhenUnconfigured() {
        let c = FacetConfig()
        #expect(c.desktopType(ordinal: 1) == nil)
        #expect(c.desktopType(ordinal: nil) == nil)
    }

    @Test func desktopIsolateOnlyForIsolateType() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .isolate, match: "app=x", layout: "grid"),
            2: DesktopMeta(type: .workspace),
        ]
        #expect(c.desktopIsolate(ordinal: 1)?.match == "app=x")
        #expect(c.desktopIsolate(ordinal: 2) == nil)
        #expect(c.desktopIsolate(ordinal: 3) == nil)
    }

    @Test func isolateDesktopIsManagedButOptInElsewhere() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, match: "app=x")]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        // Opt-in: declaring ANY typed desktop leaves the others hands-off.
        #expect(!c.isMacDesktopManaged(ordinal: 2))
    }

    // MARK: - desktopTypeFlips (t-63h2: hot-reload can't re-seed the catalog)

    @Test func typeFlipsDetectsWorkspaceToIsolateAndBack() {
        var ws = FacetConfig()
        ws.macDesktopSectionConfigs = [1: [DesktopSection()]]   // desktop 1 = workspace
        var iso = FacetConfig()
        iso.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, match: "app=x")]
        // Either direction reports ordinal 1 (symmetric across the two configs).
        #expect(ws.desktopTypeFlips(against: iso) == [1])
        #expect(iso.desktopTypeFlips(against: ws) == [1])
    }

    @Test func typeFlipsDetectsGainingOrLosingATypedDesktop() {
        let bare = FacetConfig()                                // desktop 1 = none
        var iso = FacetConfig()
        iso.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, match: "app=x")]
        #expect(bare.desktopTypeFlips(against: iso) == [1],
                "none → isolate is a flip (the desktop gains a type)")
    }

    @Test func typeFlipsEmptyWhenTypesUnchanged() {
        // A match / label edit on the SAME isolate type is not a type flip.
        var a = FacetConfig()
        a.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, match: "app=x")]
        var b = FacetConfig()
        b.macDesktopMetaConfigs = [1: DesktopMeta(type: .isolate, label: "W",
                                                  match: "app=y")]
        #expect(a.desktopTypeFlips(against: b) == [])
    }

    @Test func typeFlipsReportsOnlyChangedOrdinalsSorted() {
        var a = FacetConfig()
        a.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .workspace),
            2: DesktopMeta(type: .isolate, match: "app=x"),
            3: DesktopMeta(type: .isolate, match: "app=z"),
        ]
        var b = FacetConfig()
        b.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .workspace),                   // unchanged
            2: DesktopMeta(type: .workspace),                   // lens → workspace
            3: DesktopMeta(type: .isolate, match: "app=z2"),       // match edit only
        ]
        #expect(a.desktopTypeFlips(against: b) == [2])
    }

    // MARK: - full load path

    @Test func loadPopulatesTypedDesktops() {
        let c = FacetConfig.load(source: """
        [desktop.1]
        type = "workspace"
        label = "Main"

        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app~=Chrome'
        layout = "grid"
        """)
        #expect(c.desktopType(ordinal: 1) == .workspace)
        #expect(c.desktopType(ordinal: 2) == .isolate)
        #expect(c.desktopIsolate(ordinal: 2)?.layout == "grid")
        #expect(c.desktopIsolate(ordinal: 2)?.label == "Web")
    }

    // MARK: - flat N=1 seed (Phase 2c)

    /// An isolate desktop is FLAT — `effectiveWorkspaceList` seeds EXACTLY ONE
    /// workspace, seeded with the desktop's layout. This pins the catalog to N=1
    /// so the active-WS park scope is the whole desktop.
    ///
    /// ⬅ It used to be NAMED from the desktop's `label`, and this test pinned
    /// that. t-j7ps cut the coupling: the name made `label` two things at once —
    /// a display name AND the value of the `workspace` FIELD a `match` compares
    /// against. So `facet section --rename` (which writes `[desktop.N] label`)
    /// could silently break the desktop's own match: rename a desktop whose match
    /// said `workspace=Web` and at the NEXT LAUNCH it selects nothing and parks
    /// every window — cause and effect on opposite sides of a restart.
    ///
    /// The name was never load-bearing: an isolate desktop's workspace is
    /// UNADDRESSABLE (every workspace verb is refused by `IsolateDesktopGate`)
    /// because N=1 is an internal invariant, not a thing the user owns.
    @Test func isolateDesktopSeedsExactlyOneUNNAMEDWorkspace() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .isolate, label: "Web", match: "app~=Chrome", layout: "bsp")]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 1)
        #expect(list[0].index == 1)
        #expect(list[0].config.name == "",
                "the label names the DESKTOP, not a matchable workspace field")
        #expect(list[0].config.layout == "bsp")
    }

    /// The rename can no longer reach the match. Renaming the desktop changes the
    /// display label and NOTHING else — which is what `applyIsolateLabelOverride`
    /// has always claimed, and is now finally true across a restart too.
    @Test func renamingAnIsolateDesktopCannotChangeWhatItMatches() {
        var before = FacetConfig()
        before.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .isolate, label: "Web", match: "app~=Chrome")]
        var after = FacetConfig()
        after.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .isolate, label: "Editors", match: "app~=Chrome")]
        #expect(before.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name)
                == after.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name),
                "a rename must not move any field a `match` can see")
    }

    /// A workspace desktop with no sections is unaffected by the lens seed — it
    /// still degrades to the default slot count.
    @Test func workspaceDesktopUnaffectedByIsolateSeed() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .workspace, label: "Main")]
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).count
                == FacetConfig.defaultWorkspaceCount)
    }
}
