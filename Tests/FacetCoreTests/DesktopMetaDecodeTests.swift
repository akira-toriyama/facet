import Testing
import Foundation
@testable import FacetCore

/// `[desktop.N]` typed-desktop table decode (t-0sbm) — the SINGLE-table
/// successor to the retired `[[desktop.N.tab]]` boards. A mac desktop is typed
/// directly (`type = "workspace" | "lens"`); a lens desktop carries an always-on
/// `match` + `layout` (+ `show-non-matching`) right on the table. PURE FacetCore:
/// these pin the decode plus the `desktopType` / `desktopLens` / workspace-seed
/// accessors that the typed-desktop runtime (projection, park, catalog seed)
/// reads.
///
/// Wire rules (FROZEN here):
///   • `type` is REQUIRED (workspace / lens) — absent / unknown DROPS the desktop.
///   • a lens desktop REQUIRES a non-empty `match`; `layout` + `show-non-matching`
///     are honoured. (`apply` retired with the section-lens, t-ec9s: it is not in
///     the schema, so `config --validate` rejects it outright.)
///   • a workspace desktop has NO `match` — its `[[desktop.N.section]]` rows are
///     spatial cells (`label` / `layout` / `unassigned`), and a `match` authored on
///     the table is ignored w/ caveat.
struct DesktopMetaDecodeTests {

    // MARK: - decode

    @Test func decodesLensDesktop() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.2]
        type = "lens"
        label = "Web"
        match = 'app=Safari or app~=Chrome'
        layout = "bsp"
        show-non-matching = true
        """)
        #expect(m[2] == DesktopMeta(type: .lens, label: "Web",
            match: "app=Safari or app~=Chrome", layout: "bsp",
            showNonMatching: true))
    }

    @Test func decodesWorkspaceDesktopTypeAndLabelOnly() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "workspace"
        label = "Main"
        """)
        #expect(m[1] == DesktopMeta(type: .workspace, label: "Main"))
    }

    @Test func lensWithoutMatchDrops() {
        let m = FacetConfig.decodeDesktopTables(fromTOML: """
        [desktop.1]
        type = "lens"
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
        type = "lens"
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
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, match: "app=x")]
        #expect(c.desktopType(ordinal: 1) == .lens)
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

    @Test func desktopLensOnlyForLens() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .lens, match: "app=x", layout: "grid"),
            2: DesktopMeta(type: .workspace),
        ]
        #expect(c.desktopLens(ordinal: 1)?.match == "app=x")
        #expect(c.desktopLens(ordinal: 2) == nil)
        #expect(c.desktopLens(ordinal: 3) == nil)
    }

    @Test func lensDesktopIsManagedButOptInElsewhere() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, match: "app=x")]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        // Opt-in: declaring ANY typed desktop leaves the others hands-off.
        #expect(!c.isMacDesktopManaged(ordinal: 2))
    }

    // MARK: - desktopTypeFlips (t-63h2: hot-reload can't re-seed the catalog)

    @Test func typeFlipsDetectsWorkspaceToLensAndBack() {
        var ws = FacetConfig()
        ws.macDesktopSectionConfigs = [1: [DesktopSection()]]   // desktop 1 = workspace
        var lens = FacetConfig()
        lens.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, match: "app=x")]
        // Either direction reports ordinal 1 (symmetric across the two configs).
        #expect(ws.desktopTypeFlips(against: lens) == [1])
        #expect(lens.desktopTypeFlips(against: ws) == [1])
    }

    @Test func typeFlipsDetectsGainingOrLosingATypedDesktop() {
        let bare = FacetConfig()                                // desktop 1 = none
        var lens = FacetConfig()
        lens.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, match: "app=x")]
        #expect(bare.desktopTypeFlips(against: lens) == [1],
                "none → lens is a flip (the desktop gains a type)")
    }

    @Test func typeFlipsEmptyWhenTypesUnchanged() {
        // A match / label edit on the SAME lens type is not a type flip.
        var a = FacetConfig()
        a.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, match: "app=x")]
        var b = FacetConfig()
        b.macDesktopMetaConfigs = [1: DesktopMeta(type: .lens, label: "W",
                                                  match: "app=y")]
        #expect(a.desktopTypeFlips(against: b) == [])
    }

    @Test func typeFlipsReportsOnlyChangedOrdinalsSorted() {
        var a = FacetConfig()
        a.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .workspace),
            2: DesktopMeta(type: .lens, match: "app=x"),
            3: DesktopMeta(type: .lens, match: "app=z"),
        ]
        var b = FacetConfig()
        b.macDesktopMetaConfigs = [
            1: DesktopMeta(type: .workspace),                   // unchanged
            2: DesktopMeta(type: .workspace),                   // lens → workspace
            3: DesktopMeta(type: .lens, match: "app=z2"),       // match edit only
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
        type = "lens"
        label = "Web"
        match = 'app~=Chrome'
        layout = "grid"
        """)
        #expect(c.desktopType(ordinal: 1) == .workspace)
        #expect(c.desktopType(ordinal: 2) == .lens)
        #expect(c.desktopLens(ordinal: 2)?.layout == "grid")
        #expect(c.desktopLens(ordinal: 2)?.label == "Web")
    }

    // MARK: - flat N=1 seed (Phase 2c)

    /// A lens desktop is FLAT — `effectiveWorkspaceList` seeds EXACTLY ONE
    /// workspace, named by the lens label + seeded with its layout. This pins the
    /// catalog to N=1 so the active-WS park scope is the whole desktop.
    @Test func lensDesktopSeedsExactlyOneWorkspace() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .lens, label: "Web", match: "app~=Chrome", layout: "bsp")]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 1)
        #expect(list[0].index == 1)
        #expect(list[0].config.name == "Web")
        #expect(list[0].config.layout == "bsp")
    }

    /// A workspace desktop with no sections is unaffected by the lens seed — it
    /// still degrades to the default slot count.
    @Test func workspaceDesktopUnaffectedByLensSeed() {
        var c = FacetConfig()
        c.macDesktopMetaConfigs = [1: DesktopMeta(type: .workspace, label: "Main")]
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).count
                == FacetConfig.defaultWorkspaceCount)
    }
}
