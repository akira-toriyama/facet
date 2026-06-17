import XCTest
@testable import FacetCore

/// `FilterProjection` — `[Workspace]` → `[FilterGroup]` (the section/lens
/// model body). workspace sections map positionally to live workspaces (id
/// from the wire index), lens sections multi-match, unassigned is deferred.
/// Degrade (no sections) stays byte-identical to by-workspace. Pure; CI-only
/// (CLT can't run `swift test`).
final class FilterProjectionTests: XCTestCase {

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

    // MARK: - degrade (no sections → 1:1 by-workspace, byte-identical)

    func testDegradeMapsWorkspacesOneToOne() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [])
        XCTAssertTrue(r.diagnostics.isEmpty)
        XCTAssertEqual(r.groups.count, 2)
        XCTAssertEqual(r.groups[0].id, "ws:0")
        XCTAssertEqual(r.groups[0].label, "Dev")
        XCTAssertEqual(r.groups[0].sourceWorkspaceIndex, 0)
        XCTAssertEqual(r.groups[0].sectionType, .workspace)
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 2])
        XCTAssertEqual(r.groups[1].id, "ws:1")
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [3])
    }

    func testDegradeEmptyWorkspaces() {
        let r = FilterProjection.project(workspaces: [], sections: [])
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    /// Locks the FROZEN 0-based WIRE-index invariant: id/sourceWorkspaceIndex
    /// come from `Workspace.index`, NOT the array position, and the degrade
    /// preserves array order (no re-sort). A regression breaks PR8's
    /// byte-identical --focus/--move-to targeting.
    func testDegradeUsesWireIndexNotArrayPosition() {
        let wss = [
            ws(5, name: "Dev", windows: [win(1)]),
            ws(2, name: "Web", windows: [win(2)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [])
        XCTAssertEqual(r.groups[0].id, "ws:5")
        XCTAssertEqual(r.groups[0].sourceWorkspaceIndex, 5)
        XCTAssertEqual(r.groups[1].id, "ws:2")
        XCTAssertEqual(r.groups[1].sourceWorkspaceIndex, 2)
    }

    /// CONVERGENCE: for a FIXED `[Workspace]`, an all-`workspace`-sections
    /// config produces the SAME groups as the section-less degrade.
    func testWorkspaceSectionsConvergeWithDegrade() {
        let wss = [
            ws(5, name: "Dev", windows: [win(1)]),
            ws(2, name: "Web", windows: [win(2)]),
        ]
        let degrade = FilterProjection.project(workspaces: wss, sections: [])
        let sectioned = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), wsSec()])
        XCTAssertEqual(degrade, sectioned)
    }

    func testResultEquatableRoundTrip() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let expected = FilterProjection.Result(
            groups: [FilterGroup(id: "ws:0", label: "Dev",
                                 windows: [win(1), win(2)], sourceWorkspaceIndex: 0)],
            diagnostics: [])
        XCTAssertEqual(expected, FilterProjection.project(workspaces: wss, sections: []))
        // `==` discriminates each compared field — including sectionType.
        let base = FilterGroup(id: "a", label: "L", windows: [win(1)],
                               sourceWorkspaceIndex: 0, sectionType: .workspace)
        XCTAssertNotEqual(base, FilterGroup(id: "b", label: "L", windows: [win(1)], sourceWorkspaceIndex: 0))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "X", windows: [win(1)], sourceWorkspaceIndex: 0))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "L", windows: [win(1)], sourceWorkspaceIndex: 1))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "L", windows: [win(2)], sourceWorkspaceIndex: 0))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "L", windows: [win(1)],
                                            sourceWorkspaceIndex: 0, sectionType: .lens))
    }

    // MARK: - workspace sections (positional, wire-index id)

    /// k-th workspace section ↔ workspaces[k]; id/sourceWorkspaceIndex come
    /// from `ws.index` even when index != array position (sparse catalog).
    func testWorkspaceSectionsMapPositionallyByWireIndex() {
        let wss = [
            ws(3, name: "A", windows: [win(1)]),
            ws(7, name: "B", windows: [win(2)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec(), wsSec()])
        XCTAssertEqual(r.groups.map(\.id), ["ws:3", "ws:7"])
        XCTAssertEqual(r.groups.map(\.sourceWorkspaceIndex), [3, 7])
        XCTAssertEqual(r.groups.map(\.sectionType), [.workspace, .workspace])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1])
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    /// Extra live workspaces (dynamic `facet workspace --add`) append at the
    /// tail of the workspace-section run.
    func testExtraWorkspacesAppendAtTail() {
        let wss = [
            ws(0, name: "A", windows: []),
            ws(1, name: "B", windows: []),
            ws(2, name: "C", windows: []),
        ]
        // Only one workspace section, three live workspaces.
        let r = FilterProjection.project(workspaces: wss, sections: [wsSec()])
        XCTAssertEqual(r.groups.map(\.id), ["ws:0", "ws:1", "ws:2"])
    }

    /// The tail insertion goes BEFORE a later lens section, not at the very
    /// end (workspaces group together in the tree).
    func testExtraWorkspacesInsertBeforeLaterLens() {
        let wss = [
            ws(0, name: "A", windows: [win(1, tags: ["x"])]),
            ws(1, name: "B", windows: []),
        ]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), lens("L", "tag~=x")])
        XCTAssertEqual(r.groups.map(\.id), ["ws:0", "ws:1", "section:1:L"])
        XCTAssertEqual(r.groups[2].sectionType, .lens)
    }

    /// Surplus workspace sections (more than live workspaces) emit no group
    /// and add a diagnostic.
    func testSurplusWorkspaceSectionDiagnosed() {
        let wss = [ws(0, name: "A", windows: []), ws(1, name: "B", windows: [])]
        let r = FilterProjection.project(
            workspaces: wss, sections: [wsSec(), wsSec(), wsSec()])
        XCTAssertEqual(r.groups.map(\.id), ["ws:0", "ws:1"])
        XCTAssertEqual(r.diagnostics.count, 1)
        XCTAssertTrue(r.diagnostics[0].contains("workspace section #3"))
    }

    // MARK: - lens sections (multi-match)

    func testLensMatchSelectsWindowsAcrossWorkspaces() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1, tags: ["web"]), win(2, tags: ["code"])]),
            ws(1, name: "Web", windows: [win(3, tags: ["web"])]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Web", "tag~=web")])
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].id, "section:0:Web")
        XCTAssertNil(r.groups[0].sourceWorkspaceIndex)
        XCTAssertEqual(r.groups[0].sectionType, .lens)
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 3])  // ws then win order
    }

    func testMultiMatchWindowInMultipleLensSections() {
        let wss = [ws(0, name: "Dev",
                      windows: [win(1, app: "Safari", tags: ["web", "work"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Web", "tag~=web"), lens("Work", "tag~=work"),
            lens("Apple", "app=Safari"), lens("None", "tag~=nope"),
        ])
        XCTAssertEqual(r.groups.map(\.label), ["Web", "Work", "Apple", "None"])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[2].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[3].windows.map(\.id.serverID), [])
    }

    func testWorkspaceFieldResolvesViaOverlay() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("DevOnly", "workspace=Dev")])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 2])
    }

    func testNotTagSelectsOnlyUntaggedWindows() {
        let wss = [ws(0, name: "Dev", windows: [
            win(1, tags: ["web"]), win(2), win(3, tags: ["code"]), win(4),
        ])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Untagged", "not tag"), lens("Web", "tag~=web"),
        ])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [2, 4])
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [1])
    }

    /// Declaration order is preserved across a mixed-type array; the lens id's
    /// declOrder is the section's index in the full array (not among lenses).
    func testDeclarationOrderPreservedAcrossMixedTypes() {
        let wss = [ws(0, name: "A", windows: [win(1, tags: ["x"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("First", "tag~=x"),   // decl 0
            wsSec(),                    // decl 1 → ws:0
            lens("Third", "tag~=x"),    // decl 2
        ])
        XCTAssertEqual(r.groups.map(\.id), ["section:0:First", "ws:0", "section:2:Third"])
    }

    // MARK: - unassigned is deferred (no group)

    func testUnassignedSectionEmitsNoGroup() {
        let wss = [ws(0, name: "A", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            wsSec(), DesktopSection(type: .unassigned, label: "Other"),
        ])
        // Only the workspace group; the unassigned section is skipped.
        XCTAssertEqual(r.groups.map(\.id), ["ws:0"])
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    // MARK: - loud-but-non-fatal

    func testMalformedLensSkippedWithDiagnostic() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [
            lens("Bad", "tag~="),       // malformed
            lens("Good", "tag~=a"),
        ])
        XCTAssertEqual(r.groups.map(\.label), ["Good"])
        XCTAssertEqual(r.groups[0].id, "section:1:Good")  // decl index preserved
        XCTAssertEqual(r.diagnostics.count, 1)
        XCTAssertTrue(r.diagnostics[0].hasPrefix("config: section \"Bad\" match: "))
        XCTAssertTrue(r.diagnostics[0].contains("\n"))
        XCTAssertTrue(r.diagnostics[0].contains("^"))
    }

    func testUnknownFieldDiagnosticButStillProjects() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "bogusfield=x")])
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].windows.count, 0)
        XCTAssertEqual(r.diagnostics, [
            "config: section \"Typo\" match references unknown field(s): bogusfield"])
    }

    func testUnknownFieldsSortedAndJoined() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "zzz=1 and aaa=2")])
        XCTAssertTrue(r.diagnostics[0].hasSuffix("unknown field(s): aaa, zzz"))
    }

    // MARK: - scale (perf baseline)

    func testProjectsAtScale100Windows10Lenses() {
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
        XCTAssertEqual(r.groups.count, 10)
        XCTAssertEqual(r.groups[0].windows.count, 50)
        XCTAssertEqual(r.groups[1].windows.count, 50)
        XCTAssertTrue(r.diagnostics.isEmpty)
    }
}
