// `FilterProjection` — turn the backend's `[Workspace]` into the pivot's
// unified `[FilterGroup]` overview surface (the section/lens model).
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
//     (more than live workspaces) emit no group + a diagnostic.
//   • type = lens — a saved filter. Its `match` is compiled and projected
//     over EVERY window (multi-match: a window in two lens sections appears
//     in both). `id = "section:<declOrder>:<label>"`,
//     `sourceWorkspaceIndex = nil`, `sectionType = .lens`.
//   • type = unassigned — DEFERRED (トミー 2026-06-17): under the current
//     catalog every managed window has a workspace, so the AND-defined
//     unassigned set is always empty (dead UI). The TYPE decodes (parse) but
//     the projection emits NO group for it yet; an "unplaced window" concept
//     trips it later.
//
// CRITICAL DEGRADE — by-workspace stays a first-class citizen: when no
// sections are configured for the mac desktop, each `Workspace` maps 1:1 to
// a `FilterGroup` (same windows, `sourceWorkspaceIndex = ws.index`,
// `sectionType = .workspace`). The caller gates on this so the default,
// section-less config renders byte-identically to today. CONVERGENCE: for a
// FIXED `[Workspace]`, a config of all-`workspace` sections produces the
// SAME groups (same ids/labels/windows/sourceWorkspaceIndex) as the
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
private struct ProjectedWindowFields: WindowFields {
    let window: Window
    let workspaceName: String

    func filterValue(_ field: String) -> String? {
        field == "workspace" ? workspaceName : window.filterValue(field)
    }
    func filterHas(_ field: String) -> Bool {
        field == "workspace" ? !workspaceName.isEmpty : window.filterHas(field)
    }
}

public enum FilterProjection {
    /// The projection result: the renderable groups plus loud-but-non-fatal
    /// diagnostics (parse-error carets / unknown-field warnings) for the
    /// caller to log. Pure value — testable without I/O.
    public struct Result: Equatable, Sendable {
        public let groups: [FilterGroup]
        public let diagnostics: [String]
        public init(groups: [FilterGroup], diagnostics: [String]) {
            self.groups = groups
            self.diagnostics = diagnostics
        }
    }

    /// Project `workspaces` through `sections`. Total — never throws.
    ///
    /// - `sections` empty → the by-workspace degrade: one `FilterGroup` per
    ///   workspace, in order, `sourceWorkspaceIndex = ws.index` (0-based),
    ///   `sectionType = .workspace`.
    /// - otherwise → one `FilterGroup` per `workspace` / `lens` section in
    ///   config-declaration order (= display order), with the per-type
    ///   semantics in the file header. `unassigned` is deferred (no group).
    ///   Extra live workspaces append at the tail of the workspace-section
    ///   run; surplus workspace sections + malformed lens matches are noted
    ///   in `diagnostics`.
    public static func project(workspaces: [Workspace],
                               sections: [DesktopSection]) -> Result {
        // Workspace sections map onto the live workspaces POSITIONALLY (k-th
        // workspace section ↔ workspaces[k]) — the backend already emits them
        // index-ascending, so array order == index order. The group's id /
        // sourceWorkspaceIndex come from `ws.index` (the 0-based WIRE index),
        // NOT the array position or the auto-name — so a workspace section's
        // implicit `workspace=<this>` resolves by index, never by a
        // (possibly-colliding) emoji label, and `--focus` / `--move-to` stay
        // correct. Array order (not a re-sort) keeps the degrade byte-
        // identical to today.
        func wsGroup(_ ws: Workspace) -> FilterGroup {
            FilterGroup(id: "ws:\(ws.index)", label: ws.name,
                        windows: ws.windows, sourceWorkspaceIndex: ws.index,
                        sectionType: .workspace)
        }

        // Degrade: by-workspace is a first-class citizen (byte-identical).
        guard !sections.isEmpty else {
            return Result(groups: workspaces.map(wsGroup), diagnostics: [])
        }

        var out: [FilterGroup] = []
        var diags: [String] = []
        var wsCursor = 0            // next live workspace to fill a workspace section
        var sawWorkspaceSection = false
        var insertExtrasAt = 0      // tail of the workspace-section run, in `out`

        for (declOrder, s) in sections.enumerated() {
            switch s.type {
            case .workspace:
                sawWorkspaceSection = true
                if wsCursor < workspaces.count {
                    out.append(wsGroup(workspaces[wsCursor]))
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
                        where filter.matches(ProjectedWindowFields(
                            window: w, workspaceName: ws.name)) {
                            matched.append(w)
                        }
                    }
                    out.append(FilterGroup(
                        id: "section:\(declOrder):\(s.label)", label: s.label,
                        windows: matched, sourceWorkspaceIndex: nil,
                        sectionType: .lens))
                }

            case .unassigned:
                continue   // deferred — the type decodes but emits no group
            }
        }

        // Extra live workspaces (dynamic `facet workspace --add`): append at
        // the tail of the workspace-section run, before any later lens
        // sections. Only when there IS a workspace-section run — a lens-only
        // sections list produces only lens groups (and the consumer never
        // routes lens-only configs here: isSectionModelActive is false, so it
        // falls back to the by-workspace degrade).
        if sawWorkspaceSection && wsCursor < workspaces.count {
            let extras = workspaces[wsCursor...].map(wsGroup)
            out.insert(contentsOf: extras, at: insertExtrasAt)
        }
        return Result(groups: out, diagnostics: diags)
    }
}
