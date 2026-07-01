// Runtime structural validation of `config.toml` — the STRICT counterpart
// to the lenient `load()`. Driven by the SAME declarative `configSpec`
// (FacetConfig+Spec.swift) that powers the decode and `--emit-schema`, via
// sill 1.29.0's `ConfigSchema.Spec.validate` bridge (t-0029). One source ⇒
// "editor green (taplo)" and "loader accepts it" can't diverge.

import ConfigSchema
import Toml

public extension FacetConfig {

    /// Validate `config.toml` SOURCE against `configSpec`. Surfaces the
    /// type / enum / range / unknown-key mismatches that the lenient
    /// `load()` silently clamps or drops — the input to `facet config
    /// --validate`.
    ///
    /// - Throws if `source` isn't parseable TOML at all (a syntax error);
    ///   the caller maps that to exit 2.
    /// - Returns EVERY schema violation (does not stop at the first); an
    ///   empty array means structurally valid.
    ///
    /// Note it parses with the STRICT nested `Toml.parse` (the form
    /// `Spec.validate` walks), not the lenient `parseTOMLSubset`
    /// (`Toml.parseFlat`) the decode reads — validation is a deliberate
    /// hard check, load stays forgiving.
    static func validate(_ source: String) throws -> [ValidationError] {
        let root = try Toml.parse(source)
        return configSpec.validate(root)
    }
}
