// `IsolatePark` — derive the anchor-park set for a lens board's active lens (t-c6fm).
//
// When a `type="lens"` board's lens is active (lens boards are focus boards — the
// park is inherent, no opt-in), the active workspace's windows that fall OUTSIDE
// the lens slide to the corner (anchor-park), so the screen shows only the active
// lens's world — the
// dwm-style focus トミー's original design (PR #313) delivered before t-0021
// removed it. This revives ONLY the park (never the union-tile that actually
// broke — the float-freeze), and it is DERIVED from `match` every reconcile
// (continuous re-park, no stored park-set to drift out of sync with the
// display): the caller feeds the active workspace's windows each cycle and this
// returns who should be parked, so park and the tree read the SAME predicate.
//
// The rule: park = OUT-OF-LENS and NOT sticky. A sticky (`everywhere`) window is
// "always visible" by definition, so it is exempt. A float has NO special
// handling — it parks by the same out-of-lens rule as a tiled window, so it
// follows its app's lens membership (an in-lens app's dialog stays; an
// out-of-lens app's dialog parks with its parent). Pure + backend-neutral
// (rides the single `LensMembership` predicate the display uses); CI-only.
import Foundation

public enum IsolatePark {
    /// The window ids to anchor-park for an isolate-active `lens`, given the
    /// active workspace's `windows` (their current tags overlaid) perceived in
    /// the workspace named `workspaceName`. Park = a window that does NOT satisfy
    /// `lens` AND is not in `sticky`. Order follows `windows`. Total — never
    /// throws; the caller executes the park + unparks the complement.
    public static func parkSet(windows: [Window],
                               inWorkspaceNamed workspaceName: String?,
                               lens: FacetFilter,
                               sticky: Set<WindowID>) -> [WindowID] {
        windows.compactMap { w in
            if sticky.contains(w.id) { return nil }
            if LensMembership.matches(w, inWorkspaceNamed: workspaceName, filter: lens) {
                return nil
            }
            return w.id
        }
    }
}
