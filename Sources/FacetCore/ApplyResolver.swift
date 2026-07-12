// `ApplyResolver` — the pure, backend-neutral validator for the section-model
// DnD MOVE (the tree's drag / kb-lift). Since the section-lens type was retired
// (t-ec9s), a MOVE is always a workspace MEMBERSHIP move:
//
//   • ws → ws     — file the window into the dest workspace (by 0-based index).
//   • §G RESCUE   — a TRUE orphan dragged OUT of the unassigned receptacle onto
//                   a workspace is filed there (the one cross-section case).
//
// The dest MUST be a workspace (a `"ws:<index>"` id). A drop onto the
// `unassigned` receptacle (or any non-workspace id) is INERT — the view snaps
// back WITHOUT any backend op. No tags, no `apply`: those left with section-lens.
//
// No AppKit / no backend / no I/O — unit-tested in `FacetCoreTests` (CLT can't
// run XCTest; CI covers it, the local bar is `swift build`).

import Foundation

public enum ApplyResolver {

    /// The executable plan for one MOVE. `destWorkspaceIndex` is the 0-based wire
    /// index of the workspace to file the window into. `isInert == true` ⇒ the
    /// caller snaps back WITHOUT any backend op; `reason` is the loud-but-non-
    /// fatal diagnostic to log.
    public struct Plan: Equatable, Sendable {
        /// 0-based wire workspace index for the move, else `nil` (inert).
        public let destWorkspaceIndex: Int?
        /// `true` ⇒ snap back, run NO backend op.
        public let isInert: Bool
        /// Diagnostic for the inert case (the caller logs it loud).
        public let reason: String?

        public init(destWorkspaceIndex: Int?, isInert: Bool, reason: String?) {
            self.destWorkspaceIndex = destWorkspaceIndex
            self.isInert = isInert
            self.reason = reason
        }
    }

    private static func inert(_ reason: String) -> Plan {
        Plan(destWorkspaceIndex: nil, isInert: true, reason: reason)
    }

    /// Resolve a MOVE — drop `window` from `fromSectionID` (nil for an ADD-style
    /// gesture) onto `toSectionID` — into an executable `Plan`.
    /// `destWorkspaceIndex` is the dest section's 0-based workspace index
    /// (supplied by the view seam; meaningful only for a workspace dest). Total —
    /// never throws; an inert / non-workspace drop returns `isInert == true` with
    /// a `reason`.
    public static func plan(window: Window,
                            fromSectionID: String?,
                            toSectionID: String,
                            destWorkspaceIndex: Int?) -> Plan {
        // Same section → nothing to do.
        if let fromSectionID, fromSectionID == toSectionID {
            return inert("same section")
        }
        // The dest must be a workspace (a `"ws:"` id). A drop onto the
        // `unassigned` receptacle (`"unassigned:"`) or anything else is inert —
        // membership only moves BETWEEN workspaces (or rescues an orphan INTO
        // one), never into a leftover-by-subtraction receptacle.
        guard toSectionID.hasPrefix("ws:") else {
            return inert("destination \"\(toSectionID)\" is not a workspace")
        }
        // A sticky window can't be filed into a workspace (the catalog's
        // moveWindow rejects it) — snap back rather than silently no-op.
        if window.isSticky {
            return inert("sticky window can't move to a workspace")
        }
        return Plan(destWorkspaceIndex: destWorkspaceIndex,
                    isInert: false, reason: nil)
    }
}
