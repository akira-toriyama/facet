import Testing
@testable import FacetCore

/// §E: `applyLabelOverrides` — the PURE display-label overlay at the heart of
/// the runtime section rename. Invariants under test: only `.matched` and
/// `.unassigned` sections are relabeled (§G; a workspace label comes from the
/// catalog); the section `id` is NEVER changed (identity stays stable for
/// `--focus index:N` + the active-lens highlight); an absent key leaves the
/// section untouched; a present key swaps only the `label`. Pure → headless
/// (no Xcode needed for the logic; `swift test` still needs XCTest on the box).
struct ApplyLabelOverridesTests {

    private func win(_ id: Int) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "App", title: "",
               isFocused: false, isFloating: false, frame: nil, tags: [])
    }

    private func isolateSec(id: String, label: String,
                         windows: [Window] = []) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: windows,
                         sourceWorkspaceIndex: nil, sectionType: .matched)
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

    @Test func emptyOverrideReturnsInputUnchanged() {
        let secs = [isolateSec(id: "section:0:Web", label: "Web"),
                    wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: [:])
        #expect(out == secs)
    }

    // MARK: - present key relabels a lens (display only, id frozen)

    @Test func presentKeyRelabelsMatchedKeepingID() {
        let secs = [isolateSec(id: "section:0:Web", label: "Web",
                            windows: [win(1), win(2)])]
        let out = applyLabelOverrides(secs, to: ["section:0:Web": "My Lens"])
        #expect(out.count == 1)
        #expect(out[0].id == "section:0:Web")          // id NEVER changes
        #expect(out[0].label == "My Lens")             // display swapped
        #expect(out[0].sectionType == .matched)
        #expect(out[0].sourceWorkspaceIndex == nil)
        #expect(out[0].windows.map(\.id.serverID) == [1, 2])  // windows intact
    }

    // MARK: - absent key leaves the section untouched

    @Test func absentKeyLeavesSectionUntouched() {
        let secs = [isolateSec(id: "section:0:Web", label: "Web"),
                    isolateSec(id: "section:1:Mail", label: "Mail")]
        let out = applyLabelOverrides(secs, to: ["section:9:Gone": "Stale"])
        #expect(out == secs)                            // orphan key = no-op
    }

    @Test func mixedSomeKeysPresentSomeAbsent() {
        let secs = [isolateSec(id: "section:0:Web", label: "Web"),
                    isolateSec(id: "section:1:Mail", label: "Mail")]
        let out = applyLabelOverrides(secs, to: ["section:1:Mail": "Inbox"])
        #expect(out[0].label == "Web")                 // untouched
        #expect(out[1].label == "Inbox")               // relabeled
        #expect(out[1].id == "section:1:Mail")         // id frozen
    }

    // MARK: - only non-workspace sections are relabeled (workspace label is catalog-owned)

    @Test func workspaceSectionIsNeverRelabeled() {
        // Even if a workspace-id key is (wrongly) present, it is ignored —
        // workspace labels come from the catalog (workspaceNames), not here.
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: ["ws:0": "ShouldNotApply"])
        #expect(out == secs)
        #expect(out[0].label == "Dev")
    }

    @Test func workspaceUntouchedWhileMatchedRelabeledInSameList() {
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0),
                    isolateSec(id: "section:1:Web", label: "Web")]
        let out = applyLabelOverrides(secs,
            to: ["ws:0": "Nope", "section:1:Web": "Browser"])
        #expect(out[0].label == "Dev")                 // workspace ignored
        #expect(out[1].label == "Browser")             // lens applied
    }

    // MARK: - §G: unassigned sections are relabeled (id frozen)

    @Test func presentKeyRelabelsUnassignedKeepingID() {
        let secs = [unassignedSec(id: "unassigned:2", label: "Lost",
                                  windows: [win(1)]),
                    isolateSec(id: "section:0:Web", label: "Web"),
                    wsSec(id: "ws:0", label: "Dev", src: 0)]
        let out = applyLabelOverrides(secs, to: ["unassigned:2": "その他"])
        #expect(out[0].id == "unassigned:2")            // id NEVER changes
        #expect(out[0].label == "その他")               // display swapped
        #expect(out[0].sectionType == .unassigned)
        #expect(out[0].windows.map(\.id.serverID) == [1])  // windows intact
        #expect(out[1].label == "Web")                  // sibling lens untouched
        #expect(out[2].label == "Dev")                  // sibling workspace untouched
    }

    @Test func workspaceStillNeverRelabeled() {
        // A workspace-id key is ignored even alongside an unassigned relabel.
        let secs = [wsSec(id: "ws:0", label: "Dev", src: 0),
                    unassignedSec(id: "unassigned:1", label: "Lost")]
        let out = applyLabelOverrides(secs,
            to: ["ws:0": "Nope", "unassigned:1": "Misc"])
        #expect(out[0].label == "Dev")                  // workspace ignored
        #expect(out[1].label == "Misc")                 // unassigned applied
        #expect(out[1].id == "unassigned:1")            // id frozen
    }

    // MARK: - a stored empty value blanks a lens header (caller never stores it)

    @Test func storedEmptyValueBlanksMatchedHeader() {
        // Contract note: empty-value semantics are the CALLER's job (it DELETES
        // the key to revert). If a "" ever reaches here it maps verbatim — this
        // documents that boundary so the caller-side delete stays load-bearing.
        let secs = [isolateSec(id: "section:0:Web", label: "Web")]
        let out = applyLabelOverrides(secs, to: ["section:0:Web": ""])
        #expect(out[0].label == "")
        #expect(out[0].id == "section:0:Web")
    }
}
