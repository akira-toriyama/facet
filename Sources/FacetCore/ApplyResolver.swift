// `ApplyResolver` — the pure, backend-neutral brain of the section
// apply/un-apply DnD (the pivot's MUTATING read-path, PR8). It wires a
// dropped / right-clicked `FilterGroup` (which carries NO apply ops — only
// its id, by the frozen `OverviewModels` contract) back to its authored
// `DesktopSection.apply`, produces the forward apply list + the removeTag-only
// inverse, and validates the CORE INVARIANT: a window must SATISFY the dest
// section's `match` after the forward apply, else the drop is INERT and the
// view snaps back WITHOUT any backend mutation.
//
// No AppKit / no backend / no I/O — unit-tested in `FacetCoreTests` (CLT can't
// run XCTest; CI covers it, the local bar is `swift build`). Shared with
// `[[rule]]` (Phase 3), which reuses the same `ApplyOp` vocabulary.
//
// GESTURES (model · トミー 2026-06-17):
//   • drag = MOVE: `un-apply(source) → apply(dest)`. The inverse reverses ONLY
//     `addTag` (→ `removeTag`); `setWorkspace` / `setFloating` / `setSticky` /
//     `setMaster` are single-valued (last-writer-wins) and are NEVER un-applied.
//   • right-click = ADD: `apply` only (no source, no inverse) → multi-match.
//
// WORKSPACE vs LENS dest:
//   • A `type=workspace` group id is `"ws:<index>"`. Its relocation is the
//     IMPLICIT `setWorkspace`, surfaced to the caller as `destWorkspaceIndex`
//     (the dest group's 0-based wire `sourceWorkspaceIndex`) so the caller
//     routes it through the unified `moveWindow(_:toWorkspaceIndex:)` path,
//     never an emoji NAME (auto-named workspaces collide on label by design).
//     A workspace `match` is `""` → the invariant is trivially satisfied.
//   • A `type=lens` group id is `"section:<declOrder>:<label>"`. Its `apply`
//     (with any authored `setWorkspace` STRIPPED — lenses don't relocate,
//     "lens は絞るだけ") is the forward list; an empty/wholly-stripped lens
//     apply is DROP-INERT (snap-back).

import Foundation

public enum ApplyResolver {

    /// The executable plan for one MOVE / ADD. `forward` never contains
    /// `setWorkspace` (a workspace dest surfaces it via `destWorkspaceIndex`;
    /// a lens dest drops it). `inverse` is `removeTag`-only. `isInert == true`
    /// ⇒ the caller snaps back WITHOUT any backend op; `reason` is the
    /// loud-but-non-fatal diagnostic to log.
    public struct Plan: Equatable, Sendable {
        /// Synthesised `removeTag(s)` undoing the SOURCE group's additive
        /// tags (MOVE only; empty for ADD and for a workspace source).
        public let inverse: [ApplyOp]
        /// The DEST section's apply, `setWorkspace` stripped (canonical order
        /// preserved): `addTag(s) → setFloating → setSticky → setMaster`.
        public let forward: [ApplyOp]
        /// 0-based wire workspace index for a workspace dest, else `nil`.
        public let destWorkspaceIndex: Int?
        /// `true` ⇒ snap back, run NO backend op.
        public let isInert: Bool
        /// Diagnostic for the inert case (the caller logs it loud).
        public let reason: String?

        public init(inverse: [ApplyOp], forward: [ApplyOp],
                    destWorkspaceIndex: Int?, isInert: Bool, reason: String?) {
            self.inverse = inverse
            self.forward = forward
            self.destWorkspaceIndex = destWorkspaceIndex
            self.isInert = isInert
            self.reason = reason
        }
    }

    private static func inert(_ reason: String) -> Plan {
        Plan(inverse: [], forward: [], destWorkspaceIndex: nil,
             isInert: true, reason: reason)
    }

