// `IsolateMembership` — the single source of truth for "does this window satisfy
// an isolate desktop `match`?". ONE predicate for BOTH faces of an isolate desktop: the tree
// projection (`FilterProjection.projectIsolateDesktop`) shows the matched windows
// and the always-on anchor-park (`IsolatePark.parkSet`, applied by the adapter)
// removes the rest from the screen — sharing this predicate is what keeps what
// an isolate desktop SHOWS and what it PARKS from drifting apart.
//
// A lens `match` is a `facet filter` WHERE-clause (`FacetFilter`) evaluated
// against each window with its workspace NAME overlaid: a bare `Window`
// resolves `workspace=` to a no-match (it doesn't carry its own workspace), so
// the caller passes the containing workspace's name and `ProjectedWindowFields`
// supplies it at the seam (`desktop=` stays a no-match — an isolate desktop's
// `match` is already scoped to the mac desktop it is declared on). Pure +
// backend-neutral (FacetCore, no AppKit / no AX); unit-tested in
// `FacetCoreTests`.
//
// The CALLER owns parse + parse-failure POLICY — `FilterProjection` SKIPS a
// matched section whose `match` won't parse, the adapter's park scan DEGRADES to
// park-nothing — so this type is deliberately only the per-window membership
// decision against an ALREADY-COMPILED filter. That split also lets a match be
// parsed once and evaluated over many windows (the tree projection, and the
// active-workspace park scan, both do exactly that).

public enum IsolateMembership {
    /// Whether `window`, perceived in the workspace named `workspaceName`,
    /// satisfies the compiled lens `filter`. Pure + total: an unknown or
    /// absent field is a no-match, never a crash (see `FacetFilter.matches`).
    /// `workspaceName` is overlaid so an isolate desktop `match='workspace=Dev'` resolves.
    /// Pass `nil` when the window has NO workspace assignment (EX-3 迷子 /
    /// orphan) so `not workspace` matches it; pass the name (even `""` for an
    /// unnamed-but-assigned workspace) otherwise — `""` is assigned, so
    /// `not workspace` does NOT match it.
    public static func matches(_ window: Window,
                               inWorkspaceNamed workspaceName: String?,
                               filter: FacetFilter) -> Bool {
        filter.matches(ProjectedWindowFields(window: window,
                                             workspaceName: workspaceName))
    }
}
