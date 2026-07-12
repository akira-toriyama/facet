import Testing
@testable import FacetCore

/// `ProjectedWindowFields` (FilterProjection / the lens-membership scan) is the
/// projection `WindowFields` adapter that overlays extra context onto a bare
/// `Window` before a `FacetFilter` evaluates it: it adds the containing
/// workspace NAME; every other field delegates to `Window`.
///
/// These tests pin the FALLBACK / coalescing branches (`?? base`, empty →
/// nil-vs-"" , unknown field → delegate) — including the deliberate distinction
/// where an empty (assigned-but-unnamed) workspace name reads back as `""` and
/// is PRESENT, while a true orphan (`nil`) reads absent. Pure; CI-only (CLT
/// can't run `swift test`).
///
/// (The `ApplyPlanWindowFields` adapter and its ordered-`ApplyOp` replay were
/// removed with the section-lens / ApplyResolver collapse — t-ec9s Phase 6 —
/// so those fallback tests are gone.)
struct WindowFieldsFallbackTests {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false,
                     sticky: Bool = false, master: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil,
               isMaster: master, isSticky: sticky, tags: tags)
    }

    // MARK: - ProjectedWindowFields

    @Test func projectedWorkspaceOverlay() {
        let f = ProjectedWindowFields(window: win(1), workspaceName: "Dev")
        #expect(f.filterValue("workspace") == "Dev")
        #expect(f.filterHas("workspace"))
    }

    @Test func projectedEmptyWorkspaceReadsAsEmptyStringAndHasTrue() {
        // EX-3 迷子: presence is ASSIGNMENT-gated (`workspaceName != nil`), NOT
        // emptiness-gated. An assigned-but-UNNAMED workspace (name `""`) reads
        // its name back verbatim as `""` AND is PRESENT (`filterHas == true`),
        // so a `not workspace` lens does NOT catch it — only a true orphan
        // (`nil`) does. This is the deliberate nil-vs-`""` distinction (the
        // 迷子 receptacle keys off the ASSIGNMENT, never the display name).
        let f = ProjectedWindowFields(window: win(1), workspaceName: "")
        #expect(f.filterValue("workspace") == "")
        #expect(f.filterHas("workspace"))
    }

    @Test func projectedDelegatesNonWorkspaceFields() {
        let f = ProjectedWindowFields(window: win(1, app: "Safari", tags: ["web"]),
                                      workspaceName: "Dev")
        #expect(f.filterValue("app") == "Safari")          // → Window
        #expect(f.filterValue("tag") == "web")
        #expect(f.filterHas("tag"))
        #expect(f.filterValue("bogus") == nil)                    // unknown → nil
        #expect(!f.filterHas("bogus"))
    }
}
