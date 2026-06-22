// Window metadata commands — marks (focus marks) + runtime window
// tagging and the runtime tag vocabulary (#191 / #228, tag mode).
// Extracted unchanged from NativeAdapter+DynamicWS.swift — same-module
// extension, no logic change.

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
        // The `!=` comparison is nil-safe (orphan's nil != activeIndex), but the
        // `ws - 1` arithmetic needs the value unwrapped. An orphan has no home
        // WS to switch to → can't focus-jump it (the mark is stored, but there's
        // nowhere to go); bail loud-but-non-fatal.
        if slot.workspace != catalog.activeIndex {
            guard let ws = slot.workspace else {
                Log.debug("native: focus-mark \"\(name)\" — orphan window, no workspace to switch to")
                return false
            }
            switchWorkspace(toIndex: ws - 1, autoFocus: false)
        }
        guard let win = enumerateCGWindows().first(where: { $0.id == id })
        else {
            Log.debug("native: focus-mark \"\(name)\" — window vanished")
            return false
        }
        Focus.assert(win, backend: self)
        Log.debug("native: focus-mark \"\(name)\" -> \(id.serverID) "
            + "WS \(slot.workspace.map(String.init) ?? "迷子")")
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

    // MARK: - Runtime window tagging (#191, tag mode)

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
    // right-clicked row), not the focused one. Same park/restore + retile
    // path as the focused verbs, just with an explicit target.

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

    /// Shared body for the runtime-retag verbs. Guards tag mode, resolves
    /// the target window (`explicitID`, else the focused window), runs the
    /// catalog mutator, then — like `setLens`, on a single window — parks /
    /// restores it if its lens visibility flipped and re-tiles the active
    /// union, finally repainting. Returns `false` when there is no target
    /// window or the mutator rejected the name (unknown on `untag` /
    /// vocabulary full) so the Controller can surface the error.
    private func applyWindowRetag(
        _ verb: String, _ name: String, window explicitID: WindowID?,
        _ mutate: (inout WorkspaceCatalog, WindowID)
            -> WorkspaceCatalog.RetagVisibility?
    ) -> Bool {
        guard tagVocabReady(verb, name) else { return false }
        guard let id = explicitID ?? focusedWindow() else {
            Log.debug("native: \(verb) \"\(name)\" — no focused window")
            return false
        }
        guard let vis = mutate(&catalog, id) else {
            Log.debug("native: \(verb) \"\(name)\" — rejected (unknown / full)")
            return false
        }
        settleWindowRetag(id, vis,
                          logDetail: "\(verb) \"\(name)\" -> \(id.serverID)")
        return true
    }

    /// Apply a single-window retag's lens-visibility transition — park /
    /// restore the one window if it flipped (like `setLens` on one
    /// window) — then re-tile the active union and repaint. Shared by the
    /// `window --tag/--untag/--toggle-tag` verbs (`applyWindowRetag`) and
    /// `window --retag` (#228). `logDetail` is the verb-specific debug
    /// suffix (the `[vis]` marker is appended here).
    private func settleWindowRetag(_ id: WindowID,
                                   _ vis: WorkspaceCatalog.RetagVisibility,
                                   logDetail: String) {
        if vis != .unchanged, let pid = catalog.windowMap[id]?.pid {
            let ref = WindowRef(id: id, pid: pid)
            applyHide(toPark: vis == .park ? [ref] : [],
                      toRestore: vis == .restore ? [ref] : [])
        }
        applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
        Log.debug("native: \(logDetail) [\(vis)]")
        eventContinuation.yield(.refreshNeeded)
    }

    /// `facet window --retag OLD NEW` (#228): replace tag OLD with NEW on
    /// the focused window in a SINGLE atomic catalog write, then settle
    /// its lens visibility + retile. Maps the catalog's `RetagOutcome` to
    /// the backend-facing `WindowRetagResult` so the dispatch layer
    /// surfaces a precise error (no-focus vs. unknown-OLD vs. vocab-full).
    public func retagFocusedWindow(old: String,
                                   new: String) -> WindowRetagResult {
        guard tagVocabReady("retag", "\(old):\(new)") else { return .noFocus }
        guard let id = focusedWindow() else {
            Log.debug("native: retag \"\(old)\"->\"\(new)\" — no focused window")
            return .noFocus
        }
        switch catalog.retagWindow(id, old: old, new: new) {
        case .retagged(let vis):
            settleWindowRetag(id, vis,
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

    /// Tag-mode + managed-desktop gate shared by every runtime tag verb
    /// (`window --tag/--untag/--toggle-tag` and `tag --add/--remove/
    /// --rename`). `false` (with a debug line) when the run isn't in tag
    /// mode or this mac desktop is hands-off.
    private func tagVocabReady(_ verb: String, _ name: String) -> Bool {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal),
              catalog.grouping == .tag else {
            Log.debug("native: \(verb) \"\(name)\" — not tag mode / unmanaged")
            return false
        }
        return true
    }

    // MARK: - Runtime tag vocabulary (#191, tag mode — `facet tag`)

    /// `facet tag --add NAME`: declare a tag in the session vocabulary
    /// without touching any window. Idempotent (a defined name is a
    /// no-op success). `false` only when not in tag mode / unmanaged or
    /// the vocabulary is full (63 user tags).
    public func addTag(_ name: String) -> Bool {
        guard tagVocabReady("tag --add", name) else { return false }
        guard catalog.addTagName(name) != nil else {
            Log.debug("native: tag --add \"\(name)\" — rejected (full / reserved)")
            return false
        }
        Log.debug("native: tag --add \"\(name)\"")
        // No window changed and the flat tree only lists windows (a tag
        // with no window has no row), so the repaint is a no-op for the
        // tree today — kept so any future vocabulary-aware surface (lens
        // picker, etc.) refreshes on a new tag.
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    /// `facet tag --remove NAME`: delete a tag, stripping its bit from
    /// every window and freeing it for reuse. Parks / restores windows
    /// whose lens visibility flipped and re-tiles the union — the
    /// vocabulary analog of `setLens`. `false` when not in tag mode /
    /// unmanaged or `name` is unknown / reserved.
    public func removeTag(_ name: String) -> Bool {
        guard tagVocabReady("tag --remove", name) else { return false }
        guard let plan = catalog.removeTagName(name) else {
            Log.debug("native: tag --remove \"\(name)\" — rejected (unknown / reserved)")
            return false
        }
        let rect = activeDisplayRect()
        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        applyLensAutoFocus(newLens: plan.newLens)
        Log.debug("native: tag --remove \"\(name)\" "
            + "parked=\(plan.toPark.count) restored=\(plan.toRestore.count)")
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    /// `facet tag --rename OLD NEW`: rename a tag in place (bit kept, so
    /// no window mask / lens edit). `false` when not in tag mode /
    /// unmanaged, `old` is unknown, or `new` is already defined.
    public func renameTag(_ old: String, to new: String) -> Bool {
        guard tagVocabReady("tag --rename", "\(old):\(new)") else {
            return false
        }
        switch catalog.renameTagName(old, to: new) {
        case .renamed:
            Log.debug("native: tag --rename \"\(old)\" -> \"\(new)\"")
            eventContinuation.yield(.refreshNeeded)
            return true
        case .unknownOld:
            Log.debug("native: tag --rename \"\(old)\" — no such tag")
            return false
        case .collision:
            Log.debug("native: tag --rename -> \"\(new)\" — name already in use")
            return false
        }
    }
}
