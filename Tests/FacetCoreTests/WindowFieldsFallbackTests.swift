import Testing
@testable import FacetCore

/// The two projection `WindowFields` adapters that overlay extra context onto
/// a bare `Window` before a `FacetFilter` evaluates it:
///
/// - `ProjectedWindowFields` (FilterProjection / the section-lens park scan) —
///   adds the containing workspace NAME; everything else delegates to `Window`.
/// - `ApplyPlanWindowFields` (ApplyResolver) — replays an ordered `ApplyOp`
///   list onto the base window (tags + last-writer-wins floating/sticky/master
///   overlays) so the post-apply state is filtered, not the pre-apply one.
///
/// These tests pin the FALLBACK / coalescing branches (`?? base`, empty →
/// nil-vs-"" , unknown field → delegate) — including the deliberate asymmetry
/// where an empty workspace name reads back as `""` from the projection but
/// `nil` from the apply-plan. Pure; CI-only (CLT can't run `swift test`).
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
        // §B: ApplyPlanWindowFields now MIRRORS this (nil = orphan, "" =
        // assigned-unnamed), so the apply predictor and the tree agree.
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

    // MARK: - ApplyPlanWindowFields — empty / unknown fallbacks

    @Test func applyPlanWorkspacePresenceMirrorsProjection() {
        // §B: the apply-plan now matches ProjectedWindowFields — nil = orphan
        // (absent), "" = assigned-but-unnamed (present). Previously it coalesced
        // "" → nil, mispredicting a `not workspace` drop for an unnamed-WS window.
        let orphan = ApplyPlanWindowFields(base: win(1), workspaceName: nil, applying: [])
        #expect(orphan.filterValue("workspace") == nil)
        #expect(!orphan.filterHas("workspace"))         // orphan → absent

        let unnamed = ApplyPlanWindowFields(base: win(1), workspaceName: "", applying: [])
        #expect(unnamed.filterValue("workspace") == "")
        #expect(unnamed.filterHas("workspace"))         // assigned-unnamed → present
    }

    @Test func applyPlanEmptyTagsAreNil() {
        let f = ApplyPlanWindowFields(base: win(1, tags: []), workspaceName: "Dev",
                                      applying: [])
        #expect(f.filterValue("tag") == nil)
        #expect(!f.filterHas("tag"))
    }

    @Test func applyPlanDelegatesUnknownFieldToBase() {
        let f = ApplyPlanWindowFields(base: win(1, app: "Safari"),
                                      workspaceName: "Dev", applying: [])
        #expect(f.filterValue("app") == "Safari")          // → base
        #expect(f.filterHas("app"))
        #expect(f.filterValue("bogus") == nil)
        #expect(!f.filterHas("bogus"))
    }

    // MARK: - ApplyPlanWindowFields — overlay coalescing (`?? base`)

    @Test func applyPlanFloatingFallsBackToBaseWhenNoOp() {
        // No setFloating op → overlay is nil → reads the BASE value.
        let onBase = ApplyPlanWindowFields(base: win(1, floating: true),
                                           workspaceName: "Dev", applying: [])
        #expect(onBase.filterValue("floating") == "true")
        #expect(onBase.filterHas("floating"))
    }

    @Test func applyPlanFloatingOverlayWinsOverBase() {
        // setFloating(false) overrides a base that is floating=true.
        let overridden = ApplyPlanWindowFields(base: win(1, floating: true),
                                               workspaceName: "Dev",
                                               applying: [.setFloating(false)])
        #expect(overridden.filterValue("floating") == "false")
        #expect(!overridden.filterHas("floating"))
    }

    @Test func applyPlanStickyAndMasterCoalesce() {
        let base = win(1, sticky: true, master: false)
        let noOps = ApplyPlanWindowFields(base: base, workspaceName: "Dev",
                                          applying: [])
        #expect(noOps.filterHas("sticky"))                // base true
        #expect(!noOps.filterHas("master"))               // base false
        let setMa = ApplyPlanWindowFields(base: base, workspaceName: "Dev",
                                          applying: [.setMaster(true),
                                                     .setSticky(false)])
        #expect(setMa.filterValue("master") == "true")     // overlay
        #expect(setMa.filterValue("sticky") == "false")    // overlay
    }

    // MARK: - ApplyPlanWindowFields — ordered tag ops

    @Test func applyPlanTagOpsApplyInOrder() {
        // MOVE replay: removeTag(inverse) THEN addTag(forward) — a tag pulled
        // by the inverse and re-added by the forward resolves to PRESENT.
        let f = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                      workspaceName: "Dev",
                                      applying: [.removeTag("web"), .addTag("web")])
        #expect(f.filterValue("tag") == "web")
        #expect(f.filterHas("tag"))
    }

    @Test func applyPlanAddTagIsIdempotentAndRemoveClears() {
        let dup = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                        workspaceName: "Dev",
                                        applying: [.addTag("web")])
        #expect(dup.filterValue("tag") == "web")           // no duplicate
        let cleared = ApplyPlanWindowFields(base: win(1, tags: ["web"]),
                                            workspaceName: "Dev",
                                            applying: [.removeTag("web")])
        #expect(cleared.filterValue("tag") == nil)                // empty → nil
        #expect(!cleared.filterHas("tag"))
    }
}
