// `[[rule]]` adopt-rule — the declarative successor to the retired
// `[[assign]]` (#191), re-expressed in the shared `facet filter` language +
// the frozen `ApplyOp` vocabulary. Part of the filter-pivot epic (#282,
// Phase 3): when a NEW window matches `match`, the rule's facets are set on
// adoption. Global (not per-mac-desktop) — like its sibling top-level matcher
// `[[exclude]]`.
//
// Facets are authored as FLAT keys on the rule table (`workspace` / `tags` /
// `floating` / `sticky` / `master`) — the SAME vocabulary as a section's
// `apply`, decoded by the shared `ApplyOp.list`, but flat (like `[[exclude]]`)
// rather than a nested `apply = { … }`. The reason is schema fidelity: sill's
// `ConfigSchema` has no nested-object field kind, and a `[[rule]]` row is a
// strict object (`additionalProperties: false`), so flat keys let the schema
// validate every key (typo-catching) instead of waving a nested table through.

import Foundation

/// One `[[rule]]` adopt-rule: `match` (a `facet filter` WHERE-clause) selects
/// the new windows it adopts; `apply` is the frozen op set applied to each.
///
/// `match` is stored VERBATIM and compiled by the consumer at EVALUATION time
/// (loud + non-fatal on a malformed expression), so config-load stays total —
/// the same discipline a `type="isolate"` section's `match` follows.
public struct Rule: Sendable, Equatable {
    /// Raw `facet filter` WHERE-clause. Compiled by the consumer, not here.
    public let match: String
    /// Facets to set on a matching new window — the shared, frozen `ApplyOp`
    /// set (`ApplyOp.list` order: setWorkspace → addTag(s) → setFloating →
    /// setSticky → setMaster).
    public let apply: [ApplyOp]

    public init(match: String, apply: [ApplyOp]) {
        self.match = match
        self.apply = apply
    }
}
