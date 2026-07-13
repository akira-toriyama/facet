// `[[desktop.N.section]]` — the ordered, config-driven workspace SPATIAL cells
// that drive the filter-projected views. This file owns the types + the TOML
// decode; the parsed sections are consumed in production via
// `effectiveMacDesktopSectionConfigs` — `FilterProjection` (the single display
// path for tree/grid/rail) and `effectiveWorkspaceList` (workspace count +
// layout). Gated per-desktop by `isSectionModelActive`.
//
// A section is one entry in the per-mac-desktop ordered array — the array
// order IS the tree's display order. Since the section-lens type was retired
// (t-ec9s: `lens` is now ONLY a typed mac desktop, `[desktop.N] type=lens`),
// EVERY authored section is a workspace SPATIAL substrate (the tiling axis, the
// grid/rail cell):
//
//   • the user does NOT filter it — its membership is the implicit
//     `workspace=<this>` — but MAY name it with an optional `label` (§A: an
//     empty label leaves it UNNAMED, displayed by its 1-based index). Carries an
//     optional `layout` seed (per-section, runtime-changeable).
//
// There is no second kind. The `unassigned = true` MARKER — the lost-and-found
// receptacle that collected the leftover (universe − shown) — went with the
// orphan concept (t-6rbc): the leftover was provably always empty. It is now a
// RETIRED KEY that DROPS the row loudly (see `DesktopSection.parse`); don't
// re-add it as a silently-ignored one.
//
// A stray `type` / `match` / `apply` on a section (from the retired section-lens
// era) is IGNORED by decode — every section is a workspace cell — while
// `config --validate` flags it loudly (the strict schema's
// `additionalProperties: false`; facet's "typos fail visibly" rule).

import Foundation

/// The mac-desktop TYPE discriminator — `DesktopMeta.type` (`[desktop.N]
/// type = "workspace" | "isolate"`). NOT a section discriminator anymore (that
/// role ended with the section-lens retirement, t-ec9s). Raw values are the wire
/// spellings (lowercased on decode).
///
/// `isolate` was spelled `lens` until t-mqqw. The optical metaphor was a lie:
/// you look THROUGH an isolate desktop and it does not move what it images, but this desktop
/// tiles the matched windows and anchor-parks the rest — and leaving it un-parks
/// nothing. The runtime had already converged on the honest word on its own
/// (`IsolatePark` / `applyIsolatePark` / `isolateParked` / `facet query`'s
/// `parked`); the config vocabulary now agrees with it. A `type = "lens"` config
/// is a LOUD reject (`DesktopMeta.parse`), never a silent alias.
public enum DesktopType: String, Sendable, Equatable, CaseIterable {
    case workspace
    case isolate
}

/// One facet to set on a window matched by a `[[rule]]` adopt-rule — the typed
/// `apply` op. Deliberately a closed enum (not a raw dict) so consumers switch
/// over a fixed, exhaustive set. (The section-lens `apply` that also used this
/// was retired with section-lens, t-ec9s; `[[rule]]` is the sole authored user.)
public enum ApplyOp: Sendable, Equatable {
    /// Add a tag (additive, idempotent). The string is a normalized tag
    /// name (`TagName.normalized`), so it is reachable from the CLI.
    case addTag(String)
    /// Remove a tag — the inverse of `addTag`. No wire key: never authored.
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
        var rejected: [String] = []
        return list(from: value, rejectingTags: &rejected)
    }

    /// `list`, reporting the tag names it REFUSED (t-r5yz). A raw tag that fails
    /// `TagName` policy yields no op — so `tags = ["ok", "bad:tag"]` used to
    /// produce a rule that quietly applied one tag instead of two, and
    /// `tags = ["bad:tag"]` produced a rule with NO ops that was then dropped
    /// with a message blaming the missing `apply` key. Both lied by omission.
    static func list(from value: TOMLValue?,
                     rejectingTags rejected: inout [String]) -> [ApplyOp]
    {
        guard case .table(let t)? = value else { return [] }
        var ops: [ApplyOp] = []
        if case .string(let ws)? = t["workspace"], !ws.isEmpty {
            ops.append(.setWorkspace(ws))
        }
        if let tags = t["tags"]?.asStringArray {
            for raw in tags {
                if let name = TagName.normalized(raw) { ops.append(.addTag(name)) }
                else { rejected.append(raw) }
            }
        }
        if case .bool(let b)? = t["floating"] { ops.append(.setFloating(b)) }
        if case .bool(let b)? = t["sticky"]   { ops.append(.setSticky(b)) }
        if case .bool(let b)? = t["master"]   { ops.append(.setMaster(b)) }
        return ops
    }
}

