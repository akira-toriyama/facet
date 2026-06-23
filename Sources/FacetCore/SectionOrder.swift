// Session-only display-order override for the pivot's section list.
//
// The tree / grid / rail all render `[[desktop.N.section]]` in
// config-declaration order (= `FilterProjection` output order). A user can
// drag a section to a new slot to REORDER the display; that reorder is
// SESSION-ONLY (the app never writes config.toml) and DISPLAY-ONLY (no
// window moves, no re-binding of a workspace's contents).
//
// CRITICAL — apply to the PROJECTED RESULT, never the input config array.
// `FilterProjection` binds workspace sections to live workspaces
// POSITIONALLY (k-th workspace section ↔ workspaces[k]), and lens-section
// ids embed the config `declOrder`. So permuting the INPUT `[DesktopSection]`
// would silently re-bind a different workspace's windows / emoji name into
// each slot and renumber lens ids — the exact "no content swap" violation.
// Permuting the OUTPUT (`[ProjectedSection]` / display `[Workspace]`) leaves
// `ws.index`, `sourceWorkspaceIndex`, frozen names and lens ids untouched;
// routing still resolves by `sourceWorkspaceIndex`, so windows stay put.
//
// The override is stored as an ordered list of stable section ids
// (`"ws:<index>"` / `"section:<declOrder>:<label>"`) per mac desktop on the
// Controller — never persisted. `apply` is a TOTAL stable-partition: ids
// present in the override come first in override order, the rest keep their
// projection order appended after. So a stale/partial override (a section
// added or removed mid-session) can never drop, duplicate, or invent a
// section — it degrades gracefully (newcomers land at the tail).

import Foundation

public enum SectionOrder {

    /// Reorder `sections` to honour a session-only `orderedIDs` override,
    /// keyed by `ProjectedSection.id`. `nil` / empty override → identity.
    public static func apply(_ orderedIDs: [String]?,
                             to sections: [ProjectedSection]) -> [ProjectedSection] {
        ordered(sections, by: orderedIDs, id: \.id)
    }

    /// Degrade-path analogue over `[Workspace]` (no section model active),
    /// keyed by `"ws:<index>"` so it shares the override's id vocabulary.
    public static func applyWorkspaces(_ orderedIDs: [String]?,
                                       to workspaces: [Workspace]) -> [Workspace] {
        ordered(workspaces, by: orderedIDs, id: { "ws:\($0.index)" })
    }

    /// The stable section id for a live workspace (the degrade-path key).
    /// Matches `FilterProjection`'s `"ws:<index>"` form.
    public static func workspaceID(_ index: Int) -> String { "ws:\(index)" }

    /// Compute the new full ordered id-list after moving `id` to insertion
    /// BOUNDARY `boundary`, measured in the CURRENT `currentIDs` coordinate
    /// space: `0` = before the first element, `currentIDs.count` = after the
    /// last, `k` = between elements `k-1` and `k`. Removing the moved element
    /// shifts a boundary that sat after it left by one (handled here so call
    /// sites pass the raw drop-band boundary). `id` absent or boundary out of
    /// range → clamped / identity. Pure; the Controller stores the result as
    /// the mac desktop's new override.
    public static func reorder(_ currentIDs: [String], move id: String,
                               toBoundary boundary: Int) -> [String] {
        guard let from = currentIDs.firstIndex(of: id) else { return currentIDs }
        var ids = currentIDs
        ids.remove(at: from)
        var insert = boundary
        if from < boundary { insert -= 1 }
        insert = max(0, min(insert, ids.count))
        ids.insert(id, at: insert)
        return ids
    }

    // MARK: - core

    /// Stable-partition: items whose `id` is in `orderedIDs` come first in
    /// override order; the rest keep their input order, appended after.
    /// Total — output is always a permutation of `items` (never drops /
    /// duplicates / invents). Ids are unique, so the rank sort is
    /// deterministic.
    private static func ordered<T>(_ items: [T], by orderedIDs: [String]?,
                                   id: (T) -> String) -> [T] {
        guard let orderedIDs, !orderedIDs.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (i, key) in orderedIDs.enumerated() where rank[key] == nil { rank[key] = i }
        let known = items.filter { rank[id($0)] != nil }
            .sorted { rank[id($0)]! < rank[id($1)]! }
        let unknown = items.filter { rank[id($0)] == nil }
        return known + unknown
    }
}
