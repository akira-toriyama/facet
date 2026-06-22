// Runtime per-window tagging (#191/#228) — the window-ATTRIBUTE mutators
// that back `facet window --tag/--untag/--toggle-tag/--retag`. The legacy
// tag-mode lens/park (by=tag) was removed in EX-4; visibility is now owned
// by the section model (a `type="lens"` section + reconcile), so these are
// pure attribute writes. Storage is still a UInt64 bitmask via `tagModel`
// (migrates to Set<String> in EX-4.3).
import CoreGraphics
import FacetCore

extension WorkspaceCatalog {
    /// Outcome of `retagWindow` — a precise reject for the dispatch layer.
    enum RetagOutcome: Equatable, Sendable {
        case retagged, noWindow, oldUndefined, vocabFull
    }

    /// Add `name` to the session vocabulary if absent, return its bit;
    /// nil when full (63) or reserved. Auto-vivify primitive.
    @discardableResult
    mutating func addTagName(_ name: String) -> UInt64? { tagModel.add(name) }

    /// `window --tag`: add `name` to window `id` (auto-vivify). Keeps the
    /// `_default` floor. Returns false when untracked / vocabulary full.
    @discardableResult
    mutating func addTagToWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id], let bit = addTagName(name) else { return false }
        slot.tags = slot.tags | bit | TagModel.defaultBit
        windowMap[id] = slot
        return true
    }

    /// `window --untag`: remove `name` from window `id`. Strict — false on an
    /// unknown / reserved name or an untracked window. Keeps the floor.
    @discardableResult
    mutating func removeTagFromWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id], name != TagModel.defaultName,
              let bit = tagModel.bit(for: name) else { return false }
        slot.tags = (slot.tags & ~bit) | TagModel.defaultBit
        windowMap[id] = slot
        return true
    }

    /// `window --toggle-tag`: flip `name` on window `id` (auto-vivify).
    @discardableResult
    mutating func toggleTagOnWindow(_ id: WindowID, name: String) -> Bool {
        guard var slot = windowMap[id], let bit = addTagName(name) else { return false }
        slot.tags = (slot.tags ^ bit) | TagModel.defaultBit
        windowMap[id] = slot
        return true
    }

    /// `window --retag OLD NEW` (#228): replace OLD with NEW in one write.
    /// `old` must be DEFINED (Strict-A); a window lacking it degrades to a
    /// bare add of `new`; `new` auto-vivifies (.vocabFull at the 63 cap).
    mutating func retagWindow(_ id: WindowID, old: String, new: String) -> RetagOutcome {
        guard var slot = windowMap[id] else { return .noWindow }
        guard let oldBit = tagModel.bit(for: old) else { return .oldUndefined }
        guard let newBit = addTagName(new) else { return .vocabFull }
        slot.tags = (slot.tags & ~oldBit) | newBit | TagModel.defaultBit
        windowMap[id] = slot
        return .retagged
    }
}
