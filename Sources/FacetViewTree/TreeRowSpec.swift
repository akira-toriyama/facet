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
        case master, float, sticky, hidden, parked, mark, scratchpad, tag, overflow
    }
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String = "") { self.kind = kind; self.text = text }
}

/// The fuzzy filter, kept pure (app name + title only — WS/section names are
/// NOT searched, matching the AppKit tree). Empty query matches everything.
private func matches(_ query: String, _ w: Window) -> Bool {
    query.isEmpty || fuzzyMatch(query, w.appName + " " + w.title)
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
    if w.isParked { out.append(TreeBadge(.parked)) }   // t-c6fm phase 4
    if let m = w.mark { out.append(TreeBadge(.mark, m)) }
    if let s = w.scratchpad { out.append(TreeBadge(.scratchpad, s)) }
    let shown = w.tags.prefix(tagVisibleCap)
    out.append(contentsOf: shown.map { TreeBadge(.tag, $0) })
    if w.tags.count > tagVisibleCap {
        out.append(TreeBadge(.overflow, "+\(w.tags.count - tagVisibleCap)"))
    }
    return out
}

private func headerPrimary(_ s: ProjectedSection) -> String {
    let kind: String
    switch s.sectionType {
    case .workspace: kind = "workspace"
    case .lens: kind = "lens"
    case .unassigned: kind = "unassigned"
    }
    return "\(kind) · \(s.label)"
}

/// Flatten `[ProjectedSection]` → ordered `[TreeRowSpec]`. `group` is the
/// render-group ordinal (0-based, per emitted section) so the same window in
/// multiple sections gets distinct ids. A section whose windows all fail the
/// filter is dropped whole (its header does not render); an empty query keeps
/// every section (even one with no windows).
///
/// `layoutMode` supplies the layout-engine abbrev shown as a header subtitle,
/// and is consulted for `.workspace` sections only (lens / unassigned headers
/// have no layout, so their subtitle stays `nil` even if the closure returns a
/// value). The default keeps every existing 2-arg call site subtitle-free.
public func buildTreeRows(
    sections: [ProjectedSection], query: String,
    layoutMode: (ProjectedSection) -> String? = { _ in nil }
) -> [TreeRowSpec] {
    var rows: [TreeRowSpec] = []
    var group = 0
    for s in sections {
        let wins = s.windows.filter { matches(query, $0) }
        if !query.isEmpty && wins.isEmpty { continue }   // zero-match drop
        let subtitle = s.sectionType == .workspace ? layoutMode(s) : nil
        rows.append(TreeRowSpec(
            id: .header(s.id),
            kind: .header(sectionType: s.sectionType, subtitle: subtitle),
            primary: headerPrimary(s), secondary: nil, badges: []))
        for w in wins {
            rows.append(TreeRowSpec(
                id: .window(group: group, w.id),
                kind: .window(pid: w.pid),
                primary: w.appName,
                secondary: w.title.isEmpty ? nil : w.title,
                badges: windowBadges(w)))
        }
        group += 1
    }
    return rows
}
