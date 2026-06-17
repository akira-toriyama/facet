// `[[desktop.N.group]]` — the config-driven group definitions that drive
// the pivot's filter-projected views (PR#5; consumer lands in Phase 1
// PR#6's `FilterProjection`). PARSE-ONLY for now: this file defines the
// types and the TOML decode; nothing reads them yet.
//
// A group is the user's declarative answer to "how do I want my windows
// organised?" — it replaces the hard-coded `[desktop.N]` workspace list
// with `{ label, match, apply }`:
//
//   • `label`  — the group's display header in every view.
//   • `match`  — a `facet filter` WHERE-clause (see `FacetFilter`). A
//                window appears in the group when the filter matches it;
//                a window can match several groups (multi-match). Stored
//                VERBATIM as a string here and compiled by the consumer
//                (Phase 1 `FilterProjection`), so a malformed expression
//                is rejected loud + non-fatal at projection time, never
//                at config load (parse-only stays total).
//   • `apply`  — the inverse of `match`: the facets to SET on a window
//                dropped into (or otherwise routed to) this group, so a
//                drop "sticks" (the window then matches `match`). The
//                gesture-independent rename of the old `onDrop` — drop /
//                CLI / key all funnel through it. Consumed in Phase 2.
//
// FROZEN here so Phase 2's `apply` inversion resolver can rely on it:
//   - addTag is ADDITIVE by default (idempotent — re-adding is a no-op).
//   - setWorkspace is the single-valued special: a window has exactly one
//     workspace, so applying it AUTO-REPLACES the prior one.
//   - a group with no `apply` (or one that is wholly non-invertible) is
//     drop-INERT: a drop on it snaps back rather than mutating the window.

import Foundation

/// One facet to set on a window routed into a group — the typed `apply`
/// op. Deliberately a closed enum (not a raw dict) so Phase 2's inversion
/// resolver switches over a fixed, exhaustive set. Shared with `[[rule]]`
/// (Phase 3) which reuses the same vocabulary.
public enum ApplyOp: Sendable, Equatable {
    /// Add a tag (additive, idempotent). The string is a normalized tag
    /// name (`TagName.normalized`), so it is reachable from the CLI.
    case addTag(String)
    /// Force the window floating (`true`) or tiled (`false`).
    case setFloating(Bool)
    /// Pin the window across mac-desktop / workspace switches, or unpin.
    case setSticky(Bool)
    /// Mark/unmark as the layout master. Layout-derived in practice
    /// (`isMaster` is read from the resolved snapshot), so whether this is
    /// meaningfully invertible is settled in Phase 2; carried here for
    /// wire symmetry with the frozen op set.
    case setMaster(Bool)
    /// Move the window to a named workspace (single-valued → auto-replace).
    case setWorkspace(String)
}

public extension ApplyOp {
    /// Decode an `apply = { … }` inline table into a canonically-ordered
    /// op list. The order is FROZEN (Phase 2's inversion depends on a
    /// stable, deterministic sequence — a TOML inline table is unordered):
    ///
    ///   setWorkspace → addTag(s) → setFloating → setSticky → setMaster
    ///
    /// setWorkspace leads so a mixed `{ workspace = "Dev", tags = ["c"] }`
    /// moves the window first, then tags it (PR#9 example).
    ///
    /// Wire keys (all optional):
    ///   workspace = "Dev"        → setWorkspace
    ///   tags      = ["a", "b"]   → addTag per element, in array order
    ///                              (each normalized; invalid names dropped)
    ///   floating  = true|false   → setFloating
    ///   sticky    = true|false   → setSticky
    ///   master    = true|false   → setMaster
    ///
    /// A missing / non-table `apply` yields `[]` (drop-inert). Unknown
    /// keys are ignored — a typo can never break a sibling op.
    static func list(from value: TOMLValue?) -> [ApplyOp] {
        guard case .table(let t)? = value else { return [] }
        var ops: [ApplyOp] = []
        if case .string(let ws)? = t["workspace"], !ws.isEmpty {
            ops.append(.setWorkspace(ws))
        }
        if let tags = t["tags"]?.asStringArray {
            for raw in tags {
                if let name = TagName.normalized(raw) { ops.append(.addTag(name)) }
            }
        }
        if case .bool(let b)? = t["floating"] { ops.append(.setFloating(b)) }
        if case .bool(let b)? = t["sticky"]   { ops.append(.setSticky(b)) }
        if case .bool(let b)? = t["master"]   { ops.append(.setMaster(b)) }
        return ops
    }
}

/// One `[[desktop.N.group]]` table — a labelled window group defined by a
/// `facet filter` predicate plus the facets a drop applies. Order within a
/// mac desktop is config-declaration order (= display order).
public struct DesktopGroup: Sendable, Equatable {
    /// Display header. Required (a group with no name has nothing to show).
    public let label: String
    /// Raw `facet filter` WHERE-clause — compiled by the consumer, not
    /// here. Required + non-empty (an empty predicate matches nothing).
    public let match: String
    /// Facets to set on a window routed into this group. `[]` = drop-inert.
    public let apply: [ApplyOp]

    public init(label: String, match: String, apply: [ApplyOp] = []) {
        self.label = label
        self.match = match
        self.apply = apply
    }

    /// Build from one parsed `[[desktop.N.group]]` table row. Returns `nil`
    /// when `label` or `match` is missing / empty — a row that could never
    /// usefully render is dropped (mirrors the blank-`[[exclude]]` rule).
    public init?(fromTOMLRow t: [String: TOMLValue]) {
        guard case .string(let label)? = t["label"], !label.isEmpty,
              case .string(let match)? = t["match"], !match.isEmpty
        else { return nil }
        self.init(label: label, match: match, apply: ApplyOp.list(from: t["apply"]))
    }
}
