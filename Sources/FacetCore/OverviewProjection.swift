// `OverviewProjection` — narrow the grid/rail overview to the active lens.
//
// The pivot's grid/rail surfaces render the SPATIAL substrate: one cell per
// workspace, always (`type="lens"` / `type="unassigned"` sections never make
// a cell — "grid/rail に出せる ⟺ workspace に乗ってる"). A lens only NARROWS
// what's shown inside those cells; it never re-bundles or drops a cell. So
// this projection keeps the workspace set 1:1 (same count / order / index /
// name / layout) and only filters each workspace's `windows` to the ones the
// active lens's `match` selects. The grid/rail cell count is therefore
// INVARIANT under a lens (トミー 2026-06-17: lens = SQL VIEW, orthogonal to
// the workspace axis).
//
// Pure + backend-neutral (unit-tested in `FacetCoreTests`); the Controller
// derives a visible-window-id set from the result and feeds it to whichever
// overview is open (PR7). The landing gate (`OverviewPendingDrop.landed`)
// keeps reading the UNFILTERED `[Workspace]`, never this result — a window
// moved out of the lens's selection would otherwise never appear in the
// filtered destination and the drop would stay stuck forever.
//
// DEGRADE — no active lens (`match == nil`): the workspaces pass through
// VERBATIM (every window visible), so the section-less / lens-inactive
// overview renders byte-identically to today.
//
// Loud-but-NON-FATAL (the `facet filter` philosophy, see `FilterProjection`):
// a `match` that fails to parse, or references an unknown field, does NOT
// empty the overview — the workspaces pass through verbatim (everything
// visible) and the reason is collected in `diagnostics` for the caller to
// log. A broken filter showing everything is far less alarming than an
// all-empty overview that looks like facet lost every window.

public enum OverviewProjection {
    /// The filtered workspaces plus loud-but-non-fatal diagnostics (parse-
    /// error caret / unknown-field warning) for the caller to log. Pure
    /// value — testable without I/O. (Not `Equatable`: `Workspace` isn't —
    /// callers diff `diagnostics` (`[String]`) and `windows.map(\.id)`.)
    public struct Result: Sendable {
        public let workspaces: [Workspace]
        public let diagnostics: [String]
        public init(workspaces: [Workspace], diagnostics: [String]) {
            self.workspaces = workspaces
            self.diagnostics = diagnostics
        }
    }

    /// Narrow each workspace's windows to those matching the active lens's
    /// `match`. Total — never throws.
    ///
    /// - `match == nil` (or empty) → the degrade: workspaces returned
    ///   verbatim, no diagnostics (no active lens narrows the overview).
    /// - malformed `match` → verbatim + a parse-error diagnostic.
    /// - valid `match` → every workspace kept (same index / name / isActive /
    ///   layoutMode), its `windows` filtered to the matches. A workspace with
    ///   no matches keeps its (now-empty) cell. An unknown field referenced in
    ///   a valid `match` no-matches in the evaluator and adds a typo warning.
    public static func filterWorkspaces(_ workspaces: [Workspace],
                                        byLensMatch match: String?) -> Result {
        guard let match, !match.isEmpty else {
            return Result(workspaces: workspaces, diagnostics: [])
        }
        switch FacetFilter.parse(match) {
        case .failure(let error):
            // Broken filter shows everything (never an all-empty overview).
            return Result(workspaces: workspaces,
                          diagnostics: ["lens match: " + error.caret(in: match)])
        case .success(let filter):
            var diags: [String] = []
            let unknown = filter.fieldsReferenced()
                .subtracting(FacetFilter.knownFields).sorted()
            if !unknown.isEmpty {
                diags.append("lens match references unknown field(s): "
                    + unknown.joined(separator: ", "))
            }
            let filtered = workspaces.map { ws in
                Workspace(index: ws.index, name: ws.name, isActive: ws.isActive,
                          layoutMode: ws.layoutMode,
                          windows: ws.windows.filter {
                              LensMembership.matches(
                                  $0, inWorkspaceNamed: ws.name, filter: filter)
                          })
            }
            return Result(workspaces: filtered, diagnostics: diags)
        }
    }
}
