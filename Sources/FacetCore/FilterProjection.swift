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
// PR1 SCOPE — this is the behaviour-preserving SIGNATURE follow-on of the
// `DesktopGroup` → `DesktopSection` reshape (the body's real per-type
// semantics — workspace implicit match, unassigned AND-set — land in PR3).
// For now a section is projected only when it carries a `match` (a `lens`
// section), exactly as a group did; `workspace` / `unassigned` sections
// carry no `match` and contribute nothing here.
//
// CRITICAL DEGRADE — by-workspace stays a first-class citizen: when no
// sections are configured for the mac desktop, each `Workspace` maps 1:1 to
// a `FilterGroup` (same windows, `sourceWorkspaceIndex = ws.index`). The
// caller gates on this so the default, section-less config renders byte-
// identically to today.
//
// Loud-but-NON-FATAL, matching the `facet filter` philosophy (see
// `QueryFilter`): a section whose `match` fails to parse is SKIPPED (omitted
// from the projection) and its caret is collected in `diagnostics` for the
// caller to log; it never aborts the projection. An unknown field in a
// (valid) match no-matches in the evaluator and adds a typo warning.

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
    ///   workspace, in order, `sourceWorkspaceIndex = ws.index` (0-based).
    /// - otherwise → one `FilterGroup` per MATCH-bearing section in config-
    ///   declaration order (= display order), each holding every window whose
    ///   `match` it satisfies (multi-match across sections). A section with a
    ///   malformed `match` is skipped and noted in `diagnostics`.
    ///
    /// PR1: only `match`-bearing (`lens`) sections project; `workspace` /
    /// `unassigned` sections (no `match`) contribute nothing — their real
    /// per-type semantics land in PR3. The declaration index (`declOrder`)
    /// still counts every section, so a section's id stays stable as the
    /// body grows.
    public static func project(workspaces: [Workspace],
                               sections: [DesktopSection]) -> Result {
        // Degrade: by-workspace is a first-class citizen (byte-identical).
        guard !sections.isEmpty else {
            let gs = workspaces.map { ws in
                FilterGroup(id: "ws:\(ws.index)", label: ws.name,
                            windows: ws.windows, sourceWorkspaceIndex: ws.index)
            }
            return Result(groups: gs, diagnostics: [])
        }

        var out: [FilterGroup] = []
        var diags: [String] = []
        for (declOrder, s) in sections.enumerated() {
            guard !s.match.isEmpty else { continue }  // PR1: lens sections only
            switch FacetFilter.parse(s.match) {
            case .failure(let error):
                // Skip the section, keep the caret for the caller to log loud.
                diags.append("config: section \"\(s.label)\" match: "
                    + error.caret(in: s.match))
            case .success(let filter):
                let unknown = filter.fieldsReferenced()
                    .subtracting(FacetFilter.knownFields).sorted()
                if !unknown.isEmpty {
                    diags.append("config: section \"\(s.label)\" match references "
                        + "unknown field(s): \(unknown.joined(separator: ", "))")
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
                    windows: matched, sourceWorkspaceIndex: nil))
            }
        }
        return Result(groups: out, diagnostics: diags)
    }
}
