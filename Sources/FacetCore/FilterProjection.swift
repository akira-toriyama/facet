// `FilterProjection` — turn the backend's `[Workspace]` into the pivot's
// unified `[ProjectedSection]` overview surface (the section/lens model).
//
// This is the read-path inversion at the heart of the pivot: instead of
// "windows live in workspaces, views render workspaces", a view renders the
// config's `[[desktop.N.section]]` array, where a window shows up in EVERY
// section it belongs to (multi-match). The projection is PURE and backend-
// neutral so it is unit-tested in `FacetCoreTests`; the production consumer
// (the tree) lands in PR5.
//
// PER-TYPE SEMANTICS (the section/lens model body):
//   • type = workspace — the spatial substrate. IMPLICIT match resolved by
//     INDEX, not name (a workspace's name is its optional `label` / "" when
//     unnamed, so keying on index avoids any name-collision ambiguity): the k-th workspace
//     section maps onto the k-th live workspace (the backend emits them
//     index-ascending) and takes its windows VERBATIM (no filter eval). The
//     id / sourceWorkspaceIndex come from `ws.index` (the wire index), not
//     the array position. `id = "ws:<index>"`,
//     `sourceWorkspaceIndex = <index>`, `sectionType = .workspace`. Count
//     divergence both ways: extra live workspaces (beyond the workspace-
//     section count) append at the TAIL of the workspace-section RUN (the
//     dynamic `facet workspace --add` case); surplus workspace sections
//     (more than live workspaces) emit no section + a diagnostic.
//   • type = lens — a saved filter. Its `match` is compiled and projected
//     over EVERY window (multi-match: a window in two lens sections appears
//     in both). `id = "section:<declOrder>:<label>"`,
//     `sourceWorkspaceIndex = nil`, `sectionType = .lens`.
//   • type = unassigned — PROJECTED (§G): the opt-in lost-and-found
//     receptacle. When present, it collects the LEFTOVER (universe − shown):
//     the windows that landed in NO emitted workspace / lens section — the
//     genuinely invisible windows it rescues. `id = "unassigned:<declOrder>"`,
//     `sourceWorkspaceIndex = nil`, `sectionType = .unassigned`. Only the
//     FIRST unassigned section emits; extras warn (the leftover set is
//     singular, so a second receptacle is always empty).
//
// CRITICAL DEGRADE — by-workspace stays a first-class citizen: when no
// sections are configured for the mac desktop, each `Workspace` maps 1:1 to
// a `ProjectedSection` (same windows, `sourceWorkspaceIndex = ws.index`,
// `sectionType = .workspace`). The caller gates on this so the default,
// section-less config renders byte-identically to today. CONVERGENCE: for a
// FIXED `[Workspace]`, a config of all-`workspace` sections produces the
// SAME sections (same ids/labels/windows/sourceWorkspaceIndex) as the
// section-less degrade — by-workspace and the section model agree.
//
// Loud-but-NON-FATAL, matching the `facet filter` philosophy (see
// `QueryFilter`): a lens section whose `match` fails to parse is SKIPPED
// (omitted from the projection) and its caret is collected in `diagnostics`
// for the caller to log; it never aborts the projection. An unknown field in
// a (valid) match no-matches in the evaluator and adds a typo warning.
//
// Still PURE + backend-neutral (unit-tested in `FacetCoreTests`); the first
// production consumer is the tree (PR5), gated on `isSectionModelActive`.

/// Overlays the containing workspace's NAME onto a `Window` for filter
/// evaluation. `Window` alone resolves `workspace` to no-match (it doesn't
/// carry its workspace); the projection knows the workspace at the seam and
/// supplies it here, so a section `match='workspace=Dev'` resolves correctly.
/// `desktop` stays no-match: sections are already scoped per mac desktop by
/// the `[[desktop.N.section]]` config, so matching on `desktop=` is redundant.
///
/// The seam-overlay every lens-`match` evaluation runs through, wrapped by the
/// single `LensMembership.matches` predicate. A lens is a pure VIEW (t-0021):
/// `FilterProjection` is the ONE path that decides a window's lens membership,
/// for tree/grid/rail alike — there is no separate hide/park path to keep in
/// sync. Internal (not file-private) so `LensMembership` (same module) can
/// construct it; the public predicate exposes only `Window` + name + filter.
struct ProjectedWindowFields: WindowFields {
    let window: Window
    /// The containing workspace's name, or `nil` when the window has NO
    /// workspace assignment (迷子 / orphan). `nil` (assignment absent) is
    /// distinct from `""` (assigned to an unnamed workspace — "show the
    /// number"): only `nil` makes `not workspace` match, so a `not workspace`
    /// lens catches orphans WITHOUT also catching windows
    /// in an unnamed workspace. Presence is keyed off the ASSIGNMENT (`Int?`
    /// nil vs not), never the display name — which is WHY an unnamed workspace
    /// (name `""`, but assigned) does not collide with an orphan (`ws=nil`) in
    /// `not workspace` / bare `workspace` filter logic.
    let workspaceName: String?

