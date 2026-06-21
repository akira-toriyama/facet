// `[[desktop.N.section]]` — the ordered, config-driven display units that
// drive the pivot's filter-projected views (the section/lens model). This
// file owns the types + the TOML decode; the parsed sections are consumed
// in production via `effectiveMacDesktopSectionConfigs` — `FilterProjection`
// (tree), the adapter's section-lens park (grid/rail drop the parked windows
// via `Window.isLensParked`), `ApplyResolver` (DnD apply/un-apply), and
// `effectiveWorkspaceList` (workspace count + layout). Shipped #296–#301; gated
// per-desktop by `isSectionModelActive`.
//
// A section is one entry in the per-mac-desktop ordered array — the array
// order IS the tree's display order. Each section is one of three TYPES
// (the `type` discriminator), kept strictly apart (see docs/glossary.md):
//
//   • type = "workspace" — a permanent SPATIAL substrate (the tiling axis,
//     the grid/rail cell). AUTO-NAMED (the emoji pool, PR4): the user
//     neither names nor filters it — its `match` is the implicit
//     `workspace=<this>` and its `apply` the implicit `setWorkspace(<this>)`,
//     both resolved internally. Carries only an optional `layout` seed
//     (per-section, runtime-changeable) + an optional `apply` seed.
//   • type = "lens" — a SAVED visibility filter orthogonal to workspace
//     (an SQL VIEW): `label` + `match` (a `facet filter` WHERE-clause) +
//     optional `apply` (the inverse, for drops). Activated at runtime with
//     `facet lens NAME` (tag-unification Phase 1): the backend anchor-parks
//     every window in the ACTIVE workspace the `match` doesn't select (a real
//     hide) and re-tiles the rest; `facet lens --clear` lifts it. The
//     grid/rail cell count stays INVARIANT (a lens narrows what's shown inside
//     the ACTIVE workspace cell by dropping its `Window.isLensParked`
//     thumbnails, never re-bundles or drops a cell).
//     `match` is stored VERBATIM and compiled by the consumer, so a malformed
//     expression is rejected loud + non-fatal at projection time, never at
//     config load (parse-only stays total).
//   • type = "unassigned" — the lost-and-found safety net: `label` only.
//     (Deferred: the projection / tree branch is not built yet — under the
//     current catalog every managed window has a workspace, so an
//     AND-defined unassigned set is always empty. The TYPE is kept so the
//     model is complete; an "unplaced window" concept trips it later.)
//
// `type` is REQUIRED. An absent or unrecognised `type` DROPS the row with a
// loud reason — never a silent clamp to a default, which would mis-route a
// section's windows (e.g. discard an authored `match`). トミー 2026-06-17:
// warn + skip, never default-guess.
//
// `apply` FROZEN here so PR8's inversion resolver can rely on it:
//   - addTag is ADDITIVE by default (idempotent — re-adding is a no-op);
//     removeTag is its inverse (the only op un-apply reverses on a drag).
//   - setWorkspace is the single-valued special: a window has exactly one
//     workspace, so applying it AUTO-REPLACES the prior one.
//   - a section with no `apply` (or one wholly non-invertible) is
//     drop-INERT: a drop on it snaps back rather than mutating the window.

import Foundation

/// Which kind of section this is — the `[[desktop.N.section]]` `type`
/// discriminator. Raw values are the wire spellings (lowercased on decode).
public enum SectionType: String, Sendable, Equatable, CaseIterable {
    case workspace
    case lens
    case unassigned
}

/// One facet to set on a window routed into a section — the typed `apply`
/// op. Deliberately a closed enum (not a raw dict) so PR8's inversion
/// resolver switches over a fixed, exhaustive set. Shared with `[[rule]]`
/// (Phase 3) which reuses the same vocabulary.
public enum ApplyOp: Sendable, Equatable {
    /// Add a tag (additive, idempotent). The string is a normalized tag
    /// name (`TagName.normalized`), so it is reachable from the CLI.
    case addTag(String)
    /// Remove a tag — the inverse of `addTag`, and the ONLY op `un-apply`
    /// reverses when a drag MOVES a window out of an additive (tag) section
    /// (single-valued facets are last-writer-wins, never un-applied). No
    /// wire key: never authored, only synthesised by PR8's inversion.
    case removeTag(String)
    /// Force the window floating (`true`) or tiled (`false`).
    case setFloating(Bool)
    /// Pin the window across mac-desktop / workspace switches, or unpin.
    case setSticky(Bool)
    /// Mark/unmark as the layout master. Layout-derived in practice
    /// (`isMaster` is read from the resolved snapshot); carried here for
    /// wire symmetry with the frozen op set.
    case setMaster(Bool)
    /// Move the window to a named workspace (single-valued → auto-replace).
    case setWorkspace(String)
}

