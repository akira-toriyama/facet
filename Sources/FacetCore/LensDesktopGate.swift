// The two-world gate (t-0sbm): what a lens desktop refuses, as pure data.
//
// Lives in FacetCore — not beside the dispatch it guards — for one reason:
// `FacetApp` is an executable target with no test harness, so a gate spread
// across its `switch` arms cannot be pinned. Here it is one function, and a
// test can enumerate the whole control vocabulary against it.

/// The verbs and views a **lens desktop** refuses.
///
/// A lens desktop is a FLAT, always-on, single-workspace desktop
/// (`effectiveWorkspaceList` seeds exactly one) whose membership is a live
/// `match`, not a set of windows the user owns. Two consequences:
///
/// - **Workspace-SET and active-workspace mutations** (add / remove / move /
///   rename / focus) have nothing to act on. `--add` actively BREAKS the N=1
///   invariant the anchor-park scope relies on: `workspace == activeIndex`
///   stops being desktop-wide the moment a 2nd workspace exists, and
///   non-matching windows escape the park.
/// - **The visual views** (grid / rail) have no fixed picture to thumbnail —
///   a lens desktop is TREE-ONLY.
///
/// Both reject LOUDLY rather than no-op silently: a lens desktop is valid
/// config, so the request is *unsatisfiable*, not a typo.
///
/// `workspace --layout` is gated for a subtler reason: the lens `layout` seam
/// re-asserts the declared layout whenever the mode NAME differs
/// (`applyIsolatePark` → `setMode` only on a name change), so a runtime
/// `--layout` would silently revert on the next reconcile. Reject it honestly.
///
/// **Tile REFINEMENT is deliberately NOT gated** — `--retile` / `--balance` /
/// `--rotate` / `--mirror` refine the tiled set WITHIN the same mode (the seam
/// never re-fires), so they take effect and persist exactly as on a workspace
/// desktop. (The t-0sbm review corrected an earlier "all refinement reverts"
/// premise.) Window verbs, scratchpad verbs, tags, `section --focus` and
/// `section --match` all work on a lens desktop too.
public enum LensDesktopGate {

    /// The user-facing verb a lens desktop refuses for this DNC control
    /// payload, or `nil` when the payload is allowed there.
    ///
    /// ⚠️ Allowed is the DEFAULT, so a NEW control payload passes unless it is
    /// classified here. `LensDesktopGateTests` walks the whole vocabulary —
    /// add the payload there when you add it to the dispatch.
    public static func blockedVerb(forControl payload: String) -> String? {
        switch payload {
        case "workspace-add":
            "workspace --add"
        case let p where p.hasPrefix("workspace:"):
            "workspace --focus"
        case let p where p.hasPrefix("workspace-remove:"):
            "workspace --remove"
        case let p where p.hasPrefix("workspace-rename:"):
            "workspace --rename"
        case let p where p.hasPrefix("workspace-move:"):
            "workspace --move"
        case let p where p.hasPrefix("set-layout:"):
            "workspace --layout"
        case let p where p.hasPrefix("section-rename:"):
            "section --rename"
        default:
            nil
        }
    }

    /// Whether this facet view is unrenderable on a lens desktop (tree only).
    public static func blocksView(_ name: String) -> Bool {
        name == "grid" || name == "rail"
    }
}
