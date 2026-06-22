// Runtime per-window tagging (#191/#228) — the window-ATTRIBUTE mutators
// that back `facet window --tag/--untag/--toggle-tag/--retag`. The legacy
// tag-mode lens/park (by=tag) was removed in EX-4; visibility is now owned
// by the section model (a `type="lens"` section + reconcile), so these are
// pure attribute writes. Storage is a free-form `Set<String>` per-window
// tag set (no vocabulary, no cap, no floor — EX-4.3).
import CoreGraphics
import FacetCore

extension WorkspaceCatalog {
    /// Outcome of `retagWindow` — a precise reject for the dispatch layer.
    enum RetagOutcome: Equatable, Sendable {
        case retagged, noWindow, oldUndefined, vocabFull
    }

    /// `facet window --tag`: add `name` to window `id`. Free-form (no
    /// vocabulary, no cap). Returns false only when `id` is untracked.
    @discardableResult
    mutating func addTagToWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id] else { return false }
        slot.tags.insert(name); windowMap[id] = slot; return true
    }

    /// `facet window --untag`: remove `name`. False when untracked or the
    /// window doesn't carry `name` (so the CLI surfaces "not present").
    @discardableResult
    mutating func removeTagFromWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id], slot.tags.contains(name) else { return false }
        slot.tags.remove(name); windowMap[id] = slot; return true
    }

    /// `facet window --toggle-tag`: flip `name` on window `id`.
    @discardableResult
    mutating func toggleTagOnWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id] else { return false }
        if slot.tags.contains(name) { slot.tags.remove(name) } else { slot.tags.insert(name) }
        windowMap[id] = slot; return true
    }

    /// `facet window --retag OLD NEW` (#228): replace OLD with NEW. A window
    /// lacking OLD just gains NEW (degrade-to-add). No vocabulary → the old
    /// `.oldUndefined`/`.vocabFull` outcomes can't occur.
    mutating func retagWindow(_ id: WindowID, old: String, new: String) -> RetagOutcome {
        guard var slot = windowMap[id] else { return .noWindow }
        slot.tags.remove(old); slot.tags.insert(new); windowMap[id] = slot
        return .retagged
    }
}
