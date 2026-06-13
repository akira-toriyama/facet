// facet's hand-rolled TOML *subset* parser (~250 lines) folded into
// sill's shared, pure `Toml` module in atelier Phase 1.6 — facet is the
// fourth and last consumer to swap. What remains here is a thin adapter
// that keeps facet's historical surface (`parseTOMLSubset` /
// `parseTOMLArrayOfTables` / `TOMLValue`) over sill's parser, so neither
// FacetConfig nor the config tests churn. facet uses the FLAT, lenient
// skin (`Toml.parseFlat`), keyed by the literal header text.
//
// `Toml.Value` is a superset of facet's old `TOMLValue`: it keeps
// int / double / string / bool / table, replaces the dedicated
// `.stringArray` case with a generic `.array` (read via `asStringArray`),
// and stores ints as `Int64`. The one ripple into FacetConfig: an
// integer knob is read through `.asInt` (which is `.int`-only — a
// fractional value is still ignored, not truncated) rather than a
// direct `if case .int` binding.
//
// As a bonus over the retired parser, sill adds (none breaking facet's
// config): multi-line arrays, `0x…` hex ints, and escape-aware
// comment/quote walking — so e.g. `#` inside an inline-table string value
// (`name = "tag # 1"`) is now preserved as data, not cut as a comment.

import Toml

/// facet's historical value alias. NOTE: `Toml.Value` has no
/// `.stringArray` case — a string array is `.array(...)`, read via
/// `asStringArray`.
public typealias TOMLValue = Toml.Value

/// Parse into `[section: [key: value]]` (`""` = top-level scope), lenient
/// (a malformed line drops just itself). Sections are keyed by the literal
/// header text, matching facet's old parser.
public func parseTOMLSubset(_ text: String) -> [String: [String: TOMLValue]] {
    Toml.parseFlat(text).tables
}

/// Collect the repeated `[[name]]` array-of-tables blocks, in file order
/// (one dict per occurrence). Empty when the table never appears.
public func parseTOMLArrayOfTables(_ text: String, table name: String)
    -> [[String: TOMLValue]]
{
    Toml.parseFlat(text).arrays[name] ?? []
}
