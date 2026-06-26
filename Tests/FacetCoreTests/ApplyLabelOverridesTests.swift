import XCTest
@testable import FacetCore

/// §E: `applyLabelOverrides` — the PURE display-label overlay at the heart of
/// the runtime section rename. Invariants under test: only `.lens` and
/// `.unassigned` sections are relabeled (§G; a workspace label comes from the
/// catalog); the section `id` is NEVER changed (identity stays stable for
/// `--focus index:N` + the active-lens highlight); an absent key leaves the
/// section untouched; a present key swaps only the `label`. Pure → headless
/// (no Xcode needed for the logic; `swift test` still needs XCTest on the box).
final class ApplyLabelOverridesTests: XCTestCase {

    private func win(_ id: Int) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "App", title: "",
               isFocused: false, isFloating: false, frame: nil, tags: [])
    }

    private func lensSec(id: String, label: String,
                         windows: [Window] = []) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: windows,
                         sourceWorkspaceIndex: nil, sectionType: .lens)
    }

    private func wsSec(id: String, label: String, src: Int,
                       windows: [Window] = []) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: windows,
                         sourceWorkspaceIndex: src, sectionType: .workspace)
    }

    private func unassignedSec(id: String, label: String,
                               windows: [Window] = []) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: windows,
                         sourceWorkspaceIndex: nil, sectionType: .unassigned)
    }

    // MARK: - empty override is a no-op

    func testEmptyOverrideReturnsInputUnchanged() {
        let secs = [lensSec(id: "section:0:Web", label: "Web"),
                    wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: [:])
        XCTAssertEqual(out, secs)
    }

    // MARK: - present key relabels a lens (display only, id frozen)

    func testPresentKeyRelabelsLensKeepingID() {
        let secs = [lensSec(id: "section:0:Web", label: "Web",
                            windows: [win(1), win(2)])]
        let out = applyLabelOverrides(secs, to: ["section:0:Web": "My Lens"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "section:0:Web")          // id NEVER changes
        XCTAssertEqual(out[0].label, "My Lens")             // display swapped
        XCTAssertEqual(out[0].sectionType, .lens)
        XCTAssertEqual(out[0].sourceWorkspaceIndex, nil)
        XCTAssertEqual(out[0].windows.map(\.id.serverID), [1, 2])  // windows intact
    }

    // MARK: - absent key leaves the section untouched

    func testAbsentKeyLeavesSectionUntouched() {
        let secs = [lensSec(id: "section:0:Web", label: "Web"),
                    lensSec(id: "section:1:Mail", label: "Mail")]
        let out = applyLabelOverrides(secs, to: ["section:9:Gone": "Stale"])
        XCTAssertEqual(out, secs)                            // orphan key = no-op
    }

    func testMixedSomeKeysPresentSomeAbsent() {
        let secs = [lensSec(id: "section:0:Web", label: "Web"),
                    lensSec(id: "section:1:Mail", label: "Mail")]
        let out = applyLabelOverrides(secs, to: ["section:1:Mail": "Inbox"])
        XCTAssertEqual(out[0].label, "Web")                 // untouched
        XCTAssertEqual(out[1].label, "Inbox")               // relabeled
        XCTAssertEqual(out[1].id, "section:1:Mail")         // id frozen
    }

    // MARK: - only .lens is relabeled (workspace label is catalog-owned)

    func testWorkspaceSectionIsNeverRelabeled() {
        // Even if a workspace-id key is (wrongly) present, it is ignored —
        // workspace labels come from the catalog (workspaceNames), not here.
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: ["ws:0": "ShouldNotApply"])
        XCTAssertEqual(out, secs)
        XCTAssertEqual(out[0].label, "Dev")
    }

    func testWorkspaceUntouchedWhileLensRelabeledInSameList() {
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0),
                    lensSec(id: "section:1:Web", label: "Web")]
        let out = applyLabelOverrides(secs,
            to: ["ws:0": "Nope", "section:1:Web": "Browser"])
        XCTAssertEqual(out[0].label, "Dev")                 // workspace ignored
        XCTAssertEqual(out[1].label, "Browser")             // lens applied
    }

    // MARK: - §G: unassigned sections are relabeled (id frozen)

    func testPresentKeyRelabelsUnassignedKeepingID() {
        let secs = [unassignedSec(id: "unassigned:2", label: "Lost",
                                  windows: [win(1)]),
                    lensSec(id: "section:0:Web", label: "Web"),
                    wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: ["unassigned:2": "その他"])
        XCTAssertEqual(out[0].id, "unassigned:2")            // id NEVER changes
        XCTAssertEqual(out[0].label, "その他")               // display swapped
        XCTAssertEqual(out[0].sectionType, .unassigned)
        XCTAssertEqual(out[0].windows.map(\.id.serverID), [1])  // windows intact
        XCTAssertEqual(out[1].label, "Web")                  // sibling lens untouched
        XCTAssertEqual(out[2].label, "Dev")                  // sibling workspace untouched
    }

    func testWorkspaceStillNeverRelabeled() {
        // A workspace-id key is ignored even alongside an unassigned relabel.
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0),
                    unassignedSec(id: "unassigned:1", label: "Lost")]
        let out = applyLabelOverrides(secs,
            to: ["ws:0": "Nope", "unassigned:1": "Misc"])
        XCTAssertEqual(out[0].label, "Dev")                  // workspace ignored
        XCTAssertEqual(out[1].label, "Misc")                 // unassigned applied
        XCTAssertEqual(out[1].id, "unassigned:1")            // id frozen
    }

    // MARK: - a stored empty value blanks a lens header (caller never stores it)

    func testStoredEmptyValueBlanksLensHeader() {
        // Contract note: empty-value semantics are the CALLER's job (it DELETES
        // the key to revert). If a "" ever reaches here it maps verbatim — this
        // documents that boundary so the caller-side delete stays load-bearing.
        let secs = [lensSec(id: "section:0:Web", label: "Web")]
        let out = applyLabelOverrides(secs, to: ["section:0:Web": ""])
        XCTAssertEqual(out[0].label, "")
        XCTAssertEqual(out[0].id, "section:0:Web")
    }
}
