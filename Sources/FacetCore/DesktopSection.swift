// `[[desktop.N.section]]` — the ordered, config-driven display units that
// drive the pivot's filter-projected views (the section/lens model). This
// file owns the types + the TOML decode; the parsed sections are consumed
// in production via `effectiveMacDesktopSectionConfigs` — `FilterProjection`
// (the single display path for tree/grid/rail: a lens section lists its
// matched windows), `ApplyResolver` (DnD apply/un-apply), and
// `effectiveWorkspaceList` (workspace count + layout). Shipped #296–#301; gated
// per-desktop by `isSectionModelActive`.
//
// A section is one entry in the per-mac-desktop ordered array — the array
// order IS the tree's display order. Each section is one of three TYPES
// (the `type` discriminator), kept strictly apart (see docs/glossary.md):
//
//   • type = "workspace" — a permanent SPATIAL substrate (the tiling axis,
//     the grid/rail cell). The user does NOT filter it — its `match` is the
//     implicit `workspace=<this>` and its membership the implicit
//     `setWorkspace(<this>)`, both resolved internally — but MAY name it with
//     an optional `label` (§A reversed the always-auto-named rule); an empty
//     label leaves it UNNAMED, displayed by its 1-based index (§B retired the
//     emoji auto-name). Carries an optional `layout` seed (per-section,
//     runtime-changeable). t-qtpx: an authored `match` / `apply` is FORBIDDEN
//     (a workspace carries no side-effect — membership changes via DnD /
//     `facet window --move-to N`); an authored one is ignored with a caveat.
//   • type = "lens" — a SAVED visibility filter orthogonal to workspace
//     (an SQL VIEW): `label` + `match` (a `facet filter` WHERE-clause) +
//     optional `apply` (additive tags only, for drops — t-qtpx: a lens
//     `apply` may ONLY `tags = [...]`; `workspace` / `floating` / `sticky` /
//     `master` are forbidden and dropped). Activated at runtime with
//     `facet lens NAME`. A lens is a pure VIEW (t-0021): activating one only
//     changes what the tree/grid/rail DISPLAY — `FilterProjection` lists its
//     matched windows, aggregated across all workspaces on the current mac
//     desktop — and NEVER moves a real window. The user clicks a matched
//     window to jump to it (the ordinary window-focus path switches workspace
//     + focuses); `facet lens --clear` drops the view.
//     `match` is stored VERBATIM and compiled by the consumer, so a malformed
//     expression is rejected loud + non-fatal at projection time, never at
//     config load (parse-only stays total).
//   • type = "unassigned" — the lost-and-found safety net: an optional
//     `label` only (§A; no `match` / `apply`).
//     PROJECTED (§G): an opt-in receptacle that, when present, collects the
//     LEFTOVER (universe − shown) — the windows that land in NO other emitted
//     section. Only the first emits; extras warn.
//
// `type` is REQUIRED. An absent or unrecognised `type` DROPS the row with a
// loud reason — never a silent clamp to a default, which would mis-route a
// section's windows (e.g. discard an authored `match`). トミー 2026-06-17:
// warn + skip, never default-guess.
//
// `apply` FROZEN here so PR8's inversion resolver can rely on it. The full
// op vocabulary still exists for `[[rule]]` (Phase 3 adopt-rules, which may
// carry all ops); a `type="lens"` section is the one place a USER-authored
// `apply` lives, and there it is restricted to `addTag` (t-qtpx):
//   - addTag is ADDITIVE by default (idempotent — re-adding is a no-op);
//     removeTag is its inverse (the only op un-apply reverses on a drag).
//   - setWorkspace is the single-valued special: a window has exactly one
//     workspace, so applying it AUTO-REPLACES the prior one. NOT allowed in a
//     lens `apply` (lenses never relocate); used only by `[[rule]]`.
//   - a lens with no `apply` (or one wholly non-invertible) is drop-INERT:
//     a drop on it snaps back rather than mutating the window.

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
    /// Display header — an **optional** name on every `type` (§A): `""` when
    /// unset. A non-empty workspace label names the workspace from config (the
    /// old "always auto-named" rule was reversed); an empty one falls back to
    /// the auto-name. lens / unassigned headers are likewise optional now.
    public let label: String
    /// Raw `facet filter` WHERE-clause — compiled by the consumer, not here.
    /// `""` for `workspace` (implicit `workspace=<this>`) / `unassigned`.
    public let match: String
    /// Facets to set on a window routed into this section. `[]` = drop-inert.
    public let apply: [ApplyOp]
    /// Per-section layout seed — meaningful only for `workspace` (drives its
    /// stateful tiling engine). A lens is a pure VIEW (t-0021) and tiles
    /// nothing, so a `layout` on a `lens` / `unassigned` section is parsed but
    /// IGNORED (harmless dead data, per the clamp-don't-reject config rule).
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
    /// row index for context. Multiple per-row caveats are joined with
    /// `"; "` into the single `note`.
    ///
    /// `type` is REQUIRED and drives the per-type field rules (t-qtpx). An
    /// absent or unrecognised `type` drops the row (`note` set, `section`
    /// nil) — never a silent clamp (which would mis-route a window's facets).
    /// `label` is OPTIONAL on every type (§A). Per-type field allowance:
    ///   • workspace — `match` AND `apply` FORBIDDEN (it is the exclusive
    ///     spatial substrate, not a filter, with no side-effect); an authored
    ///     one is ignored with a caveat, the section still decodes. `label`,
    ///     if set, names the workspace.
    ///   • lens — `match` REQUIRED; `apply` may ONLY add tags
    ///     (`apply = { tags = [...] }`). A `workspace` / `floating` / `sticky`
    ///     / `master` op in a lens `apply` is FORBIDDEN — warned + dropped.
    ///   • unassigned — `match` AND `apply` FORBIDDEN (leftover by
    ///     subtraction); authored ones ignored with a caveat.
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
        // A non-empty inline `apply = { … }` table was authored on this row
        // (an `apply = {}` / non-table value never trips a forbidden-apply
        // caveat — there is nothing to ignore).
        let applyAuthored: Bool = {
            if case .table(let at)? = t["apply"] { return !at.isEmpty }
            return false
        }()

        switch type {
        case .lens:
            // §A: `label` is optional (display-only); `match` stays REQUIRED.
            guard !match.isEmpty else {
                return (nil, "lens section needs a non-empty `match`")
            }
            var lensLayout: String? = nil
            if case .string(let l)? = t["layout"], !l.isEmpty { lensLayout = l }
            // t-qtpx: a lens `apply` is the section's ONLY drop side-effect and
            // it may ONLY ADD TAGS (additive). The single-valued facets —
            // `workspace` / `floating` / `sticky` / `master` — are FORBIDDEN on
            // a lens (workspace membership is the workspace axis; window
            // attributes are direct CLI). Decode the full op list, KEEP
            // `addTag`, warn + DROP the rest. (`removeTag` has no wire key, so
            // it never appears here.)
            var kept: [ApplyOp] = []
            var droppedKeys: [String] = []
            for op in ApplyOp.list(from: t["apply"]) {
                switch op {
                case .addTag:       kept.append(op)
                case .setWorkspace: droppedKeys.append("workspace")
                case .setFloating:  droppedKeys.append("floating")
                case .setSticky:    droppedKeys.append("sticky")
                case .setMaster:    droppedKeys.append("master")
                case .removeTag:    break
                }
            }
            let note = droppedKeys.isEmpty ? nil
                : "lens `apply` accepts only `tags` — ignoring "
                  + droppedKeys.joined(separator: ", ")
            return (DesktopSection(type: .lens, label: label, match: match,
                                   apply: kept, layout: lensLayout), note)

        case .workspace:
            var layout: String? = nil
            if case .string(let l)? = t["layout"], !l.isEmpty { layout = l }
            // t-qtpx: a workspace is the exclusive spatial substrate — NOT a
            // filter and carrying NO side-effect. Both `match` (its membership
            // is the implicit `workspace=<this>`) and `apply` are FORBIDDEN; an
            // authored one is ignored with a loud caveat (membership changes
            // via DnD / `facet window --move-to N`, never config apply). A
            // non-empty `label` NAMES the workspace (§A).
            var notes: [String] = []
            if !match.isEmpty {
                notes.append("workspace section's `match` is implicit — "
                    + "ignoring authored `match`")
            }
            if applyAuthored {
                notes.append("workspace section can't carry `apply` — ignoring it")
            }
            return (DesktopSection(type: .workspace, label: label, match: "",
                                   apply: [], layout: layout),
                    notes.isEmpty ? nil : notes.joined(separator: "; "))

        case .unassigned:
            // §A / t-qtpx: the lost-and-found receptacle is the LEFTOVER by
            // subtraction — neither a filter nor an apply target, so both
            // `match` and `apply` are FORBIDDEN (authored ones ignored with a
            // loud caveat). Only an optional `label` is meaningful.
            var notes: [String] = []
            if !match.isEmpty {
                notes.append("unassigned section can't carry `match` — ignoring it")
            }
            if applyAuthored {
                notes.append("unassigned section can't carry `apply` — ignoring it")
            }
            return (DesktopSection(type: .unassigned, label: label),
                    notes.isEmpty ? nil : notes.joined(separator: "; "))
        }
    }
}

