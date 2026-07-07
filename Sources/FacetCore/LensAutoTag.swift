// `LensAutoTag` — match-based auto-apply of lens `apply` tags (t-sw9p).
//
// A window carries the `apply` tags of EVERY `type="lens"` section whose
// `match` it satisfies — regardless of when/where it opened or which lens is
// "active". This is the read the adapter runs per window on reconcile, adding
// the result ADDITIVELY (`addTagToWindow`), so a window open BEFORE facet
// launched is tagged just like one opened after. Before this, lens `apply` tags
// reached a window only via drag-drop or EX-3.3 active-lens-inherit (new windows
// only), which is why pre-existing windows stayed untagged.
//
// Pure + backend-neutral (FacetCore, no AppKit / no AX): membership rides the
// single `LensMembership` predicate (the same one `FilterProjection` uses for
// DISPLAY), so tagging and the tree can never disagree about what a lens
// matches. A lens is still a pure VIEW (t-0021) — this only writes the window's
// own tag attribute, it moves nothing.
import Foundation

public enum LensAutoTag {
    /// The tags `window` (perceived in the workspace named `workspaceName`)
    /// should carry from the lens sections it matches. Multi-match: every
    /// matching `type="lens"` section contributes its `apply` add-tags, in
    /// declaration order, DEDUPED (a tag two lenses share appears once). A
    /// section is skipped when it is not a lens, is an `unassigned` receptacle,
    /// carries no add-tags (a pure-condition lens — nothing to add), or has a
    /// `match` that won't parse (loud-but-non-fatal, mirroring `FilterProjection`;
    /// the parse-error is surfaced there, not re-logged here). Total — never
    /// throws; the caller adds the result additively (never removes).
    public static func tags(for window: Window,
                            inWorkspaceNamed workspaceName: String?,
                            lensSections: [DesktopSection]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for section in lensSections {
            guard section.type == .lens, !section.unassigned else { continue }
            let addTags: [String] = section.apply.compactMap {
                if case .addTag(let t) = $0 { return t } else { return nil }
            }
            guard !addTags.isEmpty else { continue }
            guard case .success(let filter) = FacetFilter.parse(section.match) else {
                continue
            }
            guard LensMembership.matches(window, inWorkspaceNamed: workspaceName,
                                         filter: filter) else { continue }
            for t in addTags where seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
