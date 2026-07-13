// `FilterProjection` — turn the backend's `[Workspace]` into the unified
// `[ProjectedSection]` list the views render (the section model).
//
// This is the read-path inversion at the heart of the pivot: instead of
// "windows live in workspaces, views render workspaces", a view renders the
// config's `[[desktop.N.section]]` array. The projection is PURE and backend-
// neutral so it is unit-tested in `FacetCoreTests`; the production consumers
// (tree / grid / rail) go through it, gated on `isSectionModelActive`.
//
// SECTION SEMANTICS — the sections are DISJOINT: since the section-lens was
// retired (t-ec9s) no section carries a `match`, so no window can show in two
// sections at once.
//   • a workspace SPATIAL cell — EVERY authored section, with no exception
//     (t-6rbc retired the `unassigned` receptacle, the last kind that was not
//     one; see `project`).
//     IMPLICIT match resolved by INDEX, not name (a workspace's name is its
//     optional `label` / "" when unnamed, so keying on index avoids any
//     name-collision ambiguity): the k-th workspace section maps onto the k-th
//     live workspace (the backend emits them index-ascending) and takes its
//     windows VERBATIM (no filter eval). The id / sourceWorkspaceIndex come
//     from `ws.index` (the wire index), not the array position.
//     `id = "ws:<index>"`, `sourceWorkspaceIndex = <index>`,
//     `sectionType = .workspace`. Count divergence both ways: extra live
//     workspaces (beyond the workspace-section count) append at the TAIL of
//     the workspace-section RUN (the dynamic `facet workspace --add` case);
//     surplus workspace sections (more than live workspaces) emit no section
//     + a diagnostic.
//
// A `.matched` section is still MINTED here — but only by `projectIsolateDesktop`
// (below), the dedicated route for a `[desktop.N] type=isolate` mac desktop,
// which synthesizes its 1–2 sections straight from the desktop's `match`. It
// never comes out of `project()`: there is no matched section to author.
//
// CRITICAL DEGRADE — by-workspace stays a first-class citizen: when no
// sections are configured for the mac desktop, each `Workspace` maps 1:1 to
// a `ProjectedSection` (same windows, `sourceWorkspaceIndex = ws.index`,
// `sectionType = .workspace`). The caller gates on this so the default,
// section-less config renders byte-identically to today. CONVERGENCE: for a
// FIXED `[Workspace]`, a config of workspace sections produces the SAME
// sections (same ids/labels/windows/sourceWorkspaceIndex) as the section-less
// degrade — by-workspace and the section model agree.
//
// Loud-but-NON-FATAL, matching the `facet filter` philosophy (see
// `QueryFilter`): an isolate desktop's `match` that fails to parse matches
// NOTHING (the matched section comes out empty) and its caret is collected in
// `diagnostics` for the caller to log; it never aborts the projection. An
// unknown field in a (valid) match no-matches in the evaluator and adds a
// typo warning.

/// Overlays the containing workspace's NAME onto a `Window` for filter
/// evaluation. `Window` alone resolves `workspace` to no-match (it doesn't
/// carry its workspace); the projection knows the workspace at the seam and
/// supplies it here, so an isolate desktop's `match='workspace=Dev'` resolves
/// correctly. `desktop` stays no-match: an isolate desktop's `match` is already
/// scoped to the mac desktop it is declared on, so matching on `desktop=` is
/// redundant.
///
/// The seam-overlay every lens-`match` evaluation runs through, wrapped by the
/// single `IsolateMembership.matches` predicate — the ONE membership rule shared
/// by the tree projection (`projectIsolateDesktop`) and the real-screen park
/// (`IsolatePark.parkSet`), so what an isolate desktop SHOWS and what it PARKS
/// can't drift apart. Internal (not file-private) so `IsolateMembership` (same
/// module) can construct it; the public predicate exposes only `Window` +
/// name + filter.
struct ProjectedWindowFields: WindowFields {
    let window: Window
    /// The containing workspace's name. Presence (`nil` vs not) is what `not
    /// workspace` / bare `workspace` key off, and it is distinct from `""`
    /// (ASSIGNED to an unnamed workspace — "show the number"), so an unnamed
    /// workspace never falls out of a bare `workspace` filter.
    ///
    /// `nil` used to mean 迷子 (a window in NO workspace). t-6rbc retired that:
    /// every managed window is in exactly one workspace, and every production
    /// call site passes a real name — so nothing reaches `nil` and `not
    /// workspace` matches nothing. Optional survives only as the total form of
    /// `WindowFields.filterHas`.
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

