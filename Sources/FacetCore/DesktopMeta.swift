// `[desktop.N]` — the typed mac-desktop table (board abolition, t-0sbm). Each
// mac desktop is EITHER a `workspace` desktop (its `[[desktop.N.section]]`
// sections tile as usual, shown in tree/grid/rail) OR a `lens` desktop (a single
// ALWAYS-ON `match` + `layout`, tree-only: the matched windows tile, the rest
// anchor-park). One ordinal = one desktop = one `type`. This replaces the
// browser-tab `[[desktop.N.tab]]` board grouping (which grouped BOTH kinds inside
// one desktop and was retired as one concept too many).
//
// `[desktop.N]` is a SINGLE table (not a `[[…]]` array — one ordinal is one
// desktop), decoded from the flat `parseTOMLSubset` map by `decodeDesktopTables`
// into `FacetConfig.macDesktopMetaConfigs` and read via `desktopType` /
// `desktopIsolate` (the isolate desktop's runtime is `applyIsolatePark` +
// `FilterProjection.projectIsolateDesktop`).

import Foundation

/// One `[desktop.N]` typed-desktop table. `match` / `layout` / `showNonMatching`
/// are meaningful only on a `lens` desktop (a `workspace` desktop keeps its layout
/// on its `[[desktop.N.section]]` rows).
public struct DesktopMeta: Sendable, Equatable {
    /// The desktop kind — `workspace` or `lens`.
    public let type: DesktopType
    /// Display name for this mac desktop (`""` when unset).
    public let label: String
    /// isolate desktop only — the `facet filter` WHERE-clause selecting the tiled set.
    /// `""` for a workspace desktop.
    public let match: String
    /// isolate desktop only — layout-engine name for the matched windows (`nil` = default).
    public let layout: String?
    /// isolate desktop only — also surface the non-matching windows as a 2nd tree
    /// section (the "holding" receptacle). Default `false` → tree shows only the
    /// matched section.
    public let showNonMatching: Bool

    public init(type: DesktopType, label: String = "", match: String = "",
                layout: String? = nil, showNonMatching: Bool = false) {
        self.type = type
        self.label = label
        self.match = match
        self.layout = layout
        self.showNonMatching = showNonMatching
    }

    /// Parse one `[desktop.N]` table row into a `DesktopMeta`, OR a human-readable
    /// reason it was dropped / a caveat about an accepted row (the caller logs
    /// `note` LOUD with the ordinal). `type` is REQUIRED — an absent / unknown one
    /// DROPS the desktop (never a silent clamp, which would mis-route it).
    /// Per-type field rules:
    ///   • lens — `match` REQUIRED (non-empty); `layout` + `show-non-matching`
    ///     honoured.
    ///   • workspace — `match` / `layout` / `show-non-matching` all belong on its
    ///     `[[desktop.N.section]]` rows, not here — ignored w/ caveat.
    static func parse(fromTOMLRow t: [String: TOMLValue])
        -> (meta: DesktopMeta?, note: String?)
    {
        let label: String = {
            if case .string(let s)? = t["label"] { return s } else { return "" }
        }()
        guard case .string(let rawType)? = t["type"] else {
            return (nil, "missing `type` (expected workspace / isolate)")
        }
        // Tombstone, not an alias (t-mqqw). `lens` was renamed to `isolate`
        // because the optical metaphor was a lie — this desktop moves real
        // windows. facet keeps no compatibility aliases, so name the retired
        // spelling instead of letting it fall into the generic "unknown type"
        // message: the reader deserves to know WHAT to write and WHY.
        if rawType.lowercased() == "lens" {
            return (nil, "`type = \"lens\"` was renamed to `type = \"isolate\"` "
                + "(it tiles the matched windows and anchor-parks the rest — it "
                + "was never a view)")
        }
        guard let type = DesktopType(rawValue: rawType.lowercased()) else {
            return (nil, "unknown `type` \"\(rawType)\" (expected workspace / isolate)")
        }
        let match: String = {
            if case .string(let s)? = t["match"] { return s } else { return "" }
        }()
        let hasLayout: Bool = {
            if case .string(let l)? = t["layout"], !l.isEmpty { return true }
            return false
        }()
        let hasShowKey = t["show-non-matching"] != nil

        switch type {
        case .isolate:
            guard !match.isEmpty else {
                return (nil, "isolate desktop needs a non-empty `match`")
            }
            var layout: String? = nil
            if case .string(let l)? = t["layout"], !l.isEmpty { layout = l }
            let showNonMatching: Bool = {
                if case .bool(let b)? = t["show-non-matching"] { return b }
                return false
            }()
            return (DesktopMeta(type: .isolate, label: label, match: match,
                                layout: layout, showNonMatching: showNonMatching),
                    nil)

        case .workspace:
            var notes: [String] = []
            if !match.isEmpty {
                notes.append("`match` is isolate-only (did you mean "
                    + "`type = \"isolate\"`?) — ignoring it")
            }
            if hasLayout {
                notes.append("workspace desktop's `layout` belongs on its "
                    + "sections — ignoring it")
            }
            if hasShowKey {
                notes.append("`show-non-matching` is isolate-only — ignoring it")
            }
            return (DesktopMeta(type: .workspace, label: label),
                    notes.isEmpty ? nil : notes.joined(separator: "; "))
        }
    }
}
