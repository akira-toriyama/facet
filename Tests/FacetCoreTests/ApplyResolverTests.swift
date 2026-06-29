import XCTest
@testable import FacetCore

/// `ApplyResolver` — the pure brain of the section apply/un-apply DnD (PR8):
/// section id → `DesktopSection` apply, the removeTag-only inverse, the
/// post-apply match invariant, and the MOVE / ADD `Plan`. Pure; CI-only (CLT
/// can't run `swift test`).
final class ApplyResolverTests: XCTestCase {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false,
                     sticky: Bool = false, master: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil,
               isMaster: master, isSticky: sticky, tags: tags)
    }

    private func wsSec() -> DesktopSection { DesktopSection(type: .workspace) }
    private func lens(_ label: String, _ match: String,
                      apply: [ApplyOp] = []) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match, apply: apply)
    }

    /// [0] workspace, [1] "Web" tag~=web → addTag(web), [2] "Code"
    /// tag~=code → addTag(code), [3] "Empty" app=X (no apply). A lens `apply`
    /// is tags-only (t-qtpx), so every fixture lens applies tags.
    private func sections() -> [DesktopSection] {
        [wsSec(),
         lens("Web", "tag~=web", apply: [.addTag("web")]),
         lens("Code", "tag~=code", apply: [.addTag("code")]),
         lens("Empty", "app=Nope")]
    }

    // MARK: - section(forSectionID:)

    func testSectionDecodesLensID() {
        let s = ApplyResolver.section(forSectionID: "section:1:Web", in: sections())
        XCTAssertEqual(s?.type, .lens)
        XCTAssertEqual(s?.label, "Web")
    }

    func testSectionNilForWorkspaceID() {
        // "ws:N" is handled by the caller via destWorkspaceIndex, not here.
        XCTAssertNil(ApplyResolver.section(forSectionID: "ws:0", in: sections()))
    }

    func testSectionNilForOutOfRangeDeclOrder() {
        XCTAssertNil(ApplyResolver.section(forSectionID: "section:9:Web", in: sections()))
    }

    func testSectionNilForTypeMismatch() {
        // declOrder 0 is the workspace section, not a lens → reject.
        XCTAssertNil(ApplyResolver.section(forSectionID: "section:0:", in: sections()))
    }

    func testSectionNilForLabelMismatch() {
        // Stale id: declOrder 1 is "Web", not "Stale" → reject (config moved).
        XCTAssertNil(ApplyResolver.section(forSectionID: "section:1:Stale", in: sections()))
    }

    func testSectionDecodesLabelContainingColon() {
        let secs = [wsSec(), lens("a:b:c", "app=X", apply: [.addTag("t")])]
        let s = ApplyResolver.section(forSectionID: "section:1:a:b:c", in: secs)
        XCTAssertEqual(s?.label, "a:b:c")   // split on the FIRST colon only
    }

    // MARK: - parseSectionID (A0: the shared id wire-format split)

    func testParseSectionIDSplitsDeclOrderAndLabel() {
        let parsed = ApplyResolver.parseSectionID("section:2:Web")
        XCTAssertEqual(parsed?.declOrder, 2)
        XCTAssertEqual(parsed?.label, "Web")
    }

    func testParseSectionIDKeepsColonInLabel() {
        // declOrder runs to the FIRST colon; the label is the remainder — so
        // `ActiveSection.lensLabel` and `section(forSectionID:)` share one split.
        let parsed = ApplyResolver.parseSectionID("section:0:a:b")
        XCTAssertEqual(parsed?.declOrder, 0)
        XCTAssertEqual(parsed?.label, "a:b")
    }

    func testParseSectionIDNilForNonSectionID() {
        XCTAssertNil(ApplyResolver.parseSectionID("ws:3"))          // workspace id
        XCTAssertNil(ApplyResolver.parseSectionID("Web"))           // no prefix
        XCTAssertNil(ApplyResolver.parseSectionID("section:x:Web")) // non-numeric declOrder
        XCTAssertNil(ApplyResolver.parseSectionID("section:5"))     // no label colon
    }

    // MARK: - inverse(of:)

    func testInverseIsRemoveTagOnly() {
        let fwd: [ApplyOp] = [
            .setWorkspace("Dev"), .addTag("a"), .addTag("b"),
            .setFloating(true), .setSticky(true), .setMaster(true),
        ]
        XCTAssertEqual(ApplyResolver.inverse(of: fwd),
                       [.removeTag("a"), .removeTag("b")])   // order preserved
    }

    func testInverseEmpty() {
        XCTAssertEqual(ApplyResolver.inverse(of: []), [])
        XCTAssertEqual(ApplyResolver.inverse(of: [.setFloating(true)]), [])
    }

    // MARK: - satisfiesAfterApply

    func testSatisfiesWorkspaceMatchEmptyIsTrue() {
        XCTAssertTrue(ApplyResolver.satisfiesAfterApply(
            win(1), workspaceName: "Dev", applying: [], match: ""))
    }

    func testSatisfiesTagAfterAddTag() {
        XCTAssertTrue(ApplyResolver.satisfiesAfterApply(
            win(1, app: "Chrome"), workspaceName: "Dev",
            applying: [.addTag("web")], match: "tag~=web"))
    }

    func testNotSatisfiesAppMatch() {
        // Adding a tag can't make Chrome's app become Safari → snap-back.
        XCTAssertFalse(ApplyResolver.satisfiesAfterApply(
            win(1, app: "Chrome"), workspaceName: "Dev",
            applying: [.addTag("s")], match: "app=Safari"))
    }

    func testSatisfiesFloatingAfterSetFloating() {
        XCTAssertTrue(ApplyResolver.satisfiesAfterApply(
            win(1, floating: false), workspaceName: "Dev",
            applying: [.setFloating(true)], match: "floating=true"))
        XCTAssertFalse(ApplyResolver.satisfiesAfterApply(
            win(1, floating: false), workspaceName: "Dev",
            applying: [], match: "floating=true"))
    }

    func testSatisfiesMalformedMatchIsFalse() {
        XCTAssertFalse(ApplyResolver.satisfiesAfterApply(
            win(1), workspaceName: "Dev", applying: [], match: "tag~="))
    }

    func testSatisfiesTagUnionDedup() {
        // Already has "web"; re-adding it still matches (union, no dup needed).
        XCTAssertTrue(ApplyResolver.satisfiesAfterApply(
            win(1, tags: ["web"]), workspaceName: "Dev",
            applying: [.addTag("web")], match: "tag~=web"))
    }

    // MARK: - plan() — MOVE / ADD / inert

    func testPlanLensToLensMove() {
        // Web (section:1) → Code (section:2): inverse removeTag(web),
        // forward addTag(code) (lens apply is tags-only), no relocation.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "section:2:Code",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [.removeTag("web")])
        XCTAssertEqual(p.forward, [.addTag("code")])
        XCTAssertNil(p.destWorkspaceIndex)
    }

    func testPlanLensToWorkspaceIsInert() {
        // t-qtpx: lens → workspace is a ws↔lens CROSSING — removed from DnD,
        // so it snaps back (cross-axis edits go via CLI / right-click).
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "ws:0",
            destWorkspaceIndex: 0, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanAddHasNoInverse() {
        // ADD (fromSectionID nil): apply only, no un-apply.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: nil, toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [])
        XCTAssertEqual(p.forward, [.addTag("web")])
    }

    func testPlanSameSectionIsInert() {
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanEmptyApplyLensIsInert() {
        // "Empty" (section:3) has no apply → drop-inert. Source is the "Web"
        // lens (same-type lens→lens, so the cross-type guard passes and the
        // empty-apply check is what makes it inert).
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "section:3:Empty",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanNonSatisfyingIsInert() {
        // A lens whose apply can't make the window match → snap-back. Source is
        // another lens (same-type lens→lens) so the satisfy invariant — not the
        // cross-type guard — is what rejects it.
        let secs = [wsSec(),
                    lens("Play", "tag~=play", apply: [.addTag("play")]),
                    lens("Safari", "app=Safari", apply: [.addTag("s")])]
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["play"]), workspaceName: "Dev",
            fromSectionID: "section:1:Play", toSectionID: "section:2:Safari",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert)
    }

    func testPlanStickyToWorkspaceIsInert() {
        // moveWindow rejects sticky windows → snap-back rather than no-op. A
        // ws→ws MOVE (same-type) reaches the sticky guard; a lens→ws would be
        // rejected earlier as cross-type.
        let p = ApplyResolver.plan(
            window: win(1, sticky: true), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "ws:1",
            destWorkspaceIndex: 1, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanStaleDestinationIsInert() {
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "section:9:Gone",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanWorkspaceToLensIsInert() {
        // t-qtpx: workspace → lens is a ws↔lens CROSSING — removed from DnD
        // (this was the EX-3 orphan-on-drop path), so it snaps back.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    // MARK: - convergence (plan forward → re-project → lands in dest)

    func testForwardApplyLandsWindowInDestLens() {
        let secs = sections()
        // ADD (right-click, fromSectionID nil) onto the Web lens — the
        // intentional multi-match path (a ws→lens MOVE is now cross-type-inert).
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: nil, toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: secs)
        // Simulate the backend applying the forward op (addTag("web")).
        var tags: [String] = []
        for op in p.forward { if case .addTag(let t) = op { tags.append(t) } }
        let after = win(1, app: "Chrome", tags: tags)
        let wss = [Workspace(index: 0, name: "Dev", isActive: true,
                             layoutMode: "float", windows: [after])]
        let proj = FilterProjection.project(workspaces: wss, sections: secs)
        let web = proj.sections.first { $0.label == "Web" }
        XCTAssertEqual(web?.windows.map(\.id), [after.id])   // now in the lens
    }

    // MARK: - net-effect invariant (un-apply removeTag runs BEFORE forward)

    func testSatisfiesSimulatesOpsInOrder() {
        // removeTag(web) then setSticky(true): match needs web → false.
        XCTAssertFalse(ApplyResolver.satisfiesAfterApply(
            win(1, tags: ["web"]), workspaceName: "Dev",
            applying: [.removeTag("web"), .setSticky(true)],
            match: "tag~=web and sticky=true"))
        // remove then re-add the same tag → present (order-correct).
        XCTAssertTrue(ApplyResolver.satisfiesAfterApply(
            win(1, tags: ["web"]), workspaceName: "Dev",
            applying: [.removeTag("web"), .addTag("web")], match: "tag~=web"))
    }

    func testPlanNetOverApproveIsInert() {
        // Source "Web" applies the very tag dest "Pinned" still needs; the
        // un-apply strips it, so the window would land in NEITHER lens →
        // inert (a forward-only check would wrongly let it proceed). Both
        // lenses are tags-only (t-qtpx).
        let secs = [wsSec(),
                    lens("Web", "tag~=web", apply: [.addTag("web")]),
                    lens("Pinned", "tag~=web and tag~=pinned",
                         apply: [.addTag("pinned")])]
        let p = ApplyResolver.plan(
            window: win(1, tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:1:Web", toSectionID: "section:2:Pinned",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert)
    }

    func testPlanNetUnderApproveAllowed() {
        // Dest "Work" match EXCLUDES the source "Play" tag; the un-apply
        // removes it FIRST, so the MOVE is valid — a forward-only check would
        // wrongly refuse it (see "play" still present).
        let secs = [wsSec(),
                    lens("Play", "tag~=play", apply: [.addTag("play")]),
                    lens("Work", "tag~=work and not tag~=play",
                         apply: [.addTag("work")])]
        let p = ApplyResolver.plan(
            window: win(1, tags: ["play"]), workspaceName: "Dev",
            fromSectionID: "section:1:Play", toSectionID: "section:2:Work",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertFalse(p.isInert)   // net = remove play, add work → satisfies
        XCTAssertEqual(p.inverse, [.removeTag("play")])
        XCTAssertEqual(p.forward, [.addTag("work")])
    }

    func testPlanStaleSourceIsInert() {
        // Source id no longer resolves (config hot-reloaded mid-drag): inert,
        // NOT a silent MOVE→ADD downgrade (matches stale-dest treatment).
        let p = ApplyResolver.plan(
            window: win(1, tags: ["web"]), workspaceName: "Dev",
            fromSectionID: "section:9:Gone", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    // MARK: - SAME-TYPE-ONLY DnD policy (t-qtpx) + §G rescue exception

    func testPlanWorkspaceToWorkspaceMove() {
        // ws→ws (same-type): a pure membership move via destWorkspaceIndex, no
        // inverse / forward.
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "ws:1",
            destWorkspaceIndex: 1, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [])
        XCTAssertEqual(p.forward, [])
        XCTAssertEqual(p.destWorkspaceIndex, 1)
    }

    func testPlanWorkspaceToLensIsCrossType() {
        // Re-stated for the policy section: ws→lens snaps back.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    /// §G RESCUE (the cross-type exception): a TRUE orphan (`workspaceName ==
    /// nil`) dragged OUT of the unassigned receptacle ONTO a workspace is filed
    /// there — moved via destWorkspaceIndex, no inverse, never inert.
    func testPlanUnassignedToWorkspaceRescue() {
        let secs = [wsSec(), wsSec(),
                    DesktopSection(type: .workspace, label: "Lost", unassigned: true)]
        let p = ApplyResolver.plan(
            window: win(9, app: "Chrome"), workspaceName: nil,
            fromSectionID: "unassigned:2", toSectionID: "ws:1",
            destWorkspaceIndex: 1, in: secs)
        XCTAssertFalse(p.isInert,
            "rescue from the unassigned receptacle onto a workspace is allowed")
        XCTAssertEqual(p.inverse, [], "the unassigned receptacle has no apply to reverse")
        XCTAssertEqual(p.destWorkspaceIndex, 1)
    }

    func testPlanUnassignedToLensIsInert() {
        // unassigned → lens is cross-type (only unassigned → workspace rescues).
        let secs = [wsSec(),
                    lens("Web", "tag~=web", apply: [.addTag("web")]),
                    DesktopSection(type: .workspace, label: "Lost", unassigned: true)]
        let p = ApplyResolver.plan(
            window: win(9, app: "Chrome"), workspaceName: nil,
            fromSectionID: "unassigned:2", toSectionID: "section:1:Web",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert)
    }

    func testPlanDropOntoUnassignedIsInert() {
        // Dropping a window BACK onto the unassigned receptacle is inert (a
        // passive lost-and-found, not an apply target) → snap-back. The
        // "unassigned:" dest never resolves to a lens, so it reads as stale.
        let secs = [wsSec(), DesktopSection(type: .workspace, label: "Lost", unassigned: true)]
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromSectionID: "ws:0", toSectionID: "unassigned:1",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert)
    }
}
