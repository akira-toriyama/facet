import FacetCore

/// A pure, Sendable render spec for one tree row (badges resolved to NSImage
/// only at the SwiftUI seam — see `TreeListItem`). The single builder that
/// replaces the two `SidebarView.update()` height/Cell ladders.
public struct TreeRowSpec: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case header(sectionType: ProjectedSectionType, subtitle: String?)
        case window(pid: Int)
    }
    public let id: TreeItemID
    public let kind: Kind
    public let primary: String
    public let secondary: String?
    public let badges: [TreeBadge]
}

/// A pure badge spec — the SwiftUI seam maps `kind` to a Phosphor slug + role.
public struct TreeBadge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case master, float, sticky, hidden, mark, scratchpad, tag, overflow
    }
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String = "") { self.kind = kind; self.text = text }
}

/// The AX-resolved title for a window: the backend's own title wins, and the
/// AX map fills in for the ones it left blank (Chrome / VS Code / Electron and
/// any window whose title lands late). `SidebarView.update`'s rule verbatim —
/// `win.title.isEmpty ? (titleOverride[win.id] ?? "") : win.title`.
func resolvedTitle(_ w: Window, _ titles: [WindowID: String]) -> String {
    w.title.isEmpty ? (titles[w.id] ?? "") : w.title
}

/// The fuzzy filter, kept pure (app name + title only — WS/section names are
/// NOT searched, matching the AppKit tree). Empty query matches everything.
/// Internal (not private): `TreeViewModel.focusedRowID` walks the same
/// filter + group numbering to scope the focus fill — one predicate, no drift.
/// `titles` is the same AX fallback map the rows render, so a window is
/// findable by the title the user can actually SEE.
func matches(_ query: String, _ w: Window,
             _ titles: [WindowID: String] = [:]) -> Bool {
    query.isEmpty || fuzzyMatch(query, w.appName + " " + resolvedTitle(w, titles))
}

/// Max tag chips shown before collapsing the remainder into a `+N` badge.
private let tagVisibleCap = 3

/// Status badges first (fixed order), then up to `tagVisibleCap` tag chips, then
/// a `+N` overflow badge when tags exceed the cap.
private func windowBadges(_ w: Window) -> [TreeBadge] {
    var out: [TreeBadge] = []
    if w.isMaster { out.append(TreeBadge(.master)) }
    if w.isFloating { out.append(TreeBadge(.float)) }
    if w.isSticky { out.append(TreeBadge(.sticky)) }
    if !w.isOnscreen { out.append(TreeBadge(.hidden)) }
    if let m = w.mark { out.append(TreeBadge(.mark, m)) }
    if let s = w.scratchpad { out.append(TreeBadge(.scratchpad, s)) }
    let shown = w.tags.prefix(tagVisibleCap)
    out.append(contentsOf: shown.map { TreeBadge(.tag, $0) })
    if w.tags.count > tagVisibleCap {
        out.append(TreeBadge(.overflow, "+\(w.tags.count - tagVisibleCap)"))
    }
    return out
}

private func headerPrimary(_ s: ProjectedSection, displayIndex: Int,
                           isActive: Bool) -> String {
    switch s.sectionType {
    case .workspace:
        // "workspace · 1 (Web)" — the 1-based DISPLAY index is the address
        // `--focus index:N` and the `m`-menu caption speak, and it is what
        // keeps two unnamed workspaces distinguishable. "●" marks the ACTIVE
        // workspace: the old header carried that as accent-bold text, which
        // sill's turnkey header styling doesn't offer — the information
        // stays, textual.
        let idx = "\(displayIndex + 1)"
        let name = s.label.isEmpty ? idx : "\(idx) (\(s.label))"
        return "workspace · \(name)\(isActive ? " ●" : "")"
    case .matched: return "matched · \(s.label)"
    case .holding: return "holding · \(s.label)"
    }
}

/// Flatten `[ProjectedSection]` → ordered `[TreeRowSpec]`. `group` names the
/// row's section, which is how a click resolves back to the section it acted
/// on. A section whose windows all fail the filter is dropped whole (its
/// header does not render); an empty query keeps every section (even one with
/// no windows).
///
/// ⚠️ `group` counts EMITTED sections, so under a non-empty query it is NOT an
/// index into the caller's `sections`. `SidebarView`'s twin pass keeps the
/// ORIGINAL index instead (`sections.enumerated().compactMap`), precisely so
/// `lastSections[g]` routing survives a dropped section. The two agree only
/// while the query is empty. Reconcile them before this feeds a host that
/// routes by `lastSections[group]` under search (t-tsxg facet-3).
///
/// `layoutMode` supplies the layout-engine abbrev shown as a header subtitle,
/// and is consulted for `.workspace` sections only (an isolate desktop's
/// matched / holding headers have no layout, so their subtitle stays `nil` even
/// if the closure returns a value). The default keeps every existing 2-arg call
/// site subtitle-free.
public func buildTreeRows(
    sections: [ProjectedSection], query: String,
    titles: [WindowID: String] = [:],
    layoutMode: (ProjectedSection) -> String? = { _ in nil },
    isActive: (ProjectedSection) -> Bool = { _ in false }
) -> [TreeRowSpec] {
    var rows: [TreeRowSpec] = []
    var group = 0
    for (originalIndex, s) in sections.enumerated() {
        let wins = s.windows.filter { matches(query, $0, titles) }
        if !query.isEmpty && wins.isEmpty { continue }   // zero-match drop
        let subtitle = s.sectionType == .workspace ? layoutMode(s) : nil
        rows.append(TreeRowSpec(
            id: .header(s.id),
            kind: .header(sectionType: s.sectionType, subtitle: subtitle),
            // The CAPTION keeps the ORIGINAL position — the address
            // `--focus index:N` speaks, invariant across a search filter
            // (the old tree's documented contract). `group` stays the
            // EMITTED ordinal (see the ⚠ note above): rows route against
            // `renderedSections`, captions speak the unfiltered order.
            primary: headerPrimary(s, displayIndex: originalIndex,
                                   isActive: isActive(s)),
            secondary: nil, badges: []))
        for w in wins {
            rows.append(TreeRowSpec(
                id: .window(group: group, w.id),
                kind: .window(pid: w.pid),
                primary: w.appName,
                secondary: resolvedTitle(w, titles).isEmpty
                    ? nil : resolvedTitle(w, titles),
                badges: windowBadges(w)))
        }
        group += 1
    }
    return rows
}
