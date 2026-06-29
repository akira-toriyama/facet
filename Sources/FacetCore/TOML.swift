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

/// Every `[[name]]` array-of-tables block whose header `name` satisfies
/// `match`, keyed by that literal header text (rows in file order within
/// each). For DYNAMIC nested arrays like `[[desktop.N.section]]` where the
/// ordinal in the middle isn't known up front — the caller parses `N` out
/// of each key. The flat parser keys arrays by header text and is
/// nesting-agnostic, so `[[desktop.1.section]]` lands under `desktop.1.section`
/// independent of any `[desktop.1]` table.
public func parseTOMLArraysOfTables(
    _ text: String, where match: (String) -> Bool
) -> [String: [[String: TOMLValue]]] {
    Toml.parseFlat(text).arrays.filter { match($0.key) }
}

/// Group `[[desktop.N.tab]]` blocks with their nested `[[desktop.N.tab.section]]`
/// children, keyed by the mac-desktop ordinal `N`. The flat `parseFlat` skin is
/// nesting-AGNOSTIC (every `[[…]]` lands in a single per-header-text bucket, so
/// the parent→child association is lost); this walks the lossless `Toml.Annotated`
/// DOM in document order and re-binds each `.tab.section` to the most-recent
/// `.tab` of the same ordinal via `Block.path`.
///
/// Returns, per ordinal, the tabs in document order — each a raw `tab` row and
/// its raw child `sections` rows (`[String: TOMLValue]`, identical in shape to a
/// `parseFlat` row, since `Annotated.Entry.value` round-trips through `parseFlat`
/// — so the rows feed `DesktopSection.parse` exactly like the flat path). This is
/// the SYNTAX layer; `FacetConfig.decodeDesktopTabs` is the semantic decode.
///
/// LENIENT: `Toml.Annotated(parsing:)` is strict (throws on any malformed line),
/// but the nested-tab surface is new, so a hard parse error degrades the WHOLE
/// read to "no tabs" (`[:]`) rather than breaking the rest of config load (which
/// uses the lenient flat parser independently).
public func parseTOMLNestedTabs(_ text: String)
    -> [Int: [(tab: [String: TOMLValue], sections: [[String: TOMLValue]])]]
{
    // Strict parse → degrade the whole nested read to "no tabs" on any error
    // (the lenient flat parser handles the rest of config independently).
    guard let dom = try? Toml.Annotated(parsing: text) else { return [:] }

    var out: [Int: [(tab: [String: TOMLValue], sections: [[String: TOMLValue]])]] = [:]
    // The index of the currently-open tab PER ordinal, so a `.tab.section`
    // binds to the most-recent `.tab` of the SAME ordinal (document order).
    var openTab: [Int: Int] = [:]

    // One block's `key = value` entries as a flat row, identical in shape to a
    // `parseFlat` row (`Entry.value` round-trips through `parseFlat`). A dotted
    // key (`a.b = …`) is rejoined to `"a.b"`; an undecodable value is skipped.
    func row(_ block: Toml.Annotated.Block) -> [String: TOMLValue] {
        var r: [String: TOMLValue] = [:]
        for e in block.body.entries {
            if let v = e.value { r[e.key.joined(separator: ".")] = v }
        }
        return r
    }

    for block in dom.blocks where block.kind == .arrayElement {
        let p = block.path
        if p.count == 3, p[0] == "desktop", p[2] == "tab",
           let n = Int(p[1]), n >= 1 {
            // [[desktop.N.tab]] — open a new tab bucket for ordinal N.
            out[n, default: []].append((tab: row(block), sections: []))
            openTab[n] = out[n]!.count - 1
        } else if p.count == 4, p[0] == "desktop", p[2] == "tab",
                  p[3] == "section", let n = Int(p[1]), n >= 1 {
            // [[desktop.N.tab.section]] — append to the open tab of ordinal N;
            // a child with no preceding tab has nowhere to attach, so it drops.
            guard let ti = openTab[n] else { continue }
            out[n]![ti].sections.append(row(block))
        }
        // Anything else ([[desktop.N.section]] / [[exclude]] / [[rule]] / …) is
        // not the nested-tab surface — left to the flat decoders.
    }
    return out
}
