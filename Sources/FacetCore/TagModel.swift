// Tag model (M11-3) — pure, backend-neutral, unit-testable.
//
// In `[grouping] by = "tag"` mode a window carries a SET of tags
// instead of a single workspace. Visibility is dwm's `tags & viewmask`:
// a window shows when its tag bits intersect the current `lens`. This
// file holds the pure piece:
//
//   - `TagModel`: the ordered tag vocabulary (config `[[tag]]` order)
//     and the name ⇄ bit mapping. Declaration order is load-bearing —
//     it fixes each tag's bit, drives the startup lens (`firstBit`),
//     and sets the order tag chips list on a window's flat tree row
//     (`names(in:)`).
//
// There is NO static window→tag assignment: a fresh window inherits the
// current lens's primary tag (the catalog's job), then the user retags
// at runtime. (The old config `[[assign]]` rules were retired in #191 —
// runtime tagging replaces them.)
//
// The vocabulary SEEDS from config (`[[tag]]`) but is mutable at
// runtime (#191): `facet window --tag` retags one window, `facet tag
// --add/--remove/--rename` edits the vocabulary itself. `remove` frees
// its bit as a reusable hole rather than compacting (see `TagModel`
// below) so existing windows' masks never have to shift. All runtime
// state is session-only — config stays the seed, rebuilt on restart.

/// The ordered tag vocabulary plus name ⇄ bit mapping. Bit `i` is the
/// tag in slot `i`; up to 63 USER tags (a `UInt64` mask, dwm caps at
/// 31). Bit 63 is reserved for the `_default` floor (`defaultBit`) and
/// is NOT part of the user vocabulary, so names past 63 are dropped at
/// construction.
///
/// Runtime `remove` (`facet tag --remove`, #191) frees a slot WITHOUT
/// compacting: the vacated bit becomes a hole that a later `add`
/// reuses (sparse + free-list). Compaction would shift every
/// higher-bit tag down, forcing a mask rewrite on every window;
/// sparse keeps existing windows' bits stable, so the only cross-window
/// work on a remove is clearing the one freed bit.
public struct TagModel: Sendable, Equatable {
    /// Slot `i` holds the user tag at bit `i`, or `nil` when that bit
    /// is free — a `remove` vacated it and the next `add` reuses the
    /// lowest hole. Trailing `nil`s are trimmed so two models with the
    /// same live tags compare equal regardless of add/remove history.
    /// Not exposed directly; read `names` (defined names) or `bit(for:)`
    /// (name → bit) instead.
    private let slots: [String?]

    /// The reserved top bit (63) — the `_default` floor (M11-3 → #191).
    /// In tag mode every window carries it, so a window is never
    /// `tags == 0` ("lost"). It is NOT part of the user vocabulary: it
    /// never appears in `[[tag]]`, in `names`, in a `lens NAME` (only) mask,
    /// or as a tree chip. User tags occupy bits 0...62; `allMask` (the
    /// `lens --all` user-tag union) never sets it. The catalog ORs it
    /// in where the floor must apply (new windows, `lens --all`).
    public static let defaultBit: UInt64 = UInt64(1) << 63
    /// Internal marker name for `defaultBit`. Reserved: the CLI
    /// tag-name parser rejects it (leading `_`) and it never appears in
    /// `names`.
    public static let defaultName = "_default"
    /// Max user-tag count — bit 63 is reserved for `defaultBit`.
    public static let maxUserTags = 63

    /// Construct from declaration-ordered names (config / startup) —
    /// no holes; names past bit 62 are dropped.
    public init(_ names: [String]) {
        self.slots = Array(names.prefix(TagModel.maxUserTags))
    }

    /// Build from raw slots, trimming trailing holes so equality is
    /// history-independent.
    private init(slots: [String?]) {
        var s = slots
        while s.last == .some(nil) { s.removeLast() }
        self.slots = s
    }

    /// Defined tag names in declaration (bit) order — freed holes are
    /// omitted, so a `names` index is NOT a bit position once a remove
    /// has opened a hole (use `bit(for:)` for bits). The `lens --all`
    /// union and a window's tag-chip name set read from here.
    public var names: [String] { slots.compactMap { $0 } }

