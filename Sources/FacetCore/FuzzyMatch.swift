// Subsequence (fuzzy) match — `q`'s characters appear in `s` in
// order, not necessarily contiguous. Case-insensitive. Empty
// query matches everything. Used by SearchBar / SidebarView for
// the `s` filter in keyboard-nav mode.

public func fuzzyMatch(_ q: String, _ s: String) -> Bool {
    if q.isEmpty { return true }
    let hay = s.lowercased()
    var i = hay.startIndex
    for ch in q.lowercased() {
        guard let r = hay[i...].firstIndex(of: ch) else { return false }
        i = hay.index(after: r)
    }
    return true
}
