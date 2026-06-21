// Resolve a lens section's union layout to a STATELESS engine. A
// type="lens" section tiles a cross-workspace union (decision ⑩/⑫); the
// stateful engines (bsp/stack) thread a per-workspace tree and can't
// represent an arbitrary union, so a lens layout is clamped here exactly
// like tag-mode's config validation. A typo / forbidden value never
// breaks tiling — it falls back, it doesn't reject.
public enum LensLayout {
    /// Stateless engine name for a lens union. `requested` is the
    /// section's `layout`; `globalDefault` is `[layout] default`. Order:
    /// requested-if-stateless → globalDefault-if-stateless → "grid".
    public static func resolve(_ requested: String?, globalDefault: String) -> String {
        if let r = requested?.lowercased(), isStateless(r) { return r }
        let g = globalDefault.lowercased()
        if isStateless(g) { return g }
        return "grid"
    }

    /// A stateless engine = a registered `LayoutEngine` (master-*/grid/
    /// spiral). bsp / stack / float are NOT stateless engines.
    public static func isStateless(_ mode: String) -> Bool {
        LayoutRegistry.engine(named: mode.lowercased()) != nil
    }
}
