import XCTest
@testable import FacetCore

/// `ApplyResolver` — the pure brain of the section apply/un-apply DnD (PR8):
/// group id → `DesktopSection` apply, the removeTag-only inverse, the
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

    /// [0] workspace, [1] "Web" tag~=web → addTag(web), [2] "Float"
    /// floating=true → setFloating(true), [3] "Empty" app=X (no apply).
    private func sections() -> [DesktopSection] {
        [wsSec(),
         lens("Web", "tag~=web", apply: [.addTag("web")]),
         lens("Float", "floating=true", apply: [.setFloating(true)]),
         lens("Empty", "app=Nope")]
    }

    // MARK: - section(forGroupID:)

    func testSectionDecodesLensID() {
        let s = ApplyResolver.section(forGroupID: "section:1:Web", in: sections())
        XCTAssertEqual(s?.type, .lens)
        XCTAssertEqual(s?.label, "Web")
    }

    func testSectionNilForWorkspaceID() {
        // "ws:N" is handled by the caller via destWorkspaceIndex, not here.
        XCTAssertNil(ApplyResolver.section(forGroupID: "ws:0", in: sections()))
    }

    func testSectionNilForOutOfRangeDeclOrder() {
        XCTAssertNil(ApplyResolver.section(forGroupID: "section:9:Web", in: sections()))
    }

    func testSectionNilForTypeMismatch() {
        // declOrder 0 is the workspace section, not a lens → reject.
        XCTAssertNil(ApplyResolver.section(forGroupID: "section:0:", in: sections()))
    }

    func testSectionNilForLabelMismatch() {
        // Stale id: declOrder 1 is "Web", not "Stale" → reject (config moved).
        XCTAssertNil(ApplyResolver.section(forGroupID: "section:1:Stale", in: sections()))
    }

    func testSectionDecodesLabelContainingColon() {
        let secs = [wsSec(), lens("a:b:c", "app=X", apply: [.addTag("t")])]
        let s = ApplyResolver.section(forGroupID: "section:1:a:b:c", in: secs)
        XCTAssertEqual(s?.label, "a:b:c")   // split on the FIRST colon only
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
        // Web (section:1) → Float (section:2): inverse removeTag(web),
        // forward setFloating(true), no workspace relocation.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromGroupID: "section:1:Web", toGroupID: "section:2:Float",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [.removeTag("web")])
        XCTAssertEqual(p.forward, [.setFloating(true)])
        XCTAssertNil(p.destWorkspaceIndex)
    }

    func testPlanLensToWorkspaceMove() {
        // Web → workspace ws:0: inverse removeTag(web), forward [], destWS 0.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome", tags: ["web"]), workspaceName: "Dev",
            fromGroupID: "section:1:Web", toGroupID: "ws:0",
            destWorkspaceIndex: 0, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [.removeTag("web")])
        XCTAssertEqual(p.forward, [])
        XCTAssertEqual(p.destWorkspaceIndex, 0)
    }

    func testPlanAddHasNoInverse() {
        // ADD (fromGroupID nil): apply only, no un-apply.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromGroupID: nil, toGroupID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertFalse(p.isInert)
        XCTAssertEqual(p.inverse, [])
        XCTAssertEqual(p.forward, [.addTag("web")])
    }

    func testPlanSameGroupIsInert() {
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromGroupID: "section:1:Web", toGroupID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanEmptyApplyLensIsInert() {
        // "Empty" (section:3) has no apply → drop-inert.
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromGroupID: "ws:0", toGroupID: "section:3:Empty",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanNonSatisfyingIsInert() {
        // A lens whose apply can't make the window match → snap-back.
        let secs = [wsSec(),
                    lens("Safari", "app=Safari", apply: [.addTag("s")])]
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromGroupID: "ws:0", toGroupID: "section:1:Safari",
            destWorkspaceIndex: nil, in: secs)
        XCTAssertTrue(p.isInert)
    }

    func testPlanStickyToWorkspaceIsInert() {
        // moveWindow rejects sticky windows → snap-back rather than no-op.
        let p = ApplyResolver.plan(
            window: win(1, sticky: true), workspaceName: "Dev",
            fromGroupID: "section:1:Web", toGroupID: "ws:0",
            destWorkspaceIndex: 0, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanStaleDestinationIsInert() {
        let p = ApplyResolver.plan(
            window: win(1), workspaceName: "Dev",
            fromGroupID: "ws:0", toGroupID: "section:9:Gone",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }

    func testPlanWorkspaceSourceHasNoInverse() {
        // Dragging OUT of a workspace section: no additive tag to reverse.
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromGroupID: "ws:0", toGroupID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertEqual(p.inverse, [])
        XCTAssertEqual(p.forward, [.addTag("web")])
    }

    // MARK: - convergence (plan forward → re-project → lands in dest)

    func testForwardApplyLandsWindowInDestLens() {
        let secs = sections()
        let p = ApplyResolver.plan(
            window: win(1, app: "Chrome"), workspaceName: "Dev",
            fromGroupID: "ws:0", toGroupID: "section:1:Web",
            destWorkspaceIndex: nil, in: secs)
        // Simulate the backend applying the forward op (addTag("web")).
        var tags: [String] = []
        for op in p.forward { if case .addTag(let t) = op { tags.append(t) } }
        let after = win(1, app: "Chrome", tags: tags)
        let wss = [Workspace(index: 0, name: "Dev", isActive: true,
                             layoutMode: "float", windows: [after])]
        let proj = FilterProjection.project(workspaces: wss, sections: secs)
        let web = proj.groups.first { $0.label == "Web" }
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
        // inert (a forward-only check would wrongly let it proceed).
        let secs = [wsSec(),
                    lens("Web", "tag~=web", apply: [.addTag("web")]),
                    lens("Pinned", "tag~=web and sticky=true",
                         apply: [.setSticky(true)])]
        let p = ApplyResolver.plan(
            window: win(1, tags: ["web"]), workspaceName: "Dev",
            fromGroupID: "section:1:Web", toGroupID: "section:2:Pinned",
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
            fromGroupID: "section:1:Play", toGroupID: "section:2:Work",
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
            fromGroupID: "section:9:Gone", toGroupID: "section:1:Web",
            destWorkspaceIndex: nil, in: sections())
        XCTAssertTrue(p.isInert)
    }
}