/// One `[[desktop.N.section]]` table — a workspace SPATIAL cell. Order within a
/// mac desktop is config-declaration order (= tree display order). Since the
/// section-lens type was retired (t-ec9s), a section carries only a display
/// `label` and an optional `layout` seed. (The `unassigned` receptacle MARKER
/// went with the orphan concept — t-6rbc; see `parse`.)
public struct DesktopSection: Sendable, Equatable {
    /// Display header — an **optional** name (§A): `""` when unset. A non-empty
    /// label NAMES the workspace from config; an empty one leaves it UNNAMED
    /// (displayed by its 1-based index).
    public let label: String
    /// Per-section layout seed — drives the workspace's stateful tiling engine.
    /// An empty-string `layout` decodes as `nil` (no layout authored).
    public let layout: String?

    public init(label: String = "", layout: String? = nil) {
        self.label = label
        self.layout = layout
    }

    /// Parse one `[[desktop.N.section]]` row into a workspace-cell section.
    /// `label` (optional, §A) names the workspace; `layout` seeds its tiling
    /// engine. A stray `type` / `match` / `apply` (from the retired section-lens
    /// era) is IGNORED here — `config --validate` flags it via the strict schema.
    ///
    /// ## `unassigned` is a RETIRED KEY, and the row is DROPPED
    ///
    /// t-6rbc retired the orphan concept: nothing in facet could put a window in
    /// the lost-and-found receptacle, so it was a section that could only ever be
    /// empty — a permanent lie in the tree. Deleting the key alone would NOT have
    /// been safe: an unknown key is ignored, so a stale `unassigned = true` row
    /// would silently PROMOTE to an ordinary workspace cell, the desktop would
    /// gain a workspace, and the user's layout would change under them. Silence is
    /// the worst possible answer here, so the row is dropped — which reproduces
    /// today's effective substrate exactly, because `workspaceSubstrateSections`
    /// already filtered receptacles out of the workspace list.
    ///
    /// Detect `unassigned = false` too: it is just as retired, and letting it fall
    /// through would conjure the same phantom workspace by the back door.
    static func parse(fromTOMLRow t: [String: TOMLValue])
        -> (section: DesktopSection?, note: String?)
    {
        if case .bool? = t["unassigned"] {
            return (nil, "`unassigned` was retired (t-6rbc) — no window can ever "
                + "reach the lost-and-found receptacle, so it could only ever be an "
                + "empty section. DELETE this section block; keeping it would add a "
                + "workspace cell and change your layout")
        }
        let label: String = {
            if case .string(let s)? = t["label"] { return s } else { return "" }
        }()
        var layout: String? = nil
        if case .string(let l)? = t["layout"], !l.isEmpty { layout = l }
        return (DesktopSection(label: label, layout: layout), nil)
    }
}

/// A decoded `[[desktop.N.section]]` section WITH its raw-DOM origin (t-hdxb
/// B4). The bridge the snapshot writer needs to map a projected section id
/// (`section:<declOrder>:<label>`) back to the exact
/// `[[desktop.N.section]]` array-of-tables element to edit.
///
///   • `declOrder` — the section's position in the SURVIVING (post merge +
///     dedup) list, i.e. the SAME index `FilterProjection.project` mints ids
///     from. Not the raw file position.
///   • `headerName` — the RAW header spelling the section came from
///     (`desktop.1.section` / `desktop.01.section`); split on `.` it is the
///     array-of-tables PATH swift-toml-edit addresses.
///   • `rawOrdinal` — the section's 0-based index among blocks of THAT spelling,
///     which is exactly swift-toml-edit's array-of-tables ordinal for the path.
///
/// The divergence between `declOrder` and `rawOrdinal` (malformed rows dropped,
/// header spellings merged, duplicate labels dropped) is precisely why the
/// origin is TRACKED through the decode, not re-derived by index at write time.
public struct DesktopSectionOrigin: Sendable, Equatable {
    public let section: DesktopSection
    public let declOrder: Int
    public let headerName: String
    public let rawOrdinal: Int

    public init(section: DesktopSection, declOrder: Int,
                headerName: String, rawOrdinal: Int) {
        self.section = section
        self.declOrder = declOrder
        self.headerName = headerName
        self.rawOrdinal = rawOrdinal
    }
}