    func filterValue(_ field: String) -> String? {
        field == "workspace" ? workspaceName : window.filterValue(field)
    }
    func filterHas(_ field: String) -> Bool {
        field == "workspace" ? (workspaceName != nil) : window.filterHas(field)
    }
}

public enum FilterProjection {
    /// The projection result: the renderable sections plus loud-but-non-fatal
    /// diagnostics (parse-error carets / unknown-field warnings) for the
    /// caller to log. Pure value — testable without I/O.
    public struct Result: Equatable, Sendable {
        public let sections: [ProjectedSection]
        public let diagnostics: [String]
        public init(sections: [ProjectedSection], diagnostics: [String]) {
            self.sections = sections
            self.diagnostics = diagnostics
        }
    }

    /// Project `workspaces` through `sections`. Total — never throws.
    ///
    /// - `sections` empty → the by-workspace degrade: one `ProjectedSection` per
    ///   workspace, in order, `sourceWorkspaceIndex = ws.index` (0-based),
    ///   `sectionType = .workspace`.
    /// - otherwise → one `ProjectedSection` per `workspace` / `lens` section in
    ///   config-declaration order (= display order), with the per-type
    ///   semantics in the file header. An `unassigned` section (§G) emits the
    ///   leftover receptacle (universe − shown); only the first emits, extras
    ///   warn. Extra live workspaces append at the tail of the workspace-
    ///   section run; surplus workspace sections + malformed lens matches are
    ///   noted in `diagnostics`.
    ///
    /// `orphans` (EX-3 迷子): windows that belong to NO workspace
    /// (`WindowSlot.workspace == nil`), so the backend's `[Workspace]` snapshot
    /// can't carry them. They are evaluated against LENS sections ONLY, with an
    /// assignment-absent workspace (`inWorkspaceNamed: nil`) so `not workspace`
    /// catches them — the 迷子 receptacle. They are NEVER added to a workspace
    /// section (an orphan is in no workspace) and are appended AFTER the
    /// workspace-resident matches in each lens. No dedup is needed: an orphan
    /// appears in no `workspaces[].windows`, so it can't double-match. Default
    /// `[]` keeps every non-orphan caller byte-identical. This closes the GAP
    /// where an orphan rendered in NO tree/grid/rail section even though the
    /// activation path gathered it on-screen (display ↔ gather disagreement).
    public static func project(workspaces: [Workspace],
                               sections: [DesktopSection],
                               orphans: [Window] = []) -> Result {
        // Workspace sections map onto the live workspaces POSITIONALLY (k-th
        // workspace section ↔ workspaces[k]) — the backend already emits them
        // index-ascending, so array order == index order. The section's id /
        // sourceWorkspaceIndex come from `ws.index` (the 0-based WIRE index),
        // NOT the array position or the label — so a workspace section's
        // implicit `workspace=<this>` resolves by index, never by a
        // (possibly-empty / non-unique) label, and `--focus` / `--move-to` stay
        // correct. Array order (not a re-sort) keeps the degrade byte-
        // identical to today.
        // Isolate-parked windows (t-c6fm) stay in place in their section — the
        // real screen declutters (only the active lens's windows are on-screen),
        // but the tree is a filter-inventory, not a screen mirror: a window shows
        // in every section its match satisfies, parked or not (consistent with a
        // non-active workspace's windows, which are also parked but shown normally).
        func wsSection(_ ws: Workspace) -> ProjectedSection {
            ProjectedSection(id: "ws:\(ws.index)", label: ws.name,
                        windows: ws.windows,
                        sourceWorkspaceIndex: ws.index,
                        sectionType: .workspace)
        }

        // Degrade: by-workspace is a first-class citizen (byte-identical).
        guard !sections.isEmpty else {
            return Result(sections: workspaces.map(wsSection), diagnostics: [])
        }

        var out: [ProjectedSection] = []
        var diags: [String] = []
        var wsCursor = 0            // next live workspace to fill a workspace section
        var sawWorkspaceSection = false
        var insertExtrasAt = 0      // tail of the workspace-section run, in `out`
        var sawUnassigned = false   // §G: only the FIRST unassigned section emits

        for (declOrder, s) in sections.enumerated() {
            // W2.6 (t-wrd2): the lost-and-found receptacle is an `unassigned`
            // MARKER, not a `type` — checked FIRST so it works on a workspace OR
            // lens section anywhere in the list. Emit a PLACEHOLDER at its
            // declaration position (empty `.windows`); Pass 2 below fills it with
            // the leftover once every workspace + lens section's membership is
            // known. Only the FIRST receptacle is shown — extras are loud-but-
            // non-fatal (the "leftover" set is singular, so a second receptacle
            // would always be empty). The section's `type` is projection-
            // irrelevant here.
            if s.unassigned {
                if sawUnassigned {
                    diags.append("config: unassigned section #\(declOrder + 1) "
                        + "ignored (only the first unassigned section is shown)")
                    continue
                }
                sawUnassigned = true
                out.append(ProjectedSection(
                    id: "unassigned:\(declOrder)", label: s.label, windows: [],
                    sourceWorkspaceIndex: nil, sectionType: .unassigned))
                continue
            }
            switch s.type {
            case .workspace:
                sawWorkspaceSection = true
                if wsCursor < workspaces.count {
                    out.append(wsSection(workspaces[wsCursor]))
                    wsCursor += 1
                    insertExtrasAt = out.count
                } else {
                    diags.append("config: workspace section #\(declOrder + 1) "
                        + "has no matching live workspace (more workspace "
                        + "sections than workspaces)")
                }

            case .lens:
                switch FacetFilter.parse(s.match) {
                case .failure(let error):
                    diags.append("config: section \"\(s.label)\" match: "
                        + error.caret(in: s.match))
                case .success(let filter):
                    let unknown = filter.fieldsReferenced()
                        .subtracting(FacetFilter.knownFields).sorted()
                    if !unknown.isEmpty {
                        diags.append("config: section \"\(s.label)\" match "
                            + "references unknown field(s): "
                            + unknown.joined(separator: ", "))
                    }
                    var matched: [Window] = []
                    for ws in workspaces {
                        for w in ws.windows
                        // A lens shows EVERY window its match satisfies (t-c6fm):
                        // an isolate-parked window that matches this lens still
                        // shows here (parked = a real-screen operation, orthogonal
                        // to the display filter — same as a non-active workspace's
                        // parked windows, which show normally).
                        where LensMembership.matches(
                            w, inWorkspaceNamed: ws.name, filter: filter) {
                            matched.append(w)
                        }
                    }
                    // EX-3 迷子: orphans (in no workspace) match against this
                    // lens with `inWorkspaceNamed: nil`, so `not workspace`
                    // catches them (the receptacle) and a content lens catches
                    // them by their own fields. Appended AFTER the workspace
                    // matches; no dedup (an orphan is in no `ws.windows`).
                    for w in orphans
                    where LensMembership.matches(
                        w, inWorkspaceNamed: nil, filter: filter) {
                        matched.append(w)
                    }
                    out.append(ProjectedSection(
                        id: "section:\(declOrder):\(s.label)", label: s.label,
                        windows: matched, sourceWorkspaceIndex: nil,
                        sectionType: .lens))
                }
            }
        }

        // Extra live workspaces (dynamic `facet workspace --add`): append at
        // the tail of the workspace-section run, before any later lens
        // sections. Only when there IS a workspace-section run.
        //
        // N6 (t-wrd2): a lens-only `sections` list produces only lens sections
        // and NO workspace tail. Pre-board this was unreachable (the consumer
        // routed lens-only configs only when `isSectionModelActive` was false →
        // by-workspace degrade), but under the BOARD model a SELECTED lens board
        // routes a lens-only list here WITH `isSectionModelActive == true` (a
        // workspace board exists elsewhere on the desktop). The intended
        // semantics: a lens board is a FILTERED view — a workspace window that
        // matches no lens on the selected board is shown only if the board
        // declares an `unassigned` receptacle (W2.6); otherwise it is hidden
        // until the user switches back to a workspace board (the window stays
        // live, never lost). `BoardLensProjectionTests` pins this.
        if sawWorkspaceSection && wsCursor < workspaces.count {
            let extras = workspaces[wsCursor...].map(wsSection)
            out.insert(contentsOf: extras, at: insertExtrasAt)
        }

        // §G Pass 2 — fill the unassigned receptacle with the LEFTOVER: the
        // windows that landed in NO emitted section. `universe` = every
        // workspace window + the orphans (deduped by id, in that order);
        // `shown` = the union of every emitted workspace / lens section's
        // windows (the placeholder is still empty here, so it contributes
        // nothing). `leftover` = universe − shown, in universe order. A
        // workspace window is always shown in its own workspace section, so in
        // practice the leftover is the orphans no lens caught — the genuinely
        // invisible windows the receptacle rescues.
        if sawUnassigned {
            var shown = Set<WindowID>()
            for sec in out where sec.sectionType != .unassigned {
                for w in sec.windows { shown.insert(w.id) }
            }
            var seen = Set<WindowID>()
            var leftover: [Window] = []
            for w in workspaces.flatMap(\.windows) + orphans {
                guard seen.insert(w.id).inserted else { continue }   // dedup universe
                if !shown.contains(w.id) { leftover.append(w) }
            }
            out = out.map { sec in
                guard sec.sectionType == .unassigned else { return sec }
                return ProjectedSection(id: sec.id, label: sec.label,
                                        windows: leftover, sourceWorkspaceIndex: nil,
                                        sectionType: .unassigned)
            }
        }
        return Result(sections: out, diagnostics: diags)
    }
}

