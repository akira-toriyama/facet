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
//     INDEX, not name (the auto-name is a pure function of index, so keying
//     on index avoids any emoji-collision ambiguity): the k-th workspace
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
//   • type = unassigned — DEFERRED (トミー 2026-06-17): under the current
//     catalog every managed window has a workspace, so the AND-defined
//     unassigned set is always empty (dead UI). The TYPE decodes (parse) but
//     the projection emits NO section for it yet; an "unplaced window" concept
//     trips it later.
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
/// single `LensMembership.matches` predicate that `FilterProjection` (tree) and
/// the Phase-1 real-hide park path both share — so a window's lens membership is
/// decided identically on the display and hide paths (grid/rail then drop the
/// parked windows via the snapshot's `Window.isLensParked` flag). Internal (not
/// file-private) so `LensMembership` (same module) can construct it; the public
/// predicate exposes only `Window` + name + filter.
struct ProjectedWindowFields: WindowFields {
    let window: Window
    /// The containing workspace's name, or `nil` when the window has NO
    /// workspace assignment (EX-3 迷子 / orphan). `nil` (assignment absent) is
    /// distinct from `""` (assigned to an unnamed workspace — "show the
    /// number"): only `nil` makes `not workspace` match, so the 迷子 receptacle
    /// (`match='not workspace'`) catches orphans WITHOUT also catching windows
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
    ///   semantics in the file header. `unassigned` is deferred (no section).
    ///   Extra live workspaces append at the tail of the workspace-section
    ///   run; surplus workspace sections + malformed lens matches are noted
    ///   in `diagnostics`.
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
        // NOT the array position or the auto-name — so a workspace section's
        // implicit `workspace=<this>` resolves by index, never by a
        // (possibly-colliding) emoji label, and `--focus` / `--move-to` stay
        // correct. Array order (not a re-sort) keeps the degrade byte-
        // identical to today.
        func wsSection(_ ws: Workspace) -> ProjectedSection {
            ProjectedSection(id: "ws:\(ws.index)", label: ws.name,
                        windows: ws.windows, sourceWorkspaceIndex: ws.index,
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

        for (declOrder, s) in sections.enumerated() {
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

            case .unassigned:
                continue   // deferred — the type decodes but emits no section
            }
        }

        // Extra live workspaces (dynamic `facet workspace --add`): append at
        // the tail of the workspace-section run, before any later lens
        // sections. Only when there IS a workspace-section run — a lens-only
        // sections list produces only lens sections (and the consumer never
        // routes lens-only configs here: isSectionModelActive is false, so it
        // falls back to the by-workspace degrade).
        if sawWorkspaceSection && wsCursor < workspaces.count {
            let extras = workspaces[wsCursor...].map(wsSection)
            out.insert(contentsOf: extras, at: insertExtrasAt)
        }
        return Result(sections: out, diagnostics: diags)
    }
}
