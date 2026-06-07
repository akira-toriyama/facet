// Tag model (M11-3) — pure, backend-neutral, unit-testable.
//
// In `[grouping] by = "tag"` mode a window carries a SET of tags
// instead of a single workspace. Visibility is dwm's `tags & viewmask`:
// a window shows when its tag bits intersect the current `lens`. This
// file holds the pure pieces:
//
//   - `TagModel`: the ordered tag vocabulary (config `[[tag]]` order)
//     and the name ⇄ bit mapping. Declaration order is load-bearing —
//     it drives tree/rail header order and the "primary tag" (the
//     lowest-order tag a window holds, where it appears once in the
//     tree).
//   - `AssignRule` / `AssignRules`: config `[[assign]]` — match a
//     window (shared `WindowMatcher`) and give it tags. A window
//     matching several rules gets the UNION (multi-membership). A
//     window matching none inherits at runtime (the catalog's job).
//
// Tags are STATIC: defined in config, frozen at window appearance, no
// runtime re-tag. That's what keeps the model cheap (no reconcile has
// to learn tag changes).

/// The ordered tag vocabulary plus name ⇄ bit mapping. Bit `i` is tag
/// `names[i]`; up to 64 tags (a `UInt64` mask, dwm caps at 31). Names
/// past 64 are dropped at construction.
public struct TagModel: Sendable, Equatable {
    /// Tag names in `[[tag]]` declaration order. Index = bit position.
    public let names: [String]

    public init(_ names: [String]) {
        self.names = Array(names.prefix(64))
    }

    public var isEmpty: Bool { names.isEmpty }
    public var count: Int { names.count }

    /// The single bit for a tag name (by declaration order), or `nil`
    /// when the name isn't in the vocabulary.
    public func bit(for name: String) -> UInt64? {
        guard let i = names.firstIndex(of: name) else { return nil }
        return UInt64(1) << UInt64(i)
    }

    /// Bitmask for a list of names; unknown names are ignored (a typo
    /// loses just that one tag, never crashes — TOML-parser stance).
    public func mask(for tagNames: [String]) -> UInt64 {
        tagNames.reduce(0) { $0 | (bit(for: $1) ?? 0) }
    }

    /// Mask with every defined tag set — `lens --all`. Empty model → 0.
    public var allMask: UInt64 {
        guard count > 0 else { return 0 }
        return count >= 64 ? .max : (UInt64(1) << UInt64(count)) - 1
    }

    /// The first tag (declaration order) — the startup lens default
    /// and the single bit for it. `nil` when no tags are defined.
    public var firstBit: UInt64? {
        names.isEmpty ? nil : 1
    }

    /// Primary tag of a mask = the lowest set bit's name (declaration
    /// order). This is where a multi-tag window appears once in the
    /// tree. `nil` when the mask is empty or out of range.
    public func primaryName(of mask: UInt64) -> String? {
        guard mask != 0 else { return nil }
        let i = mask.trailingZeroBitCount
        return i < names.count ? names[i] : nil
    }

    /// The names present in a mask, in declaration order — the badge
    /// set for a window (primary first).
    public func names(in mask: UInt64) -> [String] {
        names.enumerated().compactMap { (i, name) in
            (mask & (UInt64(1) << UInt64(i))) != 0 ? name : nil
        }
    }
}

/// One `[[assign]]` table: a `WindowMatcher` plus the tag names to
/// give a window it matches. A rule with no constraints or no tags is
/// inert (dropped by the parser).
public struct AssignRule: Sendable, Equatable {
    public let matcher: WindowMatcher
    /// Tag names this rule assigns (resolved to bits against a
    /// `TagModel` later — kept as names so the rule is independent of
    /// the vocabulary's bit layout).
    public let tags: [String]

    public init(matcher: WindowMatcher, tags: [String]) {
        self.matcher = matcher
        self.tags = tags
    }

    public func matches(_ p: WindowProbe) -> Bool { matcher.matches(p) }
    public var needsAXRole: Bool { matcher.needsAXRole }
}

/// Ordered `[[assign]]` set. Unlike `[[exclude]]` (first-match-wins),
/// assignment UNIONS every matching rule's tags — a window can land in
/// several tags from several rules (multi-membership).
public struct AssignRules: Sendable, Equatable {
    public let rules: [AssignRule]
    public init(_ rules: [AssignRule] = []) { self.rules = rules }

    public var isEmpty: Bool { rules.isEmpty }
    public var anyNeedsAXRole: Bool { rules.contains(where: \.needsAXRole) }

    /// Union of tag names from ALL rules that match `p`, de-duplicated,
    /// in first-seen order. Empty when no rule matches (the window is
    /// then "unassigned" — the catalog gives it the lens's primary tag
    /// at appearance).
    public func tags(for p: WindowProbe) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in rules where r.matches(p) {
            for t in r.tags where !seen.contains(t) {
                seen.insert(t)
                out.append(t)
            }
        }
        return out
    }

    /// Union resolved to a bitmask against `model` (unknown tag names
    /// dropped). Convenience over `tags(for:)` + `model.mask(for:)`.
    public func mask(for p: WindowProbe, in model: TagModel) -> UInt64 {
        model.mask(for: tags(for: p))
    }
}