    /// Project `workspaces` through `sections` — one `ProjectedSection` per LIVE
    /// workspace, in order, `sourceWorkspaceIndex = ws.index` (0-based),
    /// `sectionType = .workspace`. Total; never throws.
    ///
    /// ## Why `sections` only produces a diagnostic now
    ///
    /// Every `[[desktop.N.section]]` is a workspace SPATIAL cell — t-ec9s retired
    /// the section-lens, and t-6rbc retired the `unassigned` receptacle, the last
    /// section kind that was NOT a workspace. So the sections no longer *shape*
    /// this projection at all: they already shaped `effectiveWorkspaceList` (the
    /// workspace COUNT, each one's label and layout seed), and what arrives here
    /// is the result. Mapping the k-th section onto the k-th workspace and then
    /// appending the surplus workspaces at the tail of that run is, once every
    /// section is a workspace cell, an elaborate way to write `workspaces.map`.
    ///
    /// `sections` stays in the signature for the one thing it can still tell us
    /// that `workspaces` cannot: that the user declared MORE cells than there are
    /// live workspaces (a hot-reload that added a section — the catalog is seeded
    /// once per session and never re-seeded). That is a diagnostic, not a shape.
    ///
    /// ## What t-6rbc removed
    ///
    /// The §G lost-and-found receptacle and the `orphans` parameter that fed it.
    /// An orphan was a window in NO workspace, and nothing in facet could produce
    /// one — `setOrphan`'s only caller had no callers of its own since t-qtpx. The
    /// receptacle rescued a set that was provably always empty, so it rendered a
    /// section that could only ever BE empty: a permanent lie in the tree, which
    /// is the same class of defect t-mqqw's rename went to war with. Every window
    /// facet manages is in a workspace — now a TYPE (`WindowSlot.workspace: Int`),
    /// not a hope.
    public static func project(workspaces: [Workspace],
                               sections: [DesktopSection]) -> Result {
        // Sections map onto the live workspaces POSITIONALLY — the backend emits
        // them index-ascending, so array order == index order. id /
        // sourceWorkspaceIndex come from `ws.index` (the 0-based WIRE index), NOT
        // the array position or the label, so `--focus` / `--move-to` resolve by
        // index and never by a (possibly-empty / non-unique) label.
        // A parked window stays in place in its section: the tree is an
        // inventory, not a screen mirror (an inactive workspace's windows are
        // anchor-parked too, and show normally).
        func wsSection(_ ws: Workspace) -> ProjectedSection {
            ProjectedSection(id: "ws:\(ws.index)", label: ws.name,
                        windows: ws.windows,
                        sourceWorkspaceIndex: ws.index,
                        sectionType: .workspace)
        }
        let surplus = (workspaces.count..<max(workspaces.count, sections.count))
            .map { "config: workspace section #\($0 + 1) has no matching live "
                + "workspace (more workspace sections than workspaces)" }
        return Result(sections: workspaces.map(wsSection), diagnostics: surplus)
    }

