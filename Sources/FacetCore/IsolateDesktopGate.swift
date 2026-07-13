// The two-world gate (t-0sbm): what an isolate desktop refuses, as pure data.
//
// Lives in FacetCore — not beside the dispatch it guards — for one reason:
// `FacetApp` is an executable target with no test harness, so a gate spread
// across its `switch` arms cannot be pinned. Here it is one function, and a
// test can enumerate the whole control vocabulary against it.

/// The verbs and views a **isolate desktop** refuses.
///
/// An isolate desktop is a FLAT, always-on, single-workspace desktop
/// (`effectiveWorkspaceList` seeds exactly one) whose membership is a live
/// `match`, not a set of windows the user owns. Two consequences:
///
/// - **Workspace-SET and active-workspace mutations** (add / remove / move /
///   rename / focus) have nothing to act on. `--add` actively BREAKS the N=1
///   invariant the anchor-park scope relies on: `workspace == activeIndex`
///   stops being desktop-wide the moment a 2nd workspace exists, and
///   non-matching windows escape the park.
/// - **The visual views** (grid / rail) have no fixed picture to thumbnail —
///   an isolate desktop is TREE-ONLY.
///
/// Both reject LOUDLY rather than no-op silently: an isolate desktop is valid
/// config, so the request is *unsatisfiable*, not a typo.
///
/// `workspace --layout` is gated for a subtler reason: the isolate desktop `layout` seam
/// re-asserts the declared layout whenever the mode NAME differs
/// (`applyIsolatePark` → `setMode` only on a name change), so a runtime
/// `--layout` would silently revert on the next reconcile. Reject it honestly.
///
/// **Tile REFINEMENT is deliberately NOT gated** — `--retile` / `--balance` /
/// `--rotate` / `--mirror` refine the tiled set WITHIN the same mode (the seam
/// never re-fires), so they take effect and persist exactly as on a workspace
/// desktop. (The t-0sbm review corrected an earlier "all refinement reverts"
/// premise.) Window verbs, scratchpad verbs, tags, `section --focus`,
/// `section --match` and `section --rename` all work on an isolate desktop too.
///
/// `section --rename` was gated until t-j7ps, and the gate was wrong twice over:
/// the GUI (tree header ▸ Section ▸ Rename) never went through the DNC, so it
/// walked straight past the gate — a CLI-first violation — and `--match` could
/// already retarget the desktop and persist, so refusing `--rename` left the
/// label LYING about what the desktop holds ("Web" over a set of editors). It now
/// renames `[desktop.N] label`, ordinal-keyed and snapshot-persisted, exactly
/// like `--match`. (The HOLDING section still refuses — it is synthesized by
/// subtraction and has no label to write anywhere — but that reject lives in
/// `renameSection`, where the section KIND is known; the gate only sees a DNC
/// payload string.)
public enum IsolateDesktopGate {

    /// The user-facing verb an isolate desktop refuses for this DNC control
    /// payload, or `nil` when the payload is allowed there.
    ///
    /// ⚠️ Allowed is the DEFAULT, so a NEW control payload passes unless it is
    /// classified here. `IsolateDesktopGateTests` walks the whole vocabulary —
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
        default:
            nil
        }
    }

    /// Whether this facet view is unrenderable on an isolate desktop (tree only).
    public static func blocksView(_ name: String) -> Bool {
        name == "grid" || name == "rail"
    }

    /// The two refusal messages live HERE, next to the predicates that raise
    /// them. `dispatchView` and `dispatchToggle` both refuse a view, and the
    /// message was written out verbatim in both — two copies of one sentence,
    /// free to drift. One home, like the gate itself.
    public static func viewRefusal(_ name: String) -> String {
        "\(name) view is not available on an isolate desktop (tree only)"
    }

    public static func verbRefusal(_ verb: String) -> String {
        "\(verb) is not available on an isolate desktop"
    }
}
