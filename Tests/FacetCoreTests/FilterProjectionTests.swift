import Testing
@testable import FacetCore

/// `FilterProjection` — `[Workspace]` → `[ProjectedSection]`. Since section-lens
/// was retired (t-ec9s), every `[[desktop.N.section]]` is a WORKSPACE SPATIAL
/// cell: sections map positionally onto the live workspaces (id from the wire
/// index), and an opt-in `unassigned` section (§G) rescues the leftover
/// (universe − shown — windows in no other emitted section; first emits, extras
/// warn). Degrade (no sections) stays byte-identical to by-workspace. The `lens`
/// concept now lives ONLY on a typed lens DESKTOP (`projectLensDesktop`), never
/// on a config section. Pure; CI-only (CLT can't run `swift test`).
struct FilterProjectionTests {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil, tags: tags)
    }

    private func ws(_ index: Int, name: String, windows: [Window],
                    active: Bool = false) -> Workspace {
        Workspace(index: index, name: name, isActive: active,
                  layoutMode: "float", windows: windows)
    }

    /// A plain workspace SPATIAL cell (`[[desktop.N.section]]` with no marker).
    private func wsSec() -> DesktopSection { DesktopSection() }
    /// The opt-in lost-and-found receptacle (`unassigned = true`).
    private func unassigned(_ label: String) -> DesktopSection {
        DesktopSection(label: label, unassigned: true)
    }

    // MARK: - degrade (no sections → 1:1 by-workspace, byte-identical)

    @Test func degradeMapsWorkspacesOneToOne() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [])
        #expect(r.diagnostics.isEmpty)
        #expect(r.sections.count == 2)
        #expect(r.sections[0].id == "ws:0")
        #expect(r.sections[0].label == "Dev")
        #expect(r.sections[0].sourceWorkspaceIndex == 0)
        #expect(r.sections[0].sectionType == .workspace)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1, 2])
        #expect(r.sections[1].id == "ws:1")
        #expect(r.sections[1].windows.map(\.id.serverID) == [3])
    }

    @Test func degradeEmptyWorkspaces() {
        let r = FilterProjection.project(workspaces: [], sections: [])
        #expect(r.sections.isEmpty)
        #expect(r.diagnostics.isEmpty)
    }

    /// Locks the FROZEN 0-based WIRE-index invariant: id/sourceWorkspaceIndex
    /// come from `Workspace.index`, NOT the array position, and the degrade
    /// preserves array order (no re-sort). A regression breaks PR8's
    /// byte-identical --focus/--move-to targeting.
    @Test func degradeUsesWireIndexNotArrayPosition() {
        let wss = [
            ws(5, name: "Dev", windows: [win(1)]),
            ws(2, name: "Web", windows: [win(2)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [])
        #expect(r.sections[0].id == "ws:5")
        #expect(r.sections[0].sourceWorkspaceIndex == 5)
        #expect(r.sections[1].id == "ws:2")
        #expect(r.sections[1].sourceWorkspaceIndex == 2)
    }

    /// CONVERGENCE: for a FIXED `[Workspace]`, an all-`workspace`-sections
    /// config produces the SAME sections as the section-less degrade.
    @Test func workspaceSectionsConvergeWithDegrade() {
        let wss = [
            ws(5, name: "Dev", windows: [win(1)]),
            ws(2, name: "Web", windows: [win(2)]),
        ]
        let degrade = FilterProjection.project(workspaces: wss, sections: [])
        let sectioned = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), wsSec()])
        #expect(degrade == sectioned)
    }

    @Test func resultEquatableRoundTrip() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let expected = FilterProjection.Result(
            sections: [ProjectedSection(id: "ws:0", label: "Dev",
                                 windows: [win(1), win(2)], sourceWorkspaceIndex: 0)],
            diagnostics: [])
        #expect(expected == FilterProjection.project(workspaces: wss, sections: []))
        // `==` discriminates each compared field — including sectionType.
        let base = ProjectedSection(id: "a", label: "L", windows: [win(1)],
                               sourceWorkspaceIndex: 0, sectionType: .workspace)
        #expect(base != ProjectedSection(id: "b", label: "L", windows: [win(1)], sourceWorkspaceIndex: 0))
        #expect(base != ProjectedSection(id: "a", label: "X", windows: [win(1)], sourceWorkspaceIndex: 0))
        #expect(base != ProjectedSection(id: "a", label: "L", windows: [win(1)], sourceWorkspaceIndex: 1))
        #expect(base != ProjectedSection(id: "a", label: "L", windows: [win(2)], sourceWorkspaceIndex: 0))
        #expect(base != ProjectedSection(id: "a", label: "L", windows: [win(1)],
                                            sourceWorkspaceIndex: 0, sectionType: .unassigned))
    }

    // MARK: - workspace sections (positional, wire-index id)

    /// k-th workspace section ↔ workspaces[k]; id/sourceWorkspaceIndex come
    /// from `ws.index` even when index != array position (sparse catalog).
    @Test func workspaceSectionsMapPositionallyByWireIndex() {
        let wss = [
            ws(3, name: "A", windows: [win(1)]),
            ws(7, name: "B", windows: [win(2)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec(), wsSec()])
        #expect(r.sections.map(\.id) == ["ws:3", "ws:7"])
        #expect(r.sections.map(\.sourceWorkspaceIndex) == [3, 7])
        #expect(r.sections.map(\.sectionType) == [.workspace, .workspace])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])
        #expect(r.diagnostics.isEmpty)
    }

    /// Extra live workspaces (dynamic `facet workspace --add`) append at the
    /// tail of the workspace-section run.
    @Test func extraWorkspacesAppendAtTail() {
        let wss = [
            ws(0, name: "A", windows: []),
            ws(1, name: "B", windows: []),
            ws(2, name: "C", windows: []),
        ]
        // Only one workspace section, three live workspaces.
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec()])
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1", "ws:2"])
    }

    /// A NON-workspace (unassigned) section BETWEEN two workspace sections: the
    /// extras cursor (`insertExtrasAt`) tracks the LAST-filled workspace section,
    /// so a surplus live workspace lands AFTER the SECOND workspace section —
    /// past the intervening unassigned receptacle, not after the first. A
    /// regression that set the cursor only once (at the first workspace section)
    /// would yield ["ws:0", "unassigned:1", "ws:2", "ws:1"] and pass every
    /// single-ws-section extras test. Pins the moving-cursor semantics for a
    /// mixed section list.
    @Test func extraWorkspacesInsertAfterSecondWorkspaceSection() {
        let wss = [
            ws(0, name: "A", windows: []),
            ws(1, name: "B", windows: []),
            ws(2, name: "C", windows: []),
        ]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), unassigned("L"), wsSec()])
        #expect(r.sections.map(\.id) == ["ws:0", "unassigned:1", "ws:1", "ws:2"])
        #expect(r.sections[1].sectionType == .unassigned)
        #expect(r.diagnostics.isEmpty)
    }

    /// Surplus workspace sections (more than live workspaces) emit no section
    /// and add a diagnostic.
    @Test func surplusWorkspaceSectionDiagnosed() {
        let wss = [ws(0, name: "A", windows: []), ws(1, name: "B", windows: [])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), wsSec(), wsSec()])
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1"])
        #expect(r.diagnostics.count == 1)
        #expect(r.diagnostics[0].contains("workspace section #3"))
    }

    // MARK: - unassigned receptacle (§G: leftover = universe − shown)

    /// The unassigned section emits at its declaration position as a
    /// receptacle. A workspace window is shown in its own workspace section, so
    /// with no orphans the receptacle is EMPTY (no leftover) — but the section
    /// itself is present (id/label/type carried through).
    @Test func unassignedSectionEmitsReceptacle() {
        let wss = [ws(0, name: "A", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            wsSec(), unassigned("Other"),
        ])
        #expect(r.sections.map(\.id) == ["ws:0", "unassigned:1"])
        #expect(r.sections[1].sectionType == .unassigned)
        #expect(r.sections[1].id == "unassigned:1")
        #expect(r.sections[1].label == "Other")
        #expect(r.sections[1].windows.map(\.id.serverID) == [])  // win(1) shown in ws:0
        #expect(r.diagnostics.isEmpty)
    }

    /// A leftover orphan (in no workspace) is RESCUED into the unassigned
    /// receptacle. A workspace-resident window is NOT in it.
    @Test func leftoverOrphanRescuedIntoUnassigned() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), unassigned("Lost")],
            orphans: [win(9)])
        let recept = r.sections.first { $0.id == "unassigned:1" }
        #expect(recept?.windows.map(\.id.serverID) == [9])
        #expect(!(recept?.windows.map(\.id.serverID).contains(1) ?? true))
    }

    /// A workspace window is ALWAYS shown in its own workspace section, so it
    /// can never be leftover — never in the unassigned receptacle.
    @Test func workspaceWindowNeverInUnassigned() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), unassigned("Lost")])
        let recept = r.sections.first { $0.id == "unassigned:1" }
        #expect(recept?.windows.map(\.id.serverID) == [])
    }

    /// The id encodes the DECLARATION order, not the position among unassigned
    /// sections or the emitted-section count.
    @Test func unassignedIdUsesDeclOrder() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1)]),
            ws(1, name: "Web", windows: []),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [
            wsSec(), wsSec(), unassigned("Lost"),
        ])
        #expect(r.sections.last?.id == "unassigned:2")
    }

    /// Extra live workspaces insert at the tail of the workspace-section run —
    /// BEFORE the receptacle (which keeps its declaration-position id).
    @Test func unassignedPlacedAfterExtraWorkspaces() {
        let wss = [
            ws(0, name: "A", windows: []),
            ws(1, name: "B", windows: []),
            ws(2, name: "C", windows: []),
        ]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), unassigned("L")],
            orphans: [win(99)])   // no workspace → leftover
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1", "ws:2", "unassigned:1"])
        #expect(r.sections.last?.windows.map(\.id.serverID) == [99])
    }

    /// Only the FIRST unassigned section emits; a second one warns (the
    /// leftover set is singular, so a second receptacle is always empty).
    @Test func multipleUnassignedOnlyFirstEmitsWithDiag() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            wsSec(), unassigned("A"), unassigned("B"),
        ])
        let recepts = r.sections.filter { $0.sectionType == .unassigned }
        #expect(recepts.count == 1)
        #expect(recepts[0].id == "unassigned:1")
        #expect(recepts[0].label == "A")
        #expect(r.diagnostics.count == 1)
        #expect(r.diagnostics[0].contains("unassigned section #3 ignored"))
    }

    /// An unassigned receptacle as the ONLY section (no workspace section)
    /// collects EVERY window — workspace windows AND orphans — because `shown`
    /// is built only from emitted workspace sections, and here there are none,
    /// so universe − shown = the whole universe. A future optimization assuming
    /// workspace windows are always shown would silently drop all windows from
    /// an unassigned-only desktop.
    @Test func unassignedOnlySectionCollectsEveryWindow() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [unassigned("All")],
            orphans: [win(9)])
        #expect(r.sections.count == 1)
        #expect(r.sections[0].id == "unassigned:0")
        #expect(r.sections[0].sectionType == .unassigned)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1, 2, 9])
        #expect(r.diagnostics.isEmpty)
    }

    /// The receptacle preserves universe order (workspace windows then orphans,
    /// in their snapshot order) for the leftover.
    @Test func unassignedLeftoverPreservesUniverseOrder() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), unassigned("Lost")],
            orphans: [win(8), win(9)])   // both leftover, in order
        let recept = r.sections.first { $0.id == "unassigned:1" }
        #expect(recept?.windows.map(\.id.serverID) == [8, 9])
    }

    // MARK: - the projection is parking-AGNOSTIC (t-c6fm / t-pvay)

    /// A workspace section takes its windows VERBATIM — the tree is a
    /// filter-inventory, not a screen mirror. Isolate-park is a SCREEN-only
    /// concern owned by the catalog's `isolateParked` ledger and the projection
    /// never learns about it (t-pvay deleted the write-only `Window.isParked`
    /// that used to leak it into the model), so a parked window is indistinguishable
    /// here and shows in place exactly like any other.
    @Test func workspaceSectionTakesItsWindowsVerbatim() {
        let wss = [ws(0, name: "Main", windows: [win(10), win(30)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), unassigned("Lost")])
        #expect(r.sections.first { $0.sectionType == .workspace }?
            .windows.map(\.id.serverID) == [10, 30])        // both shown in place
        #expect(r.sections.first { $0.sectionType == .unassigned }?
            .windows.isEmpty == true)                       // nothing homeless
    }

    /// The grid + rail consume `project()` ONLY (a lens desktop is TREE-ONLY and
    /// loud-rejects both overviews; the tree's `projectLensDesktop` is the only
    /// minter of `.lens`). t-pvay deleted `GridPick.lens` / `RailPick.lens` /
    /// `OverviewCell.isLens` on the strength of that — so pin it: `project()` must
    /// never mint a `.lens` section, or those overviews grow a live lens path
    /// again with nothing to route it.
    @Test func projectNeverMintsALensSection() {
        let wss = [ws(0, name: "Main", windows: [win(10)]),
                   ws(1, name: "Web", windows: [win(20)])]
        for sections in [[wsSec()],
                         [wsSec(), unassigned("Lost")],
                         []] {                              // degrade path too
            let r = FilterProjection.project(workspaces: wss, sections: sections)
            #expect(r.sections.allSatisfy { $0.sectionType != .lens },
                    "project() minted a .lens section — the overviews cannot route it")
        }
    }

    // MARK: - orphans (EX-3 迷子: in NO workspace, rescued by the unassigned receptacle)

    /// An orphan NEVER lands in a workspace section (it is in no workspace) and,
    /// with no unassigned receptacle configured, shows up nowhere — no crash, no
    /// phantom section, workspace sections untouched.
    @Test func orphanNeverProjectsIntoWorkspaceSection() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec()], orphans: [win(9)])
        #expect(r.sections.map(\.id) == ["ws:0"])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])  // orphan absent
    }

    /// The default `orphans: []` keeps every existing call site byte-identical
    /// (the parameter is purely additive).
    @Test func orphansDefaultEmptyIsByteIdentical() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let secs = [wsSec()]
        #expect(
            FilterProjection.project(workspaces: wss, sections: secs)
                == FilterProjection.project(workspaces: wss, sections: secs, orphans: []))
    }

    // MARK: - scale (perf baseline)

    @Test func projectsAtScale100Windows5WorkspaceSections() {
        var wss: [Workspace] = []
        var nextID = 1
        for d in 0..<5 {
            var windows: [Window] = []
            for _ in 0..<20 {
                windows.append(win(nextID, tags: nextID % 2 == 0 ? ["even"] : ["odd"]))
                nextID += 1
            }
            wss.append(ws(d, name: "WS\(d)", windows: windows))
        }
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), wsSec(), wsSec(), wsSec(), wsSec()])
        #expect(r.sections.count == 5)
        #expect(r.sections.allSatisfy { $0.windows.count == 20 })
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1", "ws:2", "ws:3", "ws:4"])
        #expect(r.diagnostics.isEmpty)
    }
}
