import Testing
@testable import FacetCore

/// `FilterProjection` — `[Workspace]` → `[ProjectedSection]` (the section/lens
/// model body). workspace sections map positionally to live workspaces (id
/// from the wire index), lens sections multi-match, and an opt-in `unassigned`
/// section (§G) rescues the leftover (universe − shown — windows in no other
/// emitted section; first emits, extras warn). Degrade (no sections) stays
/// byte-identical to by-workspace. Pure; CI-only (CLT can't run `swift test`).
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

    private func wsSec() -> DesktopSection { DesktopSection(type: .workspace) }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }
    private func unassigned(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label, unassigned: true)
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
                                            sourceWorkspaceIndex: 0, sectionType: .lens))
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

    /// The tail insertion goes BEFORE a later lens section, not at the very
    /// end (workspaces group together in the tree).
    @Test func extraWorkspacesInsertBeforeLaterLens() {
        let wss = [
            ws(0, name: "A", windows: [win(1, tags: ["x"])]),
            ws(1, name: "B", windows: []),
        ]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), lens("L", "tag~=x")])
        #expect(r.sections.map(\.id) == ["ws:0", "ws:1", "section:1:L"])
        #expect(r.sections[2].sectionType == .lens)
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

    // MARK: - lens sections (multi-match)

    @Test func lensMatchSelectsWindowsAcrossWorkspaces() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1, tags: ["web"]), win(2, tags: ["code"])]),
            ws(1, name: "Web", windows: [win(3, tags: ["web"])]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Web", "tag~=web")])
        #expect(r.sections.count == 1)
        #expect(r.sections[0].id == "section:0:Web")
        #expect(r.sections[0].sourceWorkspaceIndex == nil)
        #expect(r.sections[0].sectionType == .lens)
        #expect(r.sections[0].windows.map(\.id.serverID) == [1, 3])  // ws then win order
    }

    @Test func multiMatchWindowInMultipleLensSections() {
        let wss = [ws(0, name: "Dev",
                      windows: [win(1, app: "Safari", tags: ["web", "work"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Web", "tag~=web"), lens("Work", "tag~=work"),
            lens("Apple", "app=Safari"), lens("None", "tag~=nope"),
        ])
        #expect(r.sections.map(\.label) == ["Web", "Work", "Apple", "None"])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])
        #expect(r.sections[1].windows.map(\.id.serverID) == [1])
        #expect(r.sections[2].windows.map(\.id.serverID) == [1])
        #expect(r.sections[3].windows.map(\.id.serverID) == [])
    }

    @Test func workspaceFieldResolvesViaOverlay() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("DevOnly", "workspace=Dev")])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1, 2])
    }

    @Test func notTagSelectsOnlyUntaggedWindows() {
        let wss = [ws(0, name: "Dev", windows: [
            win(1, tags: ["web"]), win(2), win(3, tags: ["code"]), win(4),
        ])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Untagged", "not tag"), lens("Web", "tag~=web"),
        ])
        #expect(r.sections[0].windows.map(\.id.serverID) == [2, 4])
        #expect(r.sections[1].windows.map(\.id.serverID) == [1])
    }

    /// Declaration order is preserved across a mixed-type array; the lens id's
    /// declOrder is the section's index in the full array (not among lenses).
    @Test func declarationOrderPreservedAcrossMixedTypes() {
        let wss = [ws(0, name: "A", windows: [win(1, tags: ["x"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("First", "tag~=x"),   // decl 0
            wsSec(),                    // decl 1 → ws:0
            lens("Third", "tag~=x"),    // decl 2
        ])
        #expect(r.sections.map(\.id) == ["section:0:First", "ws:0", "section:2:Third"])
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

    /// A leftover orphan (no workspace, matched by no lens) is RESCUED into the
    /// unassigned receptacle. A workspace-resident window is NOT in it.
    @Test func leftoverOrphanRescuedIntoUnassigned() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), lens("Web", "tag~=web"), unassigned("Lost")],
            orphans: [win(9, tags: ["code"])])   // matches no lens
        let recept = r.sections.first { $0.id == "unassigned:2" }
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

    /// An orphan caught by a lens is SHOWN there → not leftover, so the
    /// unassigned receptacle does not also contain it.
    @Test func orphanMatchedByLensNotInUnassigned() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), lens("Web", "tag~=web"), unassigned("Lost")],
            orphans: [win(9, tags: ["web"])])   // shown in the lens
        let recept = r.sections.first { $0.id == "unassigned:2" }
        #expect(!(recept?.windows.map(\.id.serverID).contains(9) ?? true))
    }

    /// All windows shown elsewhere → the receptacle is emitted but empty.
    @Test func unassignedEmptyWhenNoLeftover() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["web"])])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), lens("Web", "tag~=web"), unassigned("Lost")])
        let recept = r.sections.first { $0.id == "unassigned:2" }
        #expect(recept != nil)
        #expect(recept?.windows.map(\.id.serverID) == [])
    }

    /// The id encodes the DECLARATION order, not the position among unassigned
    /// sections or the emitted-section count.
    @Test func unassignedIdUsesDeclOrder() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            wsSec(), lens("Web", "tag~=web"), unassigned("Lost"),
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
            orphans: [win(99)])   // no lens → leftover
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

    /// The receptacle preserves universe order (workspace windows then orphans,
    /// in their snapshot order) for the leftover.
    @Test func unassignedLeftoverPreservesUniverseOrder() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), lens("Web", "tag~=web"), unassigned("Lost")],
            orphans: [win(8), win(9)])   // both unmatched, in order
        let recept = r.sections.first { $0.id == "unassigned:2" }
        #expect(recept?.windows.map(\.id.serverID) == [8, 9])
    }

    // MARK: - loud-but-non-fatal

    @Test func malformedLensSkippedWithDiagnostic() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Bad", "tag~="),       // malformed
            lens("Good", "tag~=a"),
        ])
        #expect(r.sections.map(\.label) == ["Good"])
        #expect(r.sections[0].id == "section:1:Good")  // decl index preserved
        #expect(r.diagnostics.count == 1)
        #expect(r.diagnostics[0].hasPrefix("config: section \"Bad\" match: "))
        #expect(r.diagnostics[0].contains("\n"))
        #expect(r.diagnostics[0].contains("^"))
    }

    @Test func unknownFieldDiagnosticButStillProjects() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "bogusfield=x")])
        #expect(r.sections.count == 1)
        #expect(r.sections[0].windows.count == 0)
        #expect(r.diagnostics == [
            "config: section \"Typo\" match references unknown field(s): bogusfield"])
    }

    @Test func unknownFieldsSortedAndJoined() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "zzz=1 and aaa=2")])
        #expect(r.diagnostics[0].hasSuffix("unknown field(s): aaa, zzz"))
    }

    // MARK: - orphans (EX-3 迷子: in NO workspace, project into lens sections only)

    /// An orphan (no workspace assignment) projects into a `not workspace`
    /// lens section — the 迷子 receptacle. A lens is a pure VIEW (t-0021):
    /// `FilterProjection` is the single path that lists an orphan in its
    /// matching lens section, so the tree/grid/rail can't disagree (EX-2's
    /// "3 views = same section list").
    @Test func orphanProjectsIntoNotWorkspaceLens() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["web"])])]
        let orphan = win(9, app: "Chrome", tags: ["web"])
        let r = FilterProjection.project(
            workspaces: wss,
            sections: [wsSec(), lens("迷子", "not workspace")],
            orphans: [orphan])
        let receptacle = r.sections.first { $0.label == "迷子" }
        #expect(receptacle?.windows.map(\.id.serverID) == [9])
        #expect(receptacle?.sectionType == .lens)
    }

    /// An orphan NEVER lands in a workspace section (it is in no workspace).
    @Test func orphanNeverProjectsIntoWorkspaceSection() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec()], orphans: [win(9)])
        #expect(r.sections.map(\.id) == ["ws:0"])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1])  // orphan absent
    }

    /// An ASSIGNED window in an UNNAMED workspace (name "") is NOT caught by
    /// `not workspace` even with an orphan present — presence is keyed off the
    /// ASSIGNMENT (nil), not the display name. Only the orphan (ws=nil) matches.
    @Test func assignedUnnamedWindowNotCaughtByNotWorkspace() {
        let wss = [ws(0, name: "", windows: [win(1)])]   // unnamed but ASSIGNED
        let r = FilterProjection.project(
            workspaces: wss, sections: [lens("迷子", "not workspace")],
            orphans: [win(9)])
        #expect(r.sections[0].windows.map(\.id.serverID) == [9])  // only the orphan
    }

    /// An orphan matches a CONTENT lens by its own fields (the tag it inherited
    /// on the DnD-to-lens move) and is APPENDED after the workspace-resident
    /// matches (the workspaces loop runs first, orphans after).
    @Test func orphanMatchesContentLensAppendedAfterWorkspaceWindows() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["web"])])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [lens("Web", "tag~=web")],
            orphans: [win(9, tags: ["web"])])
        #expect(r.sections[0].windows.map(\.id.serverID) == [1, 9])
    }

    /// An orphan that matches NO lens shows up nowhere — no crash, no phantom
    /// section, and workspace sections stay untouched.
    @Test func orphanMatchingNoLensVanishes() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), lens("Web", "tag~=web")],
            orphans: [win(9, tags: ["code"])])
        #expect(r.sections.allSatisfy {
            !$0.windows.map(\.id.serverID).contains(9) })
    }

    /// The default `orphans: []` keeps every existing call site byte-identical
    /// (the parameter is purely additive).
    @Test func orphansDefaultEmptyIsByteIdentical() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["web"])])]
        let secs = [wsSec(), lens("Web", "tag~=web")]
        #expect(
            FilterProjection.project(workspaces: wss, sections: secs)
                == FilterProjection.project(workspaces: wss, sections: secs, orphans: []))
    }

    // MARK: - scale (perf baseline)

    @Test func projectsAtScale100Windows10Lenses() {
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
        var sections = [lens("Even", "tag~=even")]
        for i in 0..<9 { sections.append(lens("G\(i)", "tag~=odd")) }
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        #expect(r.sections.count == 10)
        #expect(r.sections[0].windows.count == 50)
        #expect(r.sections[1].windows.count == 50)
        #expect(r.diagnostics.isEmpty)
    }
}