    public var isEmpty: Bool { !slots.contains { $0 != nil } }
    /// Count of DEFINED tags (holes excluded).
    public var count: Int { slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// The single bit for a tag name (by slot), or `nil` when the name
    /// isn't in the vocabulary.
    public func bit(for name: String) -> UInt64? {
        guard let i = slots.firstIndex(where: { $0 == name }) else {
            return nil
        }
        return UInt64(1) << UInt64(i)
    }

    /// Bitmask for a list of names; unknown names are ignored (a typo
    /// loses just that one tag, never crashes — TOML-parser stance).
    public func mask(for tagNames: [String]) -> UInt64 {
        tagNames.reduce(0) { $0 | (bit(for: $1) ?? 0) }
    }

    /// Mask with every defined USER tag set — the `lens --all` user-tag
    /// union (bits 0...62). The union of the populated slots' bits, so
    /// freed holes drop out. Empty model → 0. Never sets `defaultBit`
    /// (bit 63); the catalog ORs that in separately so `--all` also
    /// reveals windows carrying only the `_default` floor.
    public var allMask: UInt64 {
        slots.enumerated().reduce(0) { acc, e in
            e.element == nil ? acc : acc | (UInt64(1) << UInt64(e.offset))
        }
    }

    /// The lowest defined tag's bit (slot order) — the startup lens
    /// default and the `tagsForNewWindow` floor-fallback. `nil` when no
    /// tags are defined.
    public var firstBit: UInt64? {
        guard let i = slots.firstIndex(where: { $0 != nil }) else {
            return nil
        }
        return UInt64(1) << UInt64(i)
    }

    /// The names present in a mask, in declaration order — the tag-chip
    /// set for a window's flat tree row. Freed-hole bits contribute
    /// nothing.
    public func names(in mask: UInt64) -> [String] {
        slots.enumerated().compactMap { (i, name) in
            guard let name else { return nil }
            return (mask & (UInt64(1) << UInt64(i))) != 0 ? name : nil
        }
    }

    // MARK: - Runtime vocabulary mutation (#191, sparse + free-list)

    /// Add `name`, reusing the lowest freed slot or appending a new
    /// one. Returns its bit — the existing bit if already defined
    /// (idempotent) — or `nil` when `name` is reserved (`_default`) or
    /// the vocabulary is full (no free bit in 0...62).
    public mutating func add(_ name: String) -> UInt64? {
        if let bit = bit(for: name) { return bit }              // defined
        guard name != TagModel.defaultName else { return nil }  // reserved
        var s = slots
        if let hole = s.firstIndex(where: { $0 == nil }) {      // reuse
            s[hole] = name
            self = TagModel(slots: s)
            return UInt64(1) << UInt64(hole)
        }
        guard s.count < TagModel.maxUserTags else { return nil } // full
        s.append(name)
        self = TagModel(slots: s)
        return UInt64(1) << UInt64(s.count - 1)
    }

    /// Remove `name`, freeing its bit for a later `add` to reuse.
    /// Returns the freed bit, or `nil` when `name` is unknown or
    /// reserved. Does NOT touch window masks — stripping the bit from
    /// windows is the catalog's cross-window job.
    public mutating func remove(_ name: String) -> UInt64? {
        guard name != TagModel.defaultName,
              let i = slots.firstIndex(where: { $0 == name }) else {
            return nil
        }
        var s = slots
        s[i] = nil
        self = TagModel(slots: s)
        return UInt64(1) << UInt64(i)
    }

    /// Outcome of an in-place `rename` (the bit never moves, so window
    /// masks need no rewrite).
    public enum RenameOutcome: Equatable, Sendable {
        /// Renamed — carries the (unchanged) bit, for logging.
        case renamed(UInt64)
        /// `old` isn't a defined tag.
        case unknownOld
        /// `new` is already defined (or the reserved floor name) — a
        /// collision would fuse two tags, so it's rejected.
        case collision
    }

    /// Rename `old` to `new` in place — the bit is unchanged.
    /// Idempotent when `old == new`. Rejects an unknown `old`
    /// (`.unknownOld`) or a `new` that's already defined / reserved
    /// (`.collision`).
    public mutating func rename(_ old: String, to new: String) -> RenameOutcome {
        guard let i = slots.firstIndex(where: { $0 == old }) else {
            return .unknownOld
        }
        if old == new { return .renamed(UInt64(1) << UInt64(i)) }
        guard new != TagModel.defaultName,
              !slots.contains(where: { $0 == new }) else {
            return .collision
        }
        var s = slots
        s[i] = new
        self = TagModel(slots: s)
        return .renamed(UInt64(1) << UInt64(i))
    }
}
