// `FilterProjection` — turn the backend's `[Workspace]` into the pivot's
// unified `[FilterGroup]` overview surface (#284 PR#6).
//
// This is the read-path inversion at the heart of the pivot: instead of
// "windows live in workspaces, views render workspaces", a view renders
// GROUPS, where each group is a `[[desktop.N.group]]` `match` filter
// projected over the live windows (a window shows up in EVERY group it
// matches — multi-match). The projection is PURE and backend-neutral so it
// is unit-tested in `FacetCoreTests`; the consumer (Controller, cliQueue
// side) lands in PR#8.
//
// CRITICAL DEGRADE — by-workspace stays a first-class citizen: when no
// groups are configured for the mac desktop, each `Workspace` maps 1:1 to a
// `FilterGroup` (same windows, `sourceWorkspaceIndex = ws.index`). The
// caller (PR#8) gates on this so the default, group-less config renders
// byte-identically to today.
//
// Loud-but-NON-FATAL, matching the `facet filter` philosophy (see
// `QueryFilter`): a group whose `match` fails to parse is SKIPPED (omitted
// from the projection) and its caret is collected in `diagnostics` for the
// caller to log; it never aborts the projection. An unknown field in a
// (valid) match no-matches in the evaluator and adds a typo warning.

/// Overlays the containing workspace's NAME onto a `Window` for filter
/// evaluation. `Window` alone resolves `workspace` to no-match (it doesn't
/// carry its workspace); the projection knows the workspace at the seam and
/// supplies it here, so a group `match='workspace=Dev'` resolves correctly.
/// `desktop` stays no-match: groups are already scoped per mac desktop by
/// the `[[desktop.N.group]]` config, so matching on `desktop=` is redundant.
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

    /// Project `workspaces` through `groups`. Total — never throws.
    ///
    /// - `groups` empty → the by-workspace degrade: one `FilterGroup` per
    ///   workspace, in order, `sourceWorkspaceIndex = ws.index` (0-based).
    /// - otherwise → one `FilterGroup` per group in config-declaration order
    ///   (= display order), each holding every window whose `match` it
    ///   satisfies (multi-match across groups). A group with a malformed
    ///   `match` is skipped and noted in `diagnostics`.
    public static func project(workspaces: [Workspace],
                               groups: [DesktopGroup]) -> Result {
        // Degrade: by-workspace is a first-class citizen (byte-identical).
        guard !groups.isEmpty else {
            let gs = workspaces.map { ws in
                FilterGroup(id: "ws:\(ws.index)", label: ws.name,
                            windows: ws.windows, sourceWorkspaceIndex: ws.index)
            }
            return Result(groups: gs, diagnostics: [])
        }

        var out: [FilterGroup] = []
        var diags: [String] = []
        for (declOrder, g) in groups.enumerated() {
            switch FacetFilter.parse(g.match) {
            case .failure(let error):
                // Skip the group, keep the caret for the caller to log loud.
                diags.append("config: group \"\(g.label)\" match: "
                    + error.caret(in: g.match))
            case .success(let filter):
                let unknown = filter.fieldsReferenced()
                    .subtracting(FacetFilter.knownFields).sorted()
                if !unknown.isEmpty {
                    diags.append("config: group \"\(g.label)\" match references "
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
                    id: "group:\(declOrder):\(g.label)", label: g.label,
                    windows: matched, sourceWorkspaceIndex: nil))
            }
        }
        return Result(groups: out, diagnostics: diags)
    }
}
