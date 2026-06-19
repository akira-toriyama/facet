// WorkspaceNaming — the emoji auto-name pool for the section/lens model.
//
// A hard PREREQUISITE of the "user cannot name workspaces" rule: in a
// section-managed desktop (`isSectionModelActive`), a `type = "workspace"`
// section carries no name — the workspace IS its spatial slot, labelled by
// a deterministic emoji drawn from this pool by INDEX. (The implicit match
// keys on the index, not this label, so a pool-wrap collision is purely
// cosmetic — see `FilterProjection`.)
//
// Pure FacetCore. The seed path reads it through
// `FacetConfig.effectiveWorkspaceList`; the dynamic `facet workspace --add`
// path renames the new slot via the adapter. NOT engaged for a section-less
// desktop — its default slots stay unnamed until a runtime rename.

import Foundation

public enum WorkspaceNaming {
    /// The fixed pool, in order: animals → fruits → foods (the family
    /// grammar 🐶🍎🍕). Index 0 is the first animal; positions past the end
    /// wrap with a numeric suffix (🐶, …, last food, then 🐶2, 🐱2, …).
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

    /// The auto-name for the workspace at 0-based `index`. Deterministic and
    /// total: a negative index clamps to 0; an index past the pool length
    /// wraps with a numeric suffix (so the name is always non-empty and the
    /// k-th workspace always resolves to the same label across a session).
    public static func name(forIndex index: Int) -> String {
        let i = max(0, index)
        let emoji = pool[i % pool.count]
        let cycle = i / pool.count
        return cycle == 0 ? emoji : "\(emoji)\(cycle + 1)"
    }
}
