// WorkspaceNaming — the emoji auto-name pool for the section/lens model.
//
// A hard PREREQUISITE of the "user cannot name workspaces" rule: in a
// section-managed desktop (`isSectionModelActive`), a `type = "workspace"`
// section carries no name — the workspace IS its spatial slot, labelled by
// a deterministic BARE emoji drawn from this pool by INDEX (e.g. "🐶").
// (The implicit match keys on the index, not this label, so a pool-wrap
// collision is purely cosmetic — see `FilterProjection`.)
//
// IDENTITY vs DISPLAY: the pool entry IS the identity name — a BARE emoji,
// space-free — so a workspace stays targetable on the CLI (`facet workspace
// --focus 🐶`), on the DNC wire, and in `match` / query. The friendly
// "emoji + English name" caption (e.g. "🐶 Dog") is DISPLAY-ONLY: it is
// derived at render time by `displayLabel(forName:)` (reached through
// `workspaceShortLabel`) and is never an identity token.
//
// Pure FacetCore. The seed path reads it through
// `FacetConfig.effectiveWorkspaceList`; the dynamic `facet workspace --add`
// path renames the new slot via the adapter. NOT engaged for a section-less
// desktop — its default slots stay unnamed until a runtime rename.

import Foundation

public enum WorkspaceNaming {
    /// The fixed pool of BARE-emoji identity names, in order: animals →
    /// fruits → foods (the family grammar 🐶🍎🍕). Index 0 is the first
    /// animal; positions past the end wrap with a numeric suffix (🐶, …,
    /// last food, then 🐶2, 🐱2, …). Space-free so the name stays a valid
    /// CLI / DNC / match identity.
    public static let pool: [String] = [
        // animals
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
        "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
        // fruits
        "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓",
        "🫐", "🍒", "🍑", "🥝",
        // foods
        "🍕", "🍔", "🌭", "🍟", "🍿", "🧀", "🥪", "🌮",
        "🍣", "🍜", "🍩", "🍪",
    ]

    /// The English display word for each `pool` entry — same length and
    /// order. Used only by `displayLabel` to build the "emoji + name"
    /// caption; never part of the identity name.
    public static let words: [String] = [
        // animals
        "Dog", "Cat", "Mouse", "Hamster", "Rabbit", "Fox", "Bear", "Panda",
        "Koala", "Tiger", "Lion", "Cow", "Pig", "Frog", "Monkey", "Chicken",
        // fruits
        "Apple", "Pear", "Orange", "Lemon", "Banana", "Watermelon", "Grapes",
        "Strawberry", "Blueberry", "Cherry", "Peach", "Kiwi",
        // foods
        "Pizza", "Burger", "Hotdog", "Fries", "Popcorn", "Cheese", "Sandwich",
        "Taco", "Sushi", "Ramen", "Donut", "Cookie",
    ]

    /// The auto-name (IDENTITY) for the workspace at 0-based `index`.
    /// Deterministic and total: a negative index clamps to 0; an index past
    /// the pool length wraps with a numeric suffix (so the name is always
    /// non-empty and the k-th workspace always resolves to the same label
    /// across a session). BARE emoji — space-free.
    public static func name(forIndex index: Int) -> String {
        let i = max(0, index)
        let emoji = pool[i % pool.count]
        let cycle = i / pool.count
        return cycle == 0 ? emoji : "\(emoji)\(cycle + 1)"
    }

    /// The DISPLAY caption for an identity `name`: "emoji + English word"
    /// (e.g. "🐶" → "🐶 Dog"; overflow "🐶2" → "🐶 Dog2"). A name not in the
    /// pool (user-renamed, empty, or otherwise) is returned VERBATIM — the
    /// friendly word only decorates auto-named slots. Display-only; this
    /// string is never an identity token (it carries a space).
    public static func displayLabel(forName name: String) -> String {
        if name.isEmpty { return name }
        // Peel a trailing run of ASCII digits (the pool-wrap suffix) off the
        // end; the bare emoji itself contains no ASCII digit.
        var base = name
        var suffix = ""
        while let last = base.last, last.isASCII, last.isNumber {
            suffix = String(last) + suffix
            base.removeLast()
        }
        guard let idx = pool.firstIndex(of: base), idx < words.count else {
            return name
        }
        return "\(base) \(words[idx])\(suffix)"
    }
}
