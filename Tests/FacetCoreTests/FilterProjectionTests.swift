import Testing
@testable import FacetCore

/// `FilterProjection` — `[Workspace]` → `[ProjectedSection]`. EVERY
/// `[[desktop.N.section]]` is a WORKSPACE SPATIAL cell: section-lens went in
/// t-ec9s, the `unassigned` receptacle in t-6rbc. So sections map 1:1 onto the
/// live workspaces (id from the wire index) and the degrade path is not a
/// degrade at all — it is the same answer. `sections` survives in the signature
/// only to diagnose "more cells declared than there are live workspaces". The
/// `lens` concept lives ONLY on a typed ISOLATE DESKTOP
/// (`projectIsolateDesktop`), never on a config section. Pure; CI-only.
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

    /// A workspace SPATIAL cell (`[[desktop.N.section]]`) — the only kind.
    private func wsSec() -> DesktopSection { DesktopSection() }

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
                                            sourceWorkspaceIndex: 0, sectionType: .holding))
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

    /// Three live workspaces, two declared cells → all three project, in wire
    /// order. (This used to pin where the extras got SPLICED relative to an
    /// intervening `unassigned` receptacle — a moving-cursor invariant that
    /// disappeared with the receptacle: with every section a workspace cell,
    /// there is nothing to splice around.)
    @Test func extraWorkspacesAppendInWireOrder() {
        let wss = [
            ws(0, name: "A", windows: []),
            ws(1, name: "B", windows: []),
            ws(2, name: "C", windows: []),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec(), wsSec()])
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1", "ws:2"])
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

    // MARK: - the projection is parking-AGNOSTIC (t-c6fm / t-pvay)

    /// A workspace section takes its windows VERBATIM — the tree is a
    /// filter-inventory, not a screen mirror. Isolate-park is a SCREEN-only
    /// concern owned by the catalog's `isolateParked` ledger and the projection
    /// never learns about it (t-pvay deleted the write-only `Window.isParked`
    /// that used to leak it into the model), so a parked window is indistinguishable
    /// here and shows in place exactly like any other.
    @Test func workspaceSectionTakesItsWindowsVerbatim() {
        let wss = [ws(0, name: "Main", windows: [win(10), win(30)])]
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec()])
        #expect(r.sections.first { $0.sectionType == .workspace }?
            .windows.map(\.id.serverID) == [10, 30])        // both shown in place
    }

    /// The grid + rail consume `project()` ONLY (an isolate desktop is TREE-ONLY and
    /// loud-rejects both overviews; the tree's `projectIsolateDesktop` is the only
    /// minter of `.matched`). t-pvay deleted `GridPick.lens` / `RailPick.lens` (both since deleted) /
    /// `OverviewCell.isLens` on the strength of that — so pin it: `project()` must
    /// never mint a `.matched` section, or those overviews grow a live lens path
    /// again with nothing to route it.
    @Test func projectNeverMintsAMatchedSection() {
        let wss = [ws(0, name: "Main", windows: [win(10)]),
                   ws(1, name: "Web", windows: [win(20)])]
        for sections in [[wsSec()], [wsSec(), wsSec()], []] {   // degrade too
            let r = FilterProjection.project(workspaces: wss, sections: sections)
            #expect(r.sections.allSatisfy { $0.sectionType != .matched },
                    "project() minted a .matched section — the overviews cannot route it")
        }
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
