import XCTest
@testable import FacetCore

/// t-0020: `applyMatchOverrides` — the PURE `match` overlay at the heart of the
/// runtime lens-match live edit. It is the seam-TWIN of `applyLabelOverrides`
/// with one crucial difference: it runs on the projection INPUT (`[DesktopSection]`),
/// BEFORE `FilterProjection.project()`, because changing a lens's `match` changes
/// which windows it catches. Invariants under test: only a `.lens` section that
/// is NOT an `unassigned` receptacle is overridable (a workspace is the exclusive
/// substrate, an unassigned section is leftover-by-subtraction); the override map
/// is keyed by the SAME stable id `project()` mints for a lens —
/// `"section:<declOrder>:<label>"`, with `declOrder` the enumerated position — so
/// a swapped `match` leaves the section's identity invariant (the id is built from
/// `label`, never `match`); an absent key is a no-op; the new predicate is stored
/// VERBATIM (no trim — predicates are whitespace-significant nowhere, but the
/// caller validated already and a stored value is the source of truth).
final class ApplyMatchOverridesTests: XCTestCase {

    // MARK: - fixtures (mirror FilterProjectionTests so the round-trip pins agree)

    private func win(_ id: Int, app: String = "App", tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil, tags: tags)
    }

    private func ws(_ index: Int, name: String, windows: [Window]) -> Workspace {
        Workspace(index: index, name: name, isActive: false,
                  layoutMode: "float", windows: windows)
    }

    private func wsSec(_ label: String = "") -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    // MARK: - empty override is a no-op (fast path)

    func testEmptyOverrideReturnsInputUnchanged() {
        let secs = [wsSec("Dev"), lens("Web", "tag~=web")]
        let out = applyMatchOverrides(secs, to: [:])
        XCTAssertEqual(out, secs)
    }

    // MARK: - present key swaps a lens's match, every other field intact

    func testPresentKeyReplacesLensMatchKeepingOtherFields() {
        let secs = [lens("Web", "tag~=web")]   // declOrder 0
        let out = applyMatchOverrides(secs, to: ["section:0:Web": "tag~=mail"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].match, "tag~=mail")       // match swapped
        XCTAssertEqual(out[0].type, .lens)              // type intact
        XCTAssertEqual(out[0].label, "Web")             // label intact (= identity)
        XCTAssertEqual(out[0].apply, [])                // apply intact
        XCTAssertEqual(out[0].layout, nil)              // layout intact
        XCTAssertEqual(out[0].unassigned, false)        // marker intact
    }

    // MARK: - absent / orphan key leaves the section untouched

    func testAbsentKeyLeavesSectionUntouched() {
        let secs = [lens("Web", "tag~=web"), lens("Mail", "tag~=mail")]
        let out = applyMatchOverrides(secs, to: ["section:9:Gone": "tag~=x"])
        XCTAssertEqual(out, secs)                        // orphan key = no-op
    }

    func testMixedSomeKeysPresentSomeAbsent() {
        let secs = [lens("Web", "tag~=web"), lens("Mail", "tag~=mail")]
        let out = applyMatchOverrides(secs, to: ["section:1:Mail": "tag~=inbox"])
        XCTAssertEqual(out[0].match, "tag~=web")         // untouched
        XCTAssertEqual(out[1].match, "tag~=inbox")       // overridden
        XCTAssertEqual(out[1].label, "Mail")             // identity frozen
    }

    // MARK: - only a pure lens is overridable

    func testWorkspaceSectionNeverOverridden() {
        // Even if a "section:<declOrder>:<label>"-shaped key (wrongly) collides
        // with a workspace's enumerated position, it is ignored — a workspace
        // has no match (it's the exclusive substrate).
        let secs = [wsSec("Dev")]                        // declOrder 0
        let out = applyMatchOverrides(secs, to: ["section:0:Dev": "tag~=x"])
        XCTAssertEqual(out, secs)
        XCTAssertEqual(out[0].match, "")
    }

    func testUnassignedReceptacleNeverOverridden() {
        // A lens-typed but `unassigned` marker section is the leftover
        // receptacle (project() emits it as `unassigned:<declOrder>`, not a
        // lens) — never match-overridable even by its section-shaped key.
        let recept = DesktopSection(type: .lens, label: "Lost",
                                    match: "tag~=x", unassigned: true)
        let secs = [recept]                              // declOrder 0
        let out = applyMatchOverrides(secs, to: ["section:0:Lost": "tag~=y"])
        XCTAssertEqual(out, secs)
        XCTAssertEqual(out[0].match, "tag~=x")
    }

    // MARK: - the predicate is stored VERBATIM (no trim, "" allowed)

    func testStoredValueIsVerbatim() {
        let secs = [lens("Web", "tag~=web")]
        let out = applyMatchOverrides(secs, to: ["section:0:Web": "  tag~=mail  "])
        XCTAssertEqual(out[0].match, "  tag~=mail  ")    // padding kept verbatim
    }

    func testStoredEmptyMatchIsVerbatim() {
        // Contract note: empty-value semantics are the CALLER's job (it DELETES
        // the key to revert to config). If a "" ever reaches here it maps
        // verbatim (an empty predicate parses to `.all` = match-everything) —
        // this documents that boundary so the caller-side delete stays
        // load-bearing.
        let secs = [lens("Web", "tag~=web")]
        let out = applyMatchOverrides(secs, to: ["section:0:Web": ""])
        XCTAssertEqual(out[0].match, "")
    }

    // MARK: - declOrder is the enumerated position (lens behind a workspace run)

    func testDeclOrderCountsEveryPrecedingSection() {
        // sections = [ws(0), lens(1) "Web", lens(2) "Mail"]; overriding the
        // SECOND lens must key on declOrder 2, not its lens-only ordinal.
        let secs = [wsSec("Dev"), lens("Web", "tag~=web"), lens("Mail", "tag~=mail")]
        let out = applyMatchOverrides(secs, to: ["section:2:Mail": "tag~=inbox"])
        XCTAssertEqual(out[0].type, .workspace)          // ws untouched
        XCTAssertEqual(out[1].match, "tag~=web")         // first lens untouched
        XCTAssertEqual(out[2].match, "tag~=inbox")       // second lens overridden
    }

    // MARK: - CRITICAL: the override key == the id project() mints (round-trip)

    func testOverrideKeyMatchesProjectMintedIDAndRefiltersWindows() {
        // The whole seam in one go: override a lens's match, project, and
        // confirm (a) the projected lens keeps the SAME id project() would have
        // minted, and (b) it now catches the NEW match's windows. If declOrder
        // or the label component diverged, the override key would miss and the
        // windows would be unchanged.
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["web"]),
                                                win(2, tags: ["mail"])])]
        let secs = [wsSec("Dev"),                        // declOrder 0
                    lens("Web", "tag~=web"),             // declOrder 1 → section:1:Web
                    lens("Mail", "tag~=mail")]           // declOrder 2 → section:2:Mail

        // Baseline: "Web" catches the web window, "Mail" the mail window.
        let base = FilterProjection.project(workspaces: wss, sections: secs)
        XCTAssertEqual(base.sections[1].id, "section:1:Web")
        XCTAssertEqual(base.sections[1].windows.map(\.id.serverID), [1])
        XCTAssertEqual(base.sections[2].windows.map(\.id.serverID), [2])

        // Override "Web" to catch the mail tag instead.
        let overridden = applyMatchOverrides(
            secs, to: ["section:1:Web": "tag~=mail"])
        let after = FilterProjection.project(workspaces: wss, sections: overridden)

        XCTAssertEqual(after.sections[1].id, "section:1:Web")   // identity frozen
        XCTAssertEqual(after.sections[1].label, "Web")          // display frozen
        XCTAssertEqual(after.sections[1].windows.map(\.id.serverID), [2])  // re-filtered
        XCTAssertEqual(after.sections[2].windows.map(\.id.serverID), [2])  // sibling unchanged
    }
}