/// §E: overlay session-only DISPLAY-LABEL overrides onto a projected section
/// list. Pure + backend-neutral so it is unit-tested in `FacetCoreTests` and
/// the production seam (`Controller.apply()`) calls it once before the reorder.
///
/// lens AND `type="unassigned"` sections are relabeled (§G) — a workspace
/// section's display name comes from the catalog (`workspaceNames`), so a
/// workspace rename routes to `renameWorkspace` and never reaches here (any
/// workspace-id key in `overrides` is ignored). The map is keyed by the
/// section's STABLE id (`"section:<declOrder>:<label>"` /
/// `"unassigned:<declOrder>"`); an absent key leaves the section untouched, so
/// an orphaned override (after a config edit) is a no-op. The id is NEVER
/// changed — only the display `label` — so identity (used for `--focus index:N`
/// routing + the active-lens highlight) is invariant.
///
/// Empty-value semantics are the CALLER's job: a "revert to config" is a
/// DELETED key, not a stored `""`, so this function maps only the keys it is
/// handed (a stored `""` would, by contract, blank the header — but the caller
/// never stores one).
public func applyLabelOverrides(_ sections: [ProjectedSection],
                               to overrides: [String: String]) -> [ProjectedSection] {
    guard !overrides.isEmpty else { return sections }
    return sections.map { ps in
        // §E + §G: lens AND unassigned sections carry a session-only display
        // override (a workspace label lives in the catalog). The id is frozen.
        guard ps.sectionType == .lens || ps.sectionType == .unassigned,
              let newLabel = overrides[ps.id] else {
            return ps
        }
        return ProjectedSection(id: ps.id, label: newLabel, windows: ps.windows,
                                sourceWorkspaceIndex: ps.sourceWorkspaceIndex,
                                sectionType: ps.sectionType)
    }
}

