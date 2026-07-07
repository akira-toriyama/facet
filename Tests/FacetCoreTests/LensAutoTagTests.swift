import Testing
@testable import FacetCore

/// `LensAutoTag.tags` — the pure "which apply-tags should this window carry?"
/// helper (t-sw9p). A window gains the `apply` tags of EVERY `type="lens"`
/// section whose `match` it satisfies (multi-match, declaration order, deduped)
/// — independent of when/where it opened or which lens is "active". The adapter
/// calls this per window on reconcile and adds the result ADDITIVELY, which is
/// what finally tags pre-existing windows (previously only new windows opened
/// while a lens was active were tagged, via EX-3.3). Pure; CI-only.
struct LensAutoTagTests {

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: false, frame: nil, tags: tags)
    }

    private func lens(_ label: String, _ match: String, tags: [String]) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match,
                       apply: tags.map { ApplyOp.addTag($0) })
    }

    // MARK: - core: match → apply tags

    @Test func matchingLensAddsItsApplyTags() {
        let secs = [lens("Web", "app=Safari or app~=Chrome", tags: ["web", "foo"])]
        #expect(LensAutoTag.tags(for: win(1, app: "Safari"),
                                 inWorkspaceNamed: "Dev", lensSections: secs)
                == ["web", "foo"])
    }

    @Test func nonMatchingWindowGetsNoTags() {
        let secs = [lens("Web", "app=Safari or app~=Chrome", tags: ["web", "foo"])]
        #expect(LensAutoTag.tags(for: win(1, app: "Mail"),
                                 inWorkspaceNamed: "Dev", lensSections: secs)
                == [])
    }

    /// A window matching two lenses collects BOTH sets, in declaration order,
    /// with duplicates removed (a tag two lenses share appears once).
    @Test func multiMatchUnionsTagsDedupedInOrder() {
        let secs = [lens("Web", "app~=Chrome", tags: ["web", "shared"]),
                    lens("Dev", "app~=Chrome", tags: ["shared", "code"])]
        #expect(LensAutoTag.tags(for: win(1, app: "Google Chrome"),
                                 inWorkspaceNamed: "Dev", lensSections: secs)
                == ["web", "shared", "code"])
    }

    /// A pure-condition lens (`app=Safari`) with NO `apply` tags contributes
    /// nothing even though the window matches — there is nothing to add.
    @Test func pureConditionLensWithoutApplyContributesNothing() {
        let secs = [DesktopSection(type: .lens, label: "Web", match: "app=Safari")]
        #expect(LensAutoTag.tags(for: win(1, app: "Safari"),
                                 inWorkspaceNamed: "Dev", lensSections: secs)
                == [])
    }

    /// A `type="workspace"` section is never a lens — it is skipped even if the
    /// window would "match" (workspaces carry no match/apply).
    @Test func workspaceSectionIgnored() {
        let secs = [DesktopSection(type: .workspace, label: "Main")]
        #expect(LensAutoTag.tags(for: win(1, app: "Safari"),
                                 inWorkspaceNamed: "Main", lensSections: secs)
                == [])
    }

    /// A lens whose `match` won't parse is skipped (loud-but-non-fatal, mirroring
    /// `FilterProjection`) — it never crashes and never taints the result.
    @Test func malformedMatchSkipped() {
        let secs = [lens("Bad", "((", tags: ["nope"]),
                    lens("Web", "app=Safari", tags: ["web"])]
        #expect(LensAutoTag.tags(for: win(1, app: "Safari"),
                                 inWorkspaceNamed: "Dev", lensSections: secs)
                == ["web"])
    }

    /// The workspace-name overlay resolves `match='workspace=Dev'` at the seam —
    /// the same overlay `LensMembership` / `FilterProjection` use — so a
    /// workspace-scoped lens tags only windows in that workspace.
    @Test func workspaceNameOverlayResolves() {
        let secs = [lens("DevOnly", "workspace=Dev", tags: ["dev"])]
        #expect(LensAutoTag.tags(for: win(1), inWorkspaceNamed: "Dev", lensSections: secs)
                == ["dev"])
        #expect(LensAutoTag.tags(for: win(2), inWorkspaceNamed: "Web", lensSections: secs)
                == [])
    }
}
