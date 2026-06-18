// Section-model apply/un-apply DnD backend ops (PR8) — the ABSOLUTE,
// focus-free, by-`WindowID` mutators the tree's section-path drag /
// right-click / kb-lift drive through `ApplyOp`. Distinct from the
// user-gesture toggles (`perform(.toggleFloat/.toggleSticky)`,
// `addTag(_:toWindow:)`): those require the focused window and run tag-mode
// lens park/restore; these target an arbitrary managed window, are
// idempotent (set to an absolute value, never flip), and skip lens
// visibility (the section model is the by-workspace axis — visibility is
// workspace-driven, not lens-bitmask-driven).
//
// P6 (#259): every method asserts `dispatchPrecondition(.onQueue(cliQueue))`
// — the catalog is cliQueue-confined; the Controller dispatches these via
// `cliQueue.async` (`Controller+Apply`). They mutate the catalog, settle via
// the AX-only `reflowActive` (float/sticky/master change tiling) or just yield
// `.refreshNeeded` (a tag change re-projects, doesn't re-tile), and NEVER
// block main.

import CoreGraphics
import FacetCore
import Foundation

extension NativeAdapter {
    /// Gate the section-model mutators: the active mac desktop must be
    /// managed AND section-model-active. Mirrors `tagVocabReady`'s shape but
    /// for the by-workspace section axis (NOT `grouping == .tag`).
    private func sectionMutateReady() -> Bool {
        config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
            && config.isSectionModelActive(ordinal: activeMacDesktopOrdinal)
    }

    /// `setFloating` `ApplyOp` — float / tile `id` absolutely (focus-free).
    public func setFloating(_ id: WindowID, _ floating: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard sectionMutateReady() else { return }
        let rect = activeDisplayRect()
        if catalog.setFloating(id, floating, focused: id, in: rect) {
            reflowActive(rect: rect)          // AX-only; yields .refreshNeeded
        }
    }

    /// `setSticky` `ApplyOp` — pin / unpin `id` across every WS absolutely.
    public func setSticky(_ id: WindowID, _ sticky: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard sectionMutateReady() else { return }
        let rect = activeDisplayRect()
        if catalog.setSticky(id, sticky, focused: id, in: rect) {
            reflowActive(rect: rect)
        }
    }

    /// `setMaster` `ApplyOp` — promote / demote `id` as the layout master
    /// of its workspace (no-op for engines without a master slot).
    public func setMaster(_ id: WindowID, _ master: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard sectionMutateReady() else { return }
        guard let ws = catalog.windowMap[id]?.workspace else { return }
        let rect = activeDisplayRect()
        if catalog.setMaster(id, master, workspace: ws) {
            reflowActive(rect: rect)
        }
    }

    /// `addTag` `ApplyOp` — set the tag bit on `id` WITHOUT lens park/restore
    /// (the section model is the by-workspace axis; a tag is metadata for
    /// `match`, not a visibility selector here). Reuses the proven catalog
    /// mutator (auto-vivify, keep the `_default` floor) and ignores its
    /// returned lens-visibility transition. Returns false on unknown window /
    /// vocab-full.
    @discardableResult
    public func addTagSection(_ name: String, toWindow id: WindowID) -> Bool {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard sectionMutateReady() else { return false }
        guard catalog.addTagToWindow(id, name: name) != nil else { return false }
        eventContinuation.yield(.refreshNeeded)   // re-project; a tag doesn't tile
        return true
    }

    /// `removeTag` `ApplyOp` (un-apply only) — clear the tag bit on `id`
    /// WITHOUT lens park/restore. Strict (rejects unknown / reserved name).
    /// Returns false on unknown window / name.
    @discardableResult
    public func removeTagSection(_ name: String, fromWindow id: WindowID) -> Bool {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard sectionMutateReady() else { return false }
        guard catalog.removeTagFromWindow(id, name: name) != nil else { return false }
        eventContinuation.yield(.refreshNeeded)
        return true
    }
}