    /// Resolve a rendered LENS group id (`"section:<declOrder>:<label>"`) back
    /// to its `DesktopSection`. `declOrder` is the index into the FULL
    /// `sections` array (`FilterProjection` enumerates the array verbatim), so
    /// it indexes back directly; the in-bounds + `type == .lens` + label-suffix
    /// guards reject a stale config (hot-reload between project and drop).
    /// Returns `nil` for a `"ws:<index>"` id (the caller handles workspace
    /// dests via `destWorkspaceIndex`) or any unrecognised / mismatched id.
    public static func section(forGroupID id: String,
                               in sections: [DesktopSection]) -> DesktopSection? {
        guard id.hasPrefix("section:") else { return nil }
        // "section:<declOrder>:<label>" — the label may contain ':', so take
        // the declOrder up to the FIRST colon and the label as the remainder.
        let body = id.dropFirst("section:".count)
        guard let colon = body.firstIndex(of: ":"),
              let declOrder = Int(body[..<colon]) else { return nil }
        let label = String(body[body.index(after: colon)...])
        guard declOrder >= 0, declOrder < sections.count else { return nil }
        let s = sections[declOrder]
        guard s.type == .lens, s.label == label else { return nil }
        return s
    }

    /// The `removeTag`-only inverse of a forward apply (decision 5: only
    /// `addTag` is reversible; `setWorkspace`/`setFloating`/`setSticky`/
    /// `setMaster` are single-valued last-writer-wins → dropped). Order kept.
    public static func inverse(of apply: [ApplyOp]) -> [ApplyOp] {
        apply.compactMap {
            if case .addTag(let t) = $0 { return .removeTag(t) }
            return nil
        }
    }

    /// Whether `window` WOULD satisfy `match` after `ops` are simulated on it,
    /// IN ORDER. `ops` is the NET runtime sequence — a MOVE's `inverse` THEN
    /// the dest `forward`, or just `forward` for an ADD — so a tag the inverse
    /// removes and the forward re-adds (or vice-versa) resolves to the real
    /// post-state. A workspace section's `match` is `""` → trivially `true`
    /// (verbatim membership, no eval). A malformed `match` → `false`
    /// (snap-back, loud). `workspaceName` is the window's CURRENT workspace
    /// name (a lens drop never relocates it).
    ///
    /// LIMITATION (`master`): the `setMaster` overlay is taken at face value,
    /// but the backend's `setMaster` is a no-op on engines without a master
    /// slot (bsp / float / grid / spiral). A pure resolver can't see the live
    /// layout engine, so a lens whose satisfaction hinges SOLELY on
    /// `master=true` may pass here yet not stick on such an engine (the next
    /// reconcile evicts it). Authoring a `master=` lens only makes sense on a
    /// master-* engine.
    public static func satisfiesAfterApply(_ window: Window,
                                           workspaceName: String,
                                           applying ops: [ApplyOp],
                                           match: String) -> Bool {
        if match.isEmpty { return true }
        guard case .success(let filter) = FacetFilter.parse(match) else { return false }
        return filter.matches(ApplyPlanWindowFields(
            base: window, workspaceName: workspaceName, applying: ops))
    }

