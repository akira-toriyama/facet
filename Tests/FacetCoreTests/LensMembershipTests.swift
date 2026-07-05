import Testing
@testable import FacetCore

/// `LensMembership.matches` — the SINGLE per-window lens-`match` predicate.
/// A lens is a pure VIEW (t-0021): `FilterProjection` reads this to build the
/// tree/grid/rail display — there is no separate park path to keep in sync.
/// These lock the two behaviours the predicate must guarantee: (1) it agrees
/// with `FacetFilter.matches` for ordinary window fields, and (2) it overlays
/// the workspace NAME so `workspace=` resolves (a bare `Window` can't). Pure;
/// CI-only (CLT can't run `swift test`).
struct LensMembershipTests {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil, tags: tags)
    }

    /// Parse a filter or fail the test loudly (these are all hand-written
    /// valid expressions — a parse failure here is a test bug).
    private func filter(_ src: String,
                        file: StaticString = #filePath, line: UInt = #line) -> FacetFilter {
        switch FacetFilter.parse(src) {
        case .success(let f): return f
        case .failure(let e):
            Issue.record("unexpected parse failure for \(src): \(e.message)")
            return .all
        }
    }

    // MARK: - ordinary fields agree with FacetFilter.matches

    @Test func appFieldMatch() {
        let f = filter("app=Safari")
        #expect(LensMembership.matches(win(1, app: "Safari"),
                                       inWorkspaceNamed: "Dev", filter: f))
        #expect(!LensMembership.matches(win(2, app: "Mail"),
                                        inWorkspaceNamed: "Dev", filter: f))
    }

    @Test func tagContainsAndPresence() {
        let contains = filter("tag~=web")
        #expect(LensMembership.matches(win(1, tags: ["web", "work"]),
                                       inWorkspaceNamed: "Dev", filter: contains))
        #expect(!LensMembership.matches(win(2, tags: ["code"]),
                                        inWorkspaceNamed: "Dev", filter: contains))

        let untagged = filter("not tag")
        #expect(LensMembership.matches(win(3, tags: []),
                                       inWorkspaceNamed: "Dev", filter: untagged))
        #expect(!LensMembership.matches(win(4, tags: ["web"]),
                                        inWorkspaceNamed: "Dev", filter: untagged))
    }

    @Test func booleanAndCompoundFields() {
        let f = filter("app~=Chrome and not floating")
        #expect(LensMembership.matches(win(1, app: "Google Chrome", floating: false),
                                       inWorkspaceNamed: "Dev", filter: f))
        #expect(!LensMembership.matches(win(2, app: "Google Chrome", floating: true),
                                        inWorkspaceNamed: "Dev", filter: f))
        #expect(!LensMembership.matches(win(3, app: "Mail", floating: false),
                                        inWorkspaceNamed: "Dev", filter: f))
    }

    /// For any non-workspace filter, the shared predicate must give the exact
    /// same verdict as evaluating `FacetFilter.matches` on the bare `Window`
    /// — the overlay only adds `workspace`, it never alters other fields.
    @Test func agreesWithBareWindowForNonWorkspaceFields() {
        let f = filter("app=Safari or title*=Inbox")
        for w in [win(1, app: "Safari"), win(2, app: "Mail", title: "Inbox — Mail"),
                  win(3, app: "Mail", title: "Drafts")] {
            #expect(
                LensMembership.matches(w, inWorkspaceNamed: "Dev", filter: f)
                    == f.matches(w),
                "overlay changed a non-workspace verdict for window \(w.id.serverID)")
        }
    }

    // MARK: - workspace-name overlay (the reason the seam exists)

    @Test func workspaceFieldResolvesViaOverlay() {
        let f = filter("workspace=Dev")
        // Same window, two workspace names → opposite verdicts (proves the
        // name is supplied at the seam, not read off the window).
        let w = win(1, app: "Safari")
        #expect(LensMembership.matches(w, inWorkspaceNamed: "Dev", filter: f))
        #expect(!LensMembership.matches(w, inWorkspaceNamed: "Web", filter: f))
    }

    @Test func workspaceCombinedWithAppField() {
        let f = filter("workspace=Dev and app=Safari")
        #expect(LensMembership.matches(win(1, app: "Safari"),
                                       inWorkspaceNamed: "Dev", filter: f))
        #expect(!LensMembership.matches(win(2, app: "Safari"),
                                        inWorkspaceNamed: "Web", filter: f))
        #expect(!LensMembership.matches(win(3, app: "Mail"),
                                        inWorkspaceNamed: "Dev", filter: f))
    }

    @Test func emptyWorkspaceNameNoMatchesWorkspaceField() {
        let f = filter("workspace=Dev")
        #expect(!LensMembership.matches(win(1), inWorkspaceNamed: "", filter: f))
    }

    /// 迷子 receptacle (`match='not workspace'`): presence is the assignment,
    /// not the display name. An orphan (NO workspace → `inWorkspaceNamed: nil`)
    /// matches; an ASSIGNED window — even one in an UNNAMED workspace (name "")
    /// — does NOT. The predicate behind the receptacle; t-0021 made the lens a
    /// pure VIEW, so `FilterProjection` reads this same predicate for display
    /// (no separate adapter gather to keep in sync).
    @Test func notWorkspaceMatchesOrphanNotAssigned() {
        let f = filter("not workspace")
        #expect(LensMembership.matches(win(1), inWorkspaceNamed: nil, filter: f),
                "an orphan (no workspace) matches `not workspace`")
        #expect(!LensMembership.matches(win(2), inWorkspaceNamed: "", filter: f),
                "an unnamed-but-assigned window is NOT an orphan")
        #expect(!LensMembership.matches(win(3), inWorkspaceNamed: "Dev", filter: f),
                "a named-workspace window is NOT an orphan")
        #expect(
            LensMembership.matches(win(4, tags: ["web"]), inWorkspaceNamed: nil, filter: f),
            "a tagged orphan still has no workspace")
    }

    /// `not workspace=Dev` ("everything not in Dev") is a realistic lens whose
    /// interaction with the nil overlay is surprising: an ORPHAN
    /// (`inWorkspaceNamed: nil`) MATCHES, because the nil field makes the inner
    /// `workspace=Dev` compare short-circuit false and `not` flips it to true —
    /// while a window ACTUALLY in Dev is correctly excluded and one in another
    /// named workspace is included. Pins the nil-field/negation seam so a
    /// regression in the overlay's nil-handling or the compare nil-guard can't
    /// silently change which windows this common lens shows.
    @Test func negatedWorkspaceValueIncludesOrphan() {
        let f = filter("not workspace=Dev")
        #expect(LensMembership.matches(win(1), inWorkspaceNamed: nil, filter: f),
                "orphan: nil workspace field → inner compare false → not → true")
        #expect(!LensMembership.matches(win(2), inWorkspaceNamed: "Dev", filter: f),
                "a window in Dev is excluded by `not workspace=Dev`")
        #expect(LensMembership.matches(win(3), inWorkspaceNamed: "Web", filter: f),
                "a window in another named workspace matches `not workspace=Dev`")
    }

    /// The workspace-name overlay resolves case-INSENSITIVELY by default: a lens
    /// written `match='workspace=dev'` (lowercase) matches a window in a
    /// workspace named "Dev" because `op.equals` lowercases both sides. The
    /// case-sensitive flag (`s`) opts back into an exact-case compare, so the
    /// same lowercase literal then MISSES "Dev". Config authors routinely write
    /// a lens match in a different case than the live workspace name — pins that
    /// user-facing contract at the overlay.
    @Test func workspaceOverlayIsCaseInsensitiveByDefault() {
        let insensitive = filter("workspace=dev")
        #expect(LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: insensitive),
                "lowercase literal matches mixed-case workspace name")

        let sensitive = filter("workspace=dev s")
        #expect(!LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: sensitive),
                "case-sensitive flag makes the lowercase literal miss \"Dev\"")
    }

    /// `desktop=` stays a no-match even through the overlay (sections are
    /// already per-mac-desktop scoped, so the overlay deliberately doesn't
    /// resolve it).
    @Test func desktopFieldStaysNoMatch() {
        let f = filter("desktop=1")
        #expect(!LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: f))
    }

    // MARK: - total / edge

    @Test func allFilterMatchesEverything() {
        #expect(LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: .all))
    }

    @Test func unknownFieldNoMatches() {
        let f = filter("bogusField=x")
        #expect(!LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: f))
    }
}
