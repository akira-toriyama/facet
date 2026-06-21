// Resolve a lens section's union layout to a STATELESS engine. A
// type="lens" section tiles a cross-workspace union (decision ⑩/⑫); the
// stateful engines (bsp/stack) thread a per-workspace tree and can't
// represent an arbitrary union, so a lens layout is clamped here exactly
// like tag-mode's config validation. A typo / forbidden value never
// breaks tiling — it falls back, it doesn't reject.
public enum LensLayout {
    /// Stateless engine name for a lens union. `requested` is the
    /// section's `layout`; `globalDefault` is `[layout] default`. Order:
    /// requested-if-stateless → globalDefault-if-stateless → grid.
    /// Lowercasing happens exactly once, on the returned value (isStateless
    /// canonicalises its own argument internally).
    public static func resolve(_ requested: String?, globalDefault: String) -> String {
        if let r = requested, isStateless(r) { return r.lowercased() }
        if isStateless(globalDefault) { return globalDefault.lowercased() }
        return GridLayout().name
    }

    /// A stateless engine = a registered `LayoutEngine` (master-*/grid/
    /// spiral). bsp / stack / float are NOT stateless engines.
    /// Lowercases its argument before the registry lookup so it is
    /// independently callable regardless of the caller's case convention.
    /// Public: FacetAdapterNative's active-lens layout guard (EX-1b.6)
    /// reuses this as the canonical "can this mode tile a union?" predicate.
    public static func isStateless(_ mode: String) -> Bool {
        LayoutRegistry.engine(named: mode.lowercased()) != nil
    }
}
