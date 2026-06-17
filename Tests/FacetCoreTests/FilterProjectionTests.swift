import XCTest
@testable import FacetCore

/// `FilterProjection` — `[Workspace]` → `[FilterGroup]` (the section/lens
/// model). PR1 SCOPE: behaviour-preserving signature follow-on of the
/// `DesktopGroup` → `DesktopSection` reshape — only `match`-bearing (`lens`)
/// sections project here, exactly as a group did; the real per-type body
/// (workspace implicit match, unassigned AND-set) lands in PR3. Pure;
/// CI-only (CLT can't run `swift test`).
final class FilterProjectionTests: XCTestCase {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil,
               tags: tags)
    }

    private func ws(_ index: Int, name: String, windows: [Window],
                    active: Bool = false) -> Workspace {
        Workspace(index: index, name: name, isActive: active,
                  layoutMode: "float", windows: windows)
    }

    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    // MARK: - degrade (no sections → 1:1 by-workspace)

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
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 2])
        XCTAssertEqual(r.groups[1].id, "ws:1")
        XCTAssertEqual(r.groups[1].sourceWorkspaceIndex, 1)
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [3])
    }

    func testDegradeEmptyWorkspaces() {
        let r = FilterProjection.project(workspaces: [], sections: [])
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    /// Locks the FROZEN 0-based WIRE-index invariant: id/sourceWorkspaceIndex
    /// come from `Workspace.index`, NOT the array position. A regression to
    /// `.enumerated()` offset would break PR8's byte-identical --focus/
    /// --move-to targeting; this fails it.
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

    /// Equality round-trip: exercises FilterGroup's custom `==` (and
    /// `Result`'s derived `==`) that PR8 relies on for byte-identical
    /// degrade comparison — every other test drills into fields.
    func testResultEquatableRoundTrip() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let expected = FilterProjection.Result(
            groups: [FilterGroup(id: "ws:0", label: "Dev",
                                 windows: [win(1), win(2)], sourceWorkspaceIndex: 0)],
            diagnostics: [])
        XCTAssertEqual(expected, FilterProjection.project(workspaces: wss, sections: []))
        // `==` discriminates each compared field.
        let base = FilterGroup(id: "a", label: "L", windows: [win(1)], sourceWorkspaceIndex: 0)
        XCTAssertNotEqual(base, FilterGroup(id: "b", label: "L", windows: [win(1)], sourceWorkspaceIndex: 0))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "X", windows: [win(1)], sourceWorkspaceIndex: 0))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "L", windows: [win(1)], sourceWorkspaceIndex: 1))
        XCTAssertNotEqual(base, FilterGroup(id: "a", label: "L", windows: [win(2)], sourceWorkspaceIndex: 0))
    }

    // MARK: - lens sections (match-bearing; behaviour-preserving in PR1)

    func testLensMatchSelectsWindowsAcrossWorkspaces() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1, tags: ["web"]), win(2, tags: ["code"])]),
            ws(1, name: "Web", windows: [win(3, tags: ["web"])]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Web", "tag~=web")])
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].label, "Web")
        XCTAssertNil(r.groups[0].sourceWorkspaceIndex)  // multi-WS lens section
        XCTAssertEqual(r.groups[0].id, "section:0:Web")
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 3])  // ws then win order
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    /// Multi-match: a window appears in EVERY section it satisfies.
    func testMultiMatchWindowInMultipleSections() {
        let wss = [ws(0, name: "Dev",
                      windows: [win(1, app: "Safari", tags: ["web", "work"])])]
        let sections = [
            lens("Web", "tag~=web"),
            lens("Work", "tag~=work"),
            lens("Apple", "app=Safari"),
            lens("None", "tag~=nope"),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        XCTAssertEqual(r.groups.map(\.label), ["Web", "Work", "Apple", "None"])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[2].windows.map(\.id.serverID), [1])
        XCTAssertEqual(r.groups[3].windows.map(\.id.serverID), [])  // matches nothing
    }

    /// `workspace=NAME` resolves via the projection's workspace-name overlay
    /// (a bare `Window` no-matches `workspace`).
    func testWorkspaceFieldResolvesViaOverlay() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("DevOnly", "workspace=Dev")])
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [1, 2])
    }

    /// `not tag` (untagged window) — the old `_default` bucket, a frozen
    /// semantic this projection is the first to compile. An untagged window
    /// must MATCH `not tag` but NOT a `tag~=` section, exercised through the
    /// real overlay (`filterHas("tag")` empty-tags path).
    func testNotTagSelectsOnlyUntaggedWindows() {
        let wss = [ws(0, name: "Dev", windows: [
            win(1, tags: ["web"]), win(2), win(3, tags: ["code"]), win(4),
        ])]
        let sections = [
            lens("Untagged", "not tag"),
            lens("Web", "tag~=web"),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        XCTAssertEqual(r.groups[0].windows.map(\.id.serverID), [2, 4])   // untagged only
        XCTAssertEqual(r.groups[1].windows.map(\.id.serverID), [1])      // tagged distinct
    }

    func testSectionOrderIsDeclarationOrder() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let sections = [lens("C", "tag~=a"), lens("A", "tag~=a"), lens("B", "tag~=a")]
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        XCTAssertEqual(r.groups.map(\.label), ["C", "A", "B"])
    }

    /// PR1: non-match sections (workspace / unassigned) contribute nothing,
    /// but the declaration index still counts them so a lens section's id
    /// stays stable as the body grows.
    func testNonMatchSectionsSkippedButCountForDeclOrder() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let sections = [
            DesktopSection(type: .workspace),       // decl 0 — no match, skipped
            DesktopSection(type: .unassigned, label: "Other"),  // decl 1 — skipped
            lens("A", "tag~=a"),                    // decl 2 — projects
        ]
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        XCTAssertEqual(r.groups.map(\.label), ["A"])
        XCTAssertEqual(r.groups[0].id, "section:2:A")  // decl index preserved
    }

    // MARK: - loud-but-non-fatal

    func testMalformedMatchSectionSkippedWithDiagnostic() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let sections = [
            lens("Bad", "tag~="),       // malformed
            lens("Good", "tag~=a"),
        ]
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        // Bad section omitted; Good still projects.
        XCTAssertEqual(r.groups.map(\.label), ["Good"])
        XCTAssertEqual(r.groups[0].id, "section:1:Good")  // decl index preserved
        XCTAssertEqual(r.diagnostics.count, 1)
        // Lock the projection-owned message shape: prefix + quoted label +
        // two-line caret form (without coupling to the lexer's exact text).
        XCTAssertTrue(r.diagnostics[0].hasPrefix("config: section \"Bad\" match: "))
        XCTAssertTrue(r.diagnostics[0].contains("\n"))
        XCTAssertTrue(r.diagnostics[0].contains("^"))
    }

    func testUnknownFieldDiagnosticButStillProjects() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"])])]
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "bogusfield=x")])
        // Section still appears (valid parse), just no-matches; warning emitted.
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].windows.count, 0)
        // Fully deterministic shape here — lock it exactly.
        XCTAssertEqual(r.diagnostics, [
            "config: section \"Typo\" match references unknown field(s): bogusfield"])
    }

    /// Multiple unknown fields are deterministically SORTED + `, `-joined
    /// (the contract that propagates into PR8 logging).
    func testUnknownFieldsSortedAndJoined() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        // Referenced in non-sorted source order (zzz before aaa).
        let r = FilterProjection.project(workspaces: wss, sections: [lens("Typo", "zzz=1 and aaa=2")])
        XCTAssertTrue(r.diagnostics[0].hasSuffix("unknown field(s): aaa, zzz"))
    }

    // MARK: - scale (perf baseline)

    func testProjectsAtScale100Windows10Sections() {
        // 100 windows spread over 5 workspaces; even ids tagged "even".
        var wss: [Workspace] = []
        var nextID = 1
        for d in 0..<5 {
            var windows: [Window] = []
            for _ in 0..<20 {
                let tags = nextID % 2 == 0 ? ["even"] : ["odd"]
                windows.append(win(nextID, tags: tags))
                nextID += 1
            }
            wss.append(ws(d, name: "WS\(d)", windows: windows))
        }
        var sections = [lens("Even", "tag~=even")]
        for i in 0..<9 { sections.append(lens("G\(i)", "tag~=odd")) }
        let r = FilterProjection.project(workspaces: wss, sections: sections)
        XCTAssertEqual(r.groups.count, 10)
        XCTAssertEqual(r.groups[0].windows.count, 50)   // 50 even
        XCTAssertEqual(r.groups[1].windows.count, 50)   // 50 odd
        XCTAssertTrue(r.diagnostics.isEmpty)
    }
}