    /// Resolve a MOVE (`fromGroupID != nil`) or ADD (`fromGroupID == nil`)
    /// into an executable `Plan`. `destWorkspaceIndex` is the dest group's
    /// `sourceWorkspaceIndex` (supplied by the view seam; meaningful only for
    /// a workspace dest). Total — never throws; an unresolvable / inert drop
    /// returns `isInert == true` with a `reason`.
    public static func plan(window: Window,
                            workspaceName: String,
                            fromGroupID: String?,
                            toGroupID: String,
                            destWorkspaceIndex: Int?,
                            in sections: [DesktopSection]) -> Plan {
        // Same group → nothing to do.
        if let fromGroupID, fromGroupID == toGroupID {
            return inert("same section")
        }

        // Inverse from the SOURCE section (MOVE only; ADD has no source, and a
        // workspace source has no additive tag to reverse). Computed FIRST so
        // the net-effect invariant below can reflect it. A stale source id
        // (config hot-reloaded between render and drop) → inert, matching the
        // stale-dest treatment, so a MOVE never silently degrades to an ADD.
        var inverse: [ApplyOp] = []
        if let fromGroupID, !fromGroupID.hasPrefix("ws:") {
            guard let src = section(forGroupID: fromGroupID, in: sections) else {
                return inert("stale source \"\(fromGroupID)\"")
            }
            inverse = ApplyResolver.inverse(of: src.apply)
        }

        let destIsWorkspace = toGroupID.hasPrefix("ws:")
        let destSection = destIsWorkspace ? nil : section(forGroupID: toGroupID, in: sections)
        if !destIsWorkspace && destSection == nil {
            return inert("stale destination \"\(toGroupID)\"")
        }

        // Forward = dest apply minus setWorkspace (a workspace dest relocates
        // via destWorkspaceIndex; a lens never relocates).
        let forward = (destSection?.apply ?? []).filter {
            if case .setWorkspace = $0 { return false }
            return true
        }

        if destIsWorkspace {
            // A sticky window can't be filed into a workspace (the catalog's
            // moveWindow rejects it) — snap back rather than silently no-op.
            if window.isSticky {
                return inert("sticky window can't move to a workspace")
            }
        } else {
            // Lens with no usable apply → drop-inert.
            if forward.isEmpty {
                return inert("lens \"\(destSection!.label)\" has no apply")
            }
            // Core invariant: the window must satisfy the lens match after the
            // FULL runtime sequence — `un-apply inverse → forward`, the order
            // `Controller.runApplyPlan` executes. The inverse runs FIRST and
            // can strip a tag the dest match NEEDS (→ window lands in neither
            // lens) or one it EXCLUDES (→ a valid move wrongly refused), so a
            // forward-only check mispredicts. Simulate the NET set, in order.
            // Snap back BEFORE any mutation.
            if !satisfiesAfterApply(window, workspaceName: workspaceName,
                                    applying: inverse + forward,
                                    match: destSection!.match) {
                return inert("window won't satisfy \"\(destSection!.label)\" after apply")
            }
        }

        return Plan(inverse: inverse, forward: forward,
                    destWorkspaceIndex: destIsWorkspace ? destWorkspaceIndex : nil,
                    isInert: false, reason: nil)
    }
}

/// Simulates a window's post-forward-apply field state for the match
/// invariant — overlays `addTag` / `setFloating` / `setSticky` / `setMaster`
/// (and the workspace name) onto a base `Window` WITHOUT mutating it. Mirrors
/// `ProjectedWindowFields`' workspace overlay; `addedTags` UNION the base tag
/// list so `tag~=` membership matches a freshly-applied tag. Internal (not
/// file-private) so `FacetCoreTests` can exercise it directly.
struct ApplyPlanWindowFields: WindowFields {
    let base: Window
    let workspaceName: String
    let tags: [String]     // base tags after applying the ordered op list
    let floating: Bool?
    let sticky: Bool?
    let master: Bool?

    /// `ops` is the NET runtime sequence — a MOVE's `inverse` (removeTag)
    /// THEN the dest `forward`, or just `forward` for an ADD — applied to the
    /// base window IN ORDER, so a tag removed by the inverse and re-added by
    /// the forward (or vice-versa) resolves to the real post-state.
    /// `setFloating` / `setSticky` / `setMaster` are last-writer-wins overlays.
    init(base: Window, workspaceName: String, applying ops: [ApplyOp]) {
        self.base = base
        self.workspaceName = workspaceName
        var tags = base.tags
        var fl: Bool?; var st: Bool?; var ma: Bool?
        for op in ops {
            switch op {
            case .addTag(let t):      if !tags.contains(t) { tags.append(t) }
            case .removeTag(let t):   tags.removeAll { $0 == t }
            case .setFloating(let b): fl = b
            case .setSticky(let b):   st = b
            case .setMaster(let b):   ma = b
            case .setWorkspace:       break   // relocation handled out-of-band
            }
        }
        self.tags = tags
        self.floating = fl
        self.sticky = st
        self.master = ma
    }

    func filterValue(_ field: String) -> String? {
        switch field {
        case "workspace": return workspaceName.isEmpty ? nil : workspaceName
        case "tag":       return tags.isEmpty ? nil : tags.joined(separator: " ")
        case "floating":  return (floating ?? base.isFloating) ? "true" : "false"
        case "sticky":    return (sticky ?? base.isSticky) ? "true" : "false"
        case "master":    return (master ?? base.isMaster) ? "true" : "false"
        default:          return base.filterValue(field)
        }
    }

    func filterHas(_ field: String) -> Bool {
        switch field {
        case "workspace": return !workspaceName.isEmpty
        case "tag":       return !tags.isEmpty
        case "floating":  return floating ?? base.isFloating
        case "sticky":    return sticky ?? base.isSticky
        case "master":    return master ?? base.isMaster
        default:          return base.filterHas(field)
        }
    }
}
