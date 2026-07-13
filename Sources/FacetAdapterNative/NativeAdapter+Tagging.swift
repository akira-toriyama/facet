// Window metadata commands — marks (focus marks) + runtime per-window
// tagging (#191 / #228). The legacy tag-mode lens/vocabulary (by=tag) was
// removed in EX-4; tagging is now a pure window attribute and visibility is
// owned by the section model (a `type="isolate"` section + reconcile).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
    public func markFocusedWindow(_ name: String) -> Bool {
        guard let id = focusedWindow() else {
            Log.debug("native: mark \"\(name)\" — no focused window")
            return false
        }
        catalog.setMark(name, to: id)
        Log.debug("native: mark \"\(name)\" -> \(id.serverID)")
        eventContinuation.yield(.refreshNeeded)   // repaint the badge
        return true
    }

    public func focusMark(_ name: String) -> Bool {
        guard let id = catalog.window(forMark: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: focus-mark \"\(name)\" — unset / gone")
            return false
        }
        // Cross-WS jump: switch first (un-parks + tiles the target WS,
        // suppressing default focus), then assert the marked window —
        // the same two-step the tree-click path uses. Same WS → assert
        // straight away.
        if slot.workspace != catalog.activeIndex {
            switchWorkspace(toIndex: slot.workspace - 1, autoFocus: false)
        }
        guard let win = enumerateCGWindows().first(where: { $0.id == id })
        else {
            Log.debug("native: focus-mark \"\(name)\" — window vanished")
            return false
        }
        Focus.assert(win, backend: self)
        Log.debug("native: focus-mark \"\(name)\" -> \(id.serverID) "
            + "WS \(slot.workspace)")
        return true
    }

    public func unmark(_ name: String) -> Bool {
        guard catalog.removeMark(name) else {
            Log.debug("native: unmark \"\(name)\" — no such mark")
            return false
        }
        Log.debug("native: unmark \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)   // repaint — badge gone
        return true
    }

    // MARK: - Runtime window tagging (#191 / #228)

    public func addTagToFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("tag", name, window: nil) {
            $0.addTagToWindow($1, name: name)
        }
    }

    public func removeTagFromFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("untag", name, window: nil) {
            $0.removeTagFromWindow($1, name: name)
        }
    }

    public func toggleTagOnFocusedWindow(_ name: String) -> Bool {
        applyWindowRetag("toggle-tag", name, window: nil) {
            $0.toggleTagOnWindow($1, name: name)
        }
    }

    // GUI tag menu (#191 PR-7) — retag a SPECIFIC window (the
    // right-clicked row), not the focused one. Same reconcile-driven
    // attribute write as the focused verbs, just with an explicit target.

    public func addTag(_ name: String, toWindow id: WindowID) -> Bool {
        applyWindowRetag("tag", name, window: id) {
            $0.addTagToWindow($1, name: name)
        }
    }

    public func removeTag(_ name: String, fromWindow id: WindowID) -> Bool {
        applyWindowRetag("untag", name, window: id) {
            $0.removeTagFromWindow($1, name: name)
        }
    }

    /// Shared body for the runtime-retag verbs. Guards the managed mac
    /// desktop, resolves the target window (`explicitID`, else the focused
    /// window), runs the catalog mutator (a pure attribute write), then
    /// re-tiles + requests a refresh. Returns `false` when there is no
    /// target window or the mutator rejected the name (e.g. `--untag` of an
    /// absent tag) so the Controller can surface the error.
    private func applyWindowRetag(
        _ verb: String, _ name: String, window explicitID: WindowID?,
        _ mutate: (inout WorkspaceCatalog, WindowID) -> Bool
    ) -> Bool {
        guard windowTagReady(verb, name) else { return false }
        guard let id = explicitID ?? focusedWindow() else {
            Log.debug("native: \(verb) \"\(name)\" — no focused window")
            return false
        }
        guard mutate(&catalog, id) else {
            Log.debug("native: \(verb) \"\(name)\" — rejected (no window / not present)")
            return false
        }
        settleWindowRetag(id, logDetail: "\(verb) \"\(name)\" -> \(id.serverID)")
        return true
    }

    /// Settle a single-window tag change. The tag set changed; re-tile +
    /// request a refresh. On an ISOLATE desktop the new tags may flip the
    /// window across its `match` (`tag~=X`), so the refresh re-derives the park
    /// set as well as the projection — display and screen move together. Shared
    /// by the `window --tag/--untag/--toggle-tag` verbs (`applyWindowRetag`)
    /// and `window --retag` (#228).
    private func settleWindowRetag(_ id: WindowID, logDetail: String) {
        applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
        Log.debug("native: \(logDetail)")
        eventContinuation.yield(.refreshNeeded)
    }

    /// `facet window --retag OLD NEW` (#228): replace tag OLD with NEW on
    /// the focused window in a SINGLE atomic catalog write, then re-tile.
    /// Maps the catalog's `RetagOutcome` to the backend-facing
    /// `WindowRetagResult` so the dispatch layer surfaces a precise error
    /// (no-focus vs. unknown-OLD vs. vocab-full).
    public func retagFocusedWindow(old: String,
                                   new: String) -> WindowRetagResult {
        guard windowTagReady("retag", "\(old):\(new)") else { return .noFocus }
        guard let id = focusedWindow() else {
            Log.debug("native: retag \"\(old)\"->\"\(new)\" — no focused window")
            return .noFocus
        }
        switch catalog.retagWindow(id, old: old, new: new) {
        case .retagged:
            settleWindowRetag(id,
                logDetail: "retag \"\(old)\"->\"\(new)\" -> \(id.serverID)")
            return .retagged
        case .noWindow:
            Log.debug("native: retag — focused window \(id.serverID) unmanaged")
            return .noFocus
        case .oldUndefined:
            Log.debug("native: retag \"\(old)\" — no such tag")
            return .oldUndefined
        case .vocabFull:
            Log.debug("native: retag -> \"\(new)\" — vocabulary full")
            return .vocabFull
        }
    }

    // MARK: - Tag-manage mode (`t`) — GLOBAL vocabulary edits

    /// Tag-manage `t` RENAME: replace tag `old` → `new` on EVERY window that
    /// carries it (vocabulary-wide, not a single window). Re-tiles + requests
    /// one refresh; an isolate desktop's `match` then re-evaluates membership by the
    /// new tags on the reconcile. `false` when unmanaged or no window carried
    /// `old`.
    public func renameTag(_ old: String, to new: String) -> Bool {
        guard windowTagReady("rename-tag", "\(old):\(new)") else { return false }
        guard catalog.renameTagEverywhere(old, to: new) else {
            Log.debug("native: rename-tag \"\(old)\"->\"\(new)\" — no window carried it")
            return false
        }
        applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
        Log.debug("native: rename-tag \"\(old)\"->\"\(new)\"")
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    /// Tag-manage `t` DELETE: remove tag `name` from EVERY window (the tag then
    /// ceases to exist). `false` when unmanaged or no window carried it.
    public func removeTag(_ name: String) -> Bool {
        guard windowTagReady("delete-tag", name) else { return false }
        guard catalog.removeTagEverywhere(name) else {
            Log.debug("native: delete-tag \"\(name)\" — no window carried it")
            return false
        }
        applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
        Log.debug("native: delete-tag \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    /// Managed-desktop gate shared by every runtime window-tag verb
    /// (`window --tag/--untag/--toggle-tag/--retag`). `false` (with a debug
    /// line) when this mac desktop is hands-off.
    private func windowTagReady(_ verb: String, _ name: String) -> Bool {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal) else {
            Log.debug("native: \(verb) \"\(name)\" — unmanaged mac desktop")
            return false
        }
        return true
    }
}
