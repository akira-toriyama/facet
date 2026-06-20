// `LensMembership` — the single source of truth for "does this window satisfy
// a lens `match`?". ONE predicate, shared by the tree display read-path
// (`FilterProjection`) and — from the tag-unification Phase 1 real-hide work
// (PR-2) — the anchor-park path that physically hides the windows a lens
// EXCLUDES within the current workspace. Routing every "is this window in the
// lens?" decision through here guarantees the tree and the physical park can
// never disagree about a lens's membership (display and hide stay in lock-step
// by construction; grid/rail then drop the parked windows via the snapshot's
// `Window.isLensParked` flag, so they ride the same park verdict too).
//
// A lens `match` is a `facet filter` WHERE-clause (`FacetFilter`) evaluated
// against each window with its workspace NAME overlaid: a bare `Window`
// resolves `workspace=` to a no-match (it doesn't carry its own workspace), so
// the caller passes the containing workspace's name and `ProjectedWindowFields`
// supplies it at the seam (`desktop=` stays a no-match — sections are already
// scoped per mac desktop by the `[[desktop.N.section]]` config). Pure +
// backend-neutral (FacetCore, no AppKit / no AX); unit-tested in
// `FacetCoreTests`.
//
// The CALLER owns parse + parse-failure POLICY — `FilterProjection` SKIPS a
// lens section whose `match` won't parse, the adapter's park scan DEGRADES to
// park-nothing — so this type is deliberately only the per-window membership
// decision against an ALREADY-COMPILED filter. That split also lets a match be
// parsed once and evaluated over many windows (the tree projection, and the
// active-workspace park scan, both do exactly that).

public enum LensMembership {
    /// Whether `window`, perceived in the workspace named `workspaceName`,
    /// satisfies the compiled lens `filter`. Pure + total: an unknown or
    /// absent field is a no-match, never a crash (see `FacetFilter.matches`).
    /// `workspaceName` is overlaid so a lens `match='workspace=Dev'` resolves;
    /// pass `""` when no workspace name applies (then `workspace=` no-matches).
    public static func matches(_ window: Window,
                               inWorkspaceNamed workspaceName: String,
                               filter: FacetFilter) -> Bool {
        filter.matches(ProjectedWindowFields(window: window,
                                             workspaceName: workspaceName))
    }
}