/// One `[[desktop.N.tab]]` — a NAMED grouping of sections within a mac desktop
/// (the board model, t-wrd2). A tab is a `type` (`workspace` OR `lens` — never
/// `unassigned`, which is a per-section marker, not a grouping) + an optional
/// `label` + an ordered list of child `[[desktop.N.tab.section]]` sections.
///
/// The children carry NO `type` of their own — every section in a tab INHERITS
/// the tab's `type` (mixing is impossible by construction). The one escape is a
/// child marked `unassigned = true`, the per-tab lost-and-found receptacle,
/// which decodes to a `.unassigned` section regardless of the parent type.
///
/// PURE DATA + ADDITIVE (t-f19q / Wave 1): this models the nested config so a
/// later wave can wire boards into the projection / UI. Nothing consumes
/// `FacetConfig.macDesktopTabConfigs` yet — the reader is `decodeDesktopTabs`.
public struct DesktopTab: Sendable, Equatable {
    /// The tab's kind — `workspace` or `lens`. Every child section inherits it.
    public let type: SectionType
    /// Display header — an optional name (`""` when unset), like a section's.
    public let label: String
    /// The tab's sections, in config-declaration (= display) order.
    public let sections: [DesktopSection]

    public init(type: SectionType, label: String = "",
                sections: [DesktopSection] = []) {
        self.type = type
        self.label = label
        self.sections = sections
    }

    /// The caption the tree tab bar (t-wrd2 / W2.4) shows for this board. A
    /// named board reads its `label`; an UNNAMED one falls back to a type-
    /// default (`Workspaces` / `Lenses`) so the tab is never blank and the
    /// type reads at a glance. The 1-based index is CLI-addressing only
    /// (`facet board --focus N`) and is never shown here. Display-only / pure —
    /// identity stays on the board's position, never this caption.
    public var displayLabel: String {
        if !label.isEmpty { return label }
        switch type {
        case .workspace:  return "Workspaces"
        case .lens:       return "Lenses"
        case .unassigned: return "Unassigned"   // unreachable: a board is workspace/lens
        }
    }
}
