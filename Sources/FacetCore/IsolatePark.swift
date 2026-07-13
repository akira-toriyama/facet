// `IsolatePark` — derive the anchor-park set for an isolate desktop's always-on
// `match` (t-c6fm machinery, t-0sbm gate).
//
// On a `[desktop.N] type="isolate"` mac desktop the park is inherent, no opt-in:
// the windows that fall OUTSIDE the `match` slide to the corner (anchor-park),
// so the screen shows only the matched set — the dwm-style focus トミー's
// original design (PR #313) delivered before t-0021 removed it. This revives
// ONLY the park (never the union-tile that actually broke — the float-freeze),
// and it is DERIVED from `match` every reconcile (continuous re-park, no stored
// park-set to drift out of sync with the display): the caller feeds the active
// workspace's windows each cycle and this returns who should be parked, so park
// and the tree read the SAME predicate.
//
// The rule: park = OUT-OF-MATCH and NOT sticky. A sticky (`everywhere`) window
// is "always visible" by definition, so it is exempt — which is exactly why the
// tree's non-matching bucket is called `holding` and not `parked` (t-mqqw): a
// sticky non-matching window is HELD in that section but never parked. A float
// has NO special handling — it parks by the same out-of-match rule as a tiled
// window, so it follows its app's membership (a matching app's dialog stays; a
// non-matching app's dialog parks with its parent). Pure + backend-neutral
// (rides the single `IsolateMembership` predicate the display uses); CI-only.
import Foundation

public enum IsolatePark {
    /// The window ids to anchor-park for an isolate desktop's `match`, given the
    /// active workspace's `windows` (their current tags overlaid) perceived in
    /// the workspace named `workspaceName`. Park = a window that does NOT satisfy
    /// `match` AND is not in `sticky`. Order follows `windows`. Total — never
    /// throws; the caller executes the park + unparks the complement.
    public static func parkSet(windows: [Window],
                               inWorkspaceNamed workspaceName: String?,
                               match: FacetFilter,
                               sticky: Set<WindowID>) -> [WindowID] {
        windows.compactMap { w in
            if sticky.contains(w.id) { return nil }
            if IsolateMembership.matches(w, inWorkspaceNamed: workspaceName, filter: match) {
                return nil
            }
            return w.id
        }
    }
}