    /// Project an ISOLATE DESKTOP (t-0sbm → t-ec9s) DIRECTLY — without synthesizing
    /// a config `DesktopSection`. Produces ONE `.matched` section (id
    /// `section:0:<label>` — the stable change-match handle) and, when
    /// `showNonMatching`, a `.holding` section (id `holding:1`) filled with the
    /// leftover (universe − matched). Pure. `match` is the ALREADY-EFFECTIVE
    /// predicate (config `match` or the runtime `--match` override, resolved by
    /// the caller).
    public static func projectIsolateDesktop(
        workspaces: [Workspace],
        match: String,
        label: String,
        showNonMatching: Bool
    ) -> Result {
        var diags: [String] = []
        var matched: [Window] = []
        switch FacetFilter.parse(match) {
        case .failure(let error):
            diags.append("config: isolate desktop \"\(label)\" match: "
                + error.caret(in: match))
        case .success(let filter):
            let unknown = filter.fieldsReferenced()
                .subtracting(FacetFilter.knownFields).sorted()
            if !unknown.isEmpty {
                diags.append("config: isolate desktop \"\(label)\" match references "
                    + "unknown field(s): " + unknown.joined(separator: ", "))
            }
            // An isolate desktop shows EVERY window its match satisfies (t-c6fm):
            // a parked window still shows (park is a real-screen op, orthogonal
            // to the display filter).
            for ws in workspaces {
                for w in ws.windows
                where IsolateMembership.matches(
                    w, inWorkspaceNamed: ws.name, filter: filter) {
                    matched.append(w)
                }
            }
        }
        var out: [ProjectedSection] = [
            ProjectedSection(id: "section:0:\(label)", label: label,
                             windows: matched, sourceWorkspaceIndex: nil,
                             sectionType: .matched),
        ]
        if showNonMatching {
            var shownIDs = Set<WindowID>()
            for w in matched { shownIDs.insert(w.id) }
            var seen = Set<WindowID>()
            var leftover: [Window] = []
            for w in workspaces.flatMap(\.windows) {
                guard seen.insert(w.id).inserted else { continue }   // dedup universe
                if !shownIDs.contains(w.id) { leftover.append(w) }
            }
            // `.holding`, NOT `.unassigned` (t-mqqw): these windows ARE assigned
            // to workspaces — they are held back because they failed the `match`.
            // Nor `.parked`: `IsolatePark.parkSet` exempts sticky windows from
            // parking, and this leftover-by-subtraction does not, so a sticky
            // non-matching window is listed here while staying put on screen.
            out.append(ProjectedSection(
                id: "holding:1", label: "", windows: leftover,
                sourceWorkspaceIndex: nil, sectionType: .holding))
        }
        return Result(sections: out, diagnostics: diags)
    }
}

/// §E / t-j7ps: overlay an isolate desktop's session-only DISPLAY-LABEL override
/// onto its projected sections. Pure + backend-neutral, so it is unit-tested in
/// `FacetCoreTests`; the production seam (`Controller.apply()`) calls it once,
/// before the reorder.
///
/// ONLY the `.matched` section is relabeled. That is a structural fact, not a
/// policy:
/// - a WORKSPACE section's display name lives in the catalog (`workspaceNames`),
///   so a workspace rename routes to `renameWorkspace` and never reaches here;
/// - a `.holding` section is synthesized by SUBTRACTION from the `match`. Its
///   label is a hardcoded `""` (see `projectIsolateDesktop`) and there is no
///   config key anywhere to write a name to. Relabeling it would invent a name
///   with nowhere to live — which is exactly what the old id-keyed
///   `applyLabelOverrides` would have done, since its guard was the NEGATIVE
///   `!= .workspace`.
///
/// ⚠️ ORDINAL-KEYED, and applied to the OUTPUT — never fed into the projection's
/// INPUT the way the `match` override is. The matched section's id is
/// `"section:0:\(label)"`, with the CONFIG label baked in: relabel the input and
/// the minted id changes, so an id-keyed override would stop matching itself on
/// the very next reconcile and the rename would evaporate. Keying on the mac
/// desktop's ordinal — the one thing a rename cannot change — sidesteps the whole
/// class. The id is never touched, so `--focus N|LABEL` identity stays invariant.
///
/// `nil` / empty label = no override (the config label shows through). A "revert
/// to config" is a REMOVED key, never a stored `""` — the caller owns that.
public func applyIsolateLabelOverride(_ sections: [ProjectedSection],
                                      label: String?) -> [ProjectedSection] {
    guard let label, !label.isEmpty else { return sections }
    return sections.map { ps in
        guard ps.sectionType == .matched else { return ps }
        return ProjectedSection(id: ps.id, label: label, windows: ps.windows,
                                sourceWorkspaceIndex: ps.sourceWorkspaceIndex,
                                sectionType: ps.sectionType)
    }
}