/// t-0020: overlay session-only `match` overrides onto a CONFIG section list —
/// the seam-TWIN of `applyLabelOverrides`, with one crucial difference: it runs
/// on the projection INPUT (`[DesktopSection]`) BEFORE `FilterProjection.project()`,
/// not on its output. Changing a lens's `match` changes which windows it catches,
/// so the override must mutate what `project()` reads, not what it produced. Pure
/// + backend-neutral so it is unit-tested in `FacetCoreTests`; the production seam
/// (`Controller.apply()`) calls it once, just before `project()`.
///
/// Only a `.lens` section that is NOT an `unassigned` receptacle is overridable:
/// a workspace is the exclusive spatial substrate (no match — its windows come
/// VERBATIM), and an `unassigned` receptacle is leftover-by-subtraction (no match
/// either). The map is keyed by the SAME stable id `project()` mints for a lens —
/// `"section:<declOrder>:<label>"`, where `declOrder` is the section's enumerated
/// position (this function and `project()` enumerate the SAME array, so the keys
/// line up exactly). The id is built from `label`, never `match`, so swapping the
/// match leaves the section's identity invariant — the override key keeps matching
/// after the swap, and `--focus index:N` / the active-lens highlight stay correct.
///
/// Empty-value semantics are the CALLER's job: a "revert to config" is a DELETED
/// key, not a stored `""` (an empty predicate parses to `.all` = match-everything,
/// a legitimate value). This maps only the keys it is handed, and stores the new
/// predicate VERBATIM — validation + normalization happen at the caller's store
/// site (mirroring the `applyLabelOverrides` contract).
public func applyMatchOverrides(_ sections: [DesktopSection],
                               to overrides: [String: String]) -> [DesktopSection] {
    guard !overrides.isEmpty else { return sections }
    return sections.enumerated().map { (declOrder, s) in
        // Only a pure lens is match-overridable; the key is the id `project()`
        // mints for that lens at this declaration position. `unassigned` is
        // checked FIRST (mirroring `project()`), so a lens-typed receptacle is
        // excluded even if its section-shaped key were present.
        guard s.type == .lens, !s.unassigned,
              let newMatch = overrides["section:\(declOrder):\(s.label)"] else {
            return s
        }
        return DesktopSection(type: s.type, label: s.label, match: newMatch,
                              apply: s.apply, layout: s.layout,
                              unassigned: s.unassigned)
    }
}