public extension ApplyOp {
    /// Decode an `apply = { … }` inline table into a canonically-ordered
    /// op list. The order is FROZEN (PR8's inversion depends on a stable,
    /// deterministic sequence — a TOML inline table is unordered):
    ///
    ///   setWorkspace → addTag(s) → setFloating → setSticky → setMaster
    ///
    /// setWorkspace leads so a mixed `{ workspace = "Dev", tags = ["c"] }`
    /// moves the window first, then tags it. `removeTag` is NOT decodable —
    /// it has no wire key (synthesised by un-apply only).
    ///
    /// Wire keys (all optional):
    ///   workspace = "Dev"        → setWorkspace
    ///   tags      = ["a", "b"]   → addTag per element, in array order
    ///                              (each normalized; invalid names dropped)
    ///   floating  = true|false   → setFloating
    ///   sticky    = true|false   → setSticky
    ///   master    = true|false   → setMaster
    ///
    /// A missing / non-table `apply` yields `[]` (drop-inert). Unknown
    /// keys are ignored — a typo can never break a sibling op.
    static func list(from value: TOMLValue?) -> [ApplyOp] {
        guard case .table(let t)? = value else { return [] }
        var ops: [ApplyOp] = []
        if case .string(let ws)? = t["workspace"], !ws.isEmpty {
            ops.append(.setWorkspace(ws))
        }
        if let tags = t["tags"]?.asStringArray {
            for raw in tags {
                if let name = TagName.normalized(raw) { ops.append(.addTag(name)) }
            }
        }
        if case .bool(let b)? = t["floating"] { ops.append(.setFloating(b)) }
        if case .bool(let b)? = t["sticky"]   { ops.append(.setSticky(b)) }
        if case .bool(let b)? = t["master"]   { ops.append(.setMaster(b)) }
        return ops
    }
}

/// One `[[desktop.N.section]]` table. Order within a mac desktop is config-
/// declaration order (= tree display order). See the file header for the
/// per-`type` field rules.
public struct DesktopSection: Sendable, Equatable {
    /// The section kind — drives the field rules + the projection semantics.
    public let type: SectionType
    /// Display header. Always present for `lens` / `unassigned`; `""` for a
    /// `workspace` section (auto-named — the label is resolved internally).
    public let label: String
    /// Raw `facet filter` WHERE-clause — compiled by the consumer, not here.
    /// `""` for `workspace` (implicit `workspace=<this>`) / `unassigned`.
    public let match: String
    /// Facets to set on a window routed into this section. `[]` = drop-inert.
    public let apply: [ApplyOp]
    /// Per-section layout seed. Set for `workspace` and `lens`; `nil` for
    /// `unassigned`. Consumed differently: workspace drives stateful tiling;
    /// lens drives union stateless tiling (see `LensLayout.resolve`).
    public let layout: String?

    public init(type: SectionType, label: String = "", match: String = "",
                apply: [ApplyOp] = [], layout: String? = nil) {
        self.type = type
        self.label = label
        self.match = match
        self.apply = apply
        self.layout = layout
    }

    /// Parse one `[[desktop.N.section]]` row into a section, OR a
    /// human-readable reason it was dropped / a caveat about an accepted
    /// row. The caller logs `note` LOUD (`Log.line`) with the ordinal +
    /// row index for context.
    ///
    /// `type` is REQUIRED and drives the per-type field rules. An absent or
    /// unrecognised `type` drops the row (`note` set, `section` nil) — never
    /// a silent clamp (which would mis-route a window's facets). A
    /// `workspace` section is auto-named, so any authored `label`/`match` is
    /// ignored with a caveat note (the section still decodes).
    static func parse(fromTOMLRow t: [String: TOMLValue])
        -> (section: DesktopSection?, note: String?)
    {
        guard case .string(let rawType)? = t["type"] else {
            return (nil, "missing `type` (expected workspace / lens / unassigned)")
        }
        guard let type = SectionType(rawValue: rawType.lowercased()) else {
            return (nil, "unknown `type` \"\(rawType)\" "
                + "(expected workspace / lens / unassigned)")
        }
        let label: String = {
            if case .string(let s)? = t["label"] { return s } else { return "" }
        }()
        let match: String = {
            if case .string(let s)? = t["match"] { return s } else { return "" }
        }()

        switch type {
        case .lens:
            guard !label.isEmpty else {
                return (nil, "lens section needs a non-empty `label`")
            }
            guard !match.isEmpty else {
                return (nil, "lens section \"\(label)\" needs a non-empty `match`")
            }
            var lensLayout: String? = nil
            if case .string(let l)? = t["layout"], !l.isEmpty { lensLayout = l }
            return (DesktopSection(type: .lens, label: label, match: match,
                                   apply: ApplyOp.list(from: t["apply"]),
                                   layout: lensLayout), nil)

        case .workspace:
            var layout: String? = nil
            if case .string(let l)? = t["layout"], !l.isEmpty { layout = l }
            // Auto-named + implicit match: authored label/match are ignored.
            let caveat = (!label.isEmpty || !match.isEmpty)
                ? "workspace section is auto-named — ignoring `label` / `match`"
                : nil
            return (DesktopSection(type: .workspace, label: "", match: "",
                                   apply: ApplyOp.list(from: t["apply"]),
                                   layout: layout), caveat)

        case .unassigned:
            guard !label.isEmpty else {
                return (nil, "unassigned section needs a non-empty `label`")
            }
            return (DesktopSection(type: .unassigned, label: label), nil)
        }
    }
}
