import Testing
@testable import FacetCore

/// `IsolateDesktopGate` — the two-world gate (t-0sbm): the verbs and views a lens
/// desktop refuses.
///
/// This suite exists because the gate USED to live as seven `if …Blocks(…)`
/// lines scattered through `Controller`'s DNC `switch` — and `FacetApp` is an
/// executable target with no test harness, so not one of them could be pinned.
/// The gate is now a pure `FacetCore` function with a single home; these tests
/// are the net under it.
///
/// The point of the ALLOWED half is not symmetry — it is that `retile` /
/// `balance` / `rotate` / `mirror` are deliberately NOT gated (they refine the
/// tiled set within the same layout mode, so they take effect and persist on a
/// isolate desktop exactly as on a workspace desktop). An over-eager future gate
/// that swept "everything workspace-shaped" would break that, silently.
struct IsolateDesktopGateTests {

    // MARK: - blocked

    @Test func blocksTheWorkspaceSetMutators() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-add")
                == "workspace --add")
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-remove:2")
                == "workspace --remove")
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-rename:Web")
                == "workspace --rename")
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-move:3")
                == "workspace --move")
    }

    /// `--remove` takes an OPTIONAL index, so its payload can be bare-suffixed.
    @Test func blocksWorkspaceRemoveWithNoIndex() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-remove:")
                == "workspace --remove")
    }

    @Test func blocksActiveWorkspaceFocus() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace:2")
                == "workspace --focus")
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace:next")
                == "workspace --focus")
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace:name:Web")
                == "workspace --focus")
    }

    /// Gated for a subtler reason than the rest: the lens `layout` seam
    /// re-asserts the declared layout on any mode-NAME change, so a runtime
    /// `--layout` would silently revert on the next reconcile.
    @Test func blocksWorkspaceLayout() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "set-layout:bsp")
                == "workspace --layout")
    }

    /// An isolate desktop's sections are match-synthesized, so there is no authored
    /// label to rename.
    @Test func blocksSectionRename() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "section-rename:1:Web")
                == "section --rename")
    }

    // MARK: - allowed (the half that is easy to break)

    /// Tile REFINEMENT stays live on an isolate desktop — it works within the same
    /// layout mode, so the lens seam never re-fires and the result persists.
    @Test func allowsTileRefinement() {
        for payload in ["retile", "workspace-balance",
                        "workspace-rotate:90", "workspace-mirror:x"] {
            #expect(IsolateDesktopGate.blockedVerb(forControl: payload) == nil,
                    "tile refinement must stay available: \(payload)")
        }
    }

    @Test func allowsWindowVerbs() {
        for payload in ["window-move:2", "window-move-follow:2",
                        "window-toggle-float", "window-toggle-sticky",
                        "window-toggle-orientation", "window-cycle-stack:next",
                        "window-focus-dir:left", "window-move-dir:right",
                        "window-grow-master", "window-shrink-master",
                        "window-inc-master", "window-dec-master",
                        "window-mark:a", "window-focus-mark:a", "window-unmark:a",
                        "window-tag:web", "window-untag:web",
                        "window-retag:web:work", "window-toggle-tag:web"] {
            #expect(IsolateDesktopGate.blockedVerb(forControl: payload) == nil,
                    "window verbs act on ONE window — always available: \(payload)")
        }
    }

    @Test func allowsScratchpadAndSectionAddressing() {
        for payload in ["scratchpad-stash:shelf", "scratchpad-toggle:shelf",
                        "scratchpad-release:shelf",
                        "section-focus:1", "section-focus:label:Web",
                        "section-match:1:app=Safari"] {
            #expect(IsolateDesktopGate.blockedVerb(forControl: payload) == nil,
                    "must stay available on an isolate desktop: \(payload)")
        }
    }

    /// The view payloads are NOT gated here — `dispatchView` / `dispatchToggle`
    /// route them through `blocksView` instead (the toggle path gates only the
    /// ON direction, so an overlay that travelled here stays closable).
    @Test func allowsTheControlPayloadsThatCarryViews() {
        for payload in ["view:grid", "view:rail", "view:tree+loading:300",
                        "hide:grid", "toggle:rail", "theme:dracula",
                        "quit", "reload"] {
            #expect(IsolateDesktopGate.blockedVerb(forControl: payload) == nil,
                    "view/lifecycle payloads are gated elsewhere: \(payload)")
        }
    }

    /// The gate defaults to ALLOWED, so an unclassified payload passes. This
    /// pins that fact rather than pretending otherwise — it is why the doc on
    /// `blockedVerb` says every new payload must be classified.
    @Test func unknownPayloadIsAllowed() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "not-a-real-verb") == nil)
        #expect(IsolateDesktopGate.blockedVerb(forControl: "") == nil)
    }

    /// A near-miss must not be swept up: `workspace-` mutators and the bare
    /// `workspace:` focus prefix are distinct payloads, and neither may shadow
    /// a window verb that merely starts with the same letters.
    @Test func prefixMatchingDoesNotOverreach() {
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspace-balance") == nil)
        #expect(IsolateDesktopGate.blockedVerb(forControl: "workspaces:2") == nil)
    }

    // MARK: - views (tree-only)

    @Test func blocksTheVisualViews() {
        #expect(IsolateDesktopGate.blocksView("grid"))
        #expect(IsolateDesktopGate.blocksView("rail"))
    }

    @Test func allowsTheTree() {
        #expect(!IsolateDesktopGate.blocksView("tree"))
    }
}
