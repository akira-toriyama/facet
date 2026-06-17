// `lens` expressed as a `facet filter` — the read-only projection of the
// tag-mode visibility rule into the WHERE-clause language (pivot Phase 1,
// #284 PR#4).
//
// dwm-style tag mode shows/hides a window by a bitmask test: a window is
// visible when `window.tags & lens != 0`. The pivot folds facet's four
// ad-hoc matchers (grouping-mode / lens / search / role-float) into the
// single `facet filter` language, so the [[lens]] — "the currently-shown
// tag set" — must be expressible as a filter too. This file is that
// conversion, and it is PARITY-ONLY:
//
//   - The catalog's `UInt64` lens mask stays the AUTHORITATIVE hot-path
//     mechanism. `lensFilter` is dead-but-tested production code (no call
//     site yet — Phase 1's `FilterProjection` is the first consumer),
//     proven bit-for-bit equal to the bitmask in `LensFilterParityTests`.
//     A bug here therefore cannot mis-hide a window: the mask is canon.
//
// The mapping relies on the tag-mode invariant that every TRACKED window
// carries the `_default` floor bit, so a floor-only / `--all` lens shows
// everything:
//
//   - floor present (`lens & defaultBit != 0`)  →  `.all`
//       The lens intersects every window (all carry the floor), so it
//       shows everything. The floor-only lens is the empty-user-lens
//       show-all sentinel; an *untagged* window is spelled `not tag` in
//       the language, but the floor *lens* is show-all, hence `.all`.
//   - one user tag `A`                            →  `tag~=A s`
//   - several user tags `A`, `B`, …               →  `tag~=A s or tag~=B s …`
//       `~=` is whitespace-token containment — the natural test for the
//       list-valued `tag` field (a window's chip names are whitespace-
//       joined) — and the case-SENSITIVE ` s` flag makes it bit-exact:
//       tag bits are name-exact, and two vocabulary names may differ only
//       by case, so a case-insensitive `~=` could match a sibling bit and
//       break parity.
//   - empty (no floor, no defined user bits)      →  `.not(.all)` (matches
//       nothing). Unreachable for a real lens (`setLens` floor-guards 0,
//       and a lens only ever holds defined user bits); kept for totality
//       and to keep parity exact if a stray/undefined bit is ever passed.

public extension TagModel {
    /// The `facet filter` equivalent of a tag-mode `lens` mask under this
    /// vocabulary. Pure and total; see the file header for the mapping and
    /// the parity contract (the bitmask stays authoritative).
    func lensFilter(_ lens: UInt64) -> FacetFilter {
        // Floor bit ⇒ show-all: every tracked window carries it, so the
        // intersection is non-empty for all → `.all`.
        if lens & TagModel.defaultBit != 0 { return .all }
        // The user tags in the lens, in declaration order. A freed-hole or
        // undefined bit contributes no name here — and never intersects a
        // real window mask either (remove clears it from every window), so
        // dropping it preserves parity rather than breaking it.
        let atoms = names(in: lens).map { name in
            FacetFilter.atom(.init(
                field: "tag",
                kind: .compare(op: .contains, value: name, caseSensitive: true)))
        }
        switch atoms.count {
        case 0:  return .not(.all)   // matches nothing (unreachable lens)
        case 1:  return atoms[0]     // lone atom, not a 1-element `.or`
        default: return .or(atoms)
        }
    }
}
