// Short, display-only caption for a workspace cell — shared by the
// grid, rail, and tree headers so the same name renders identically in
// every view. Strips a leading "workspace " prefix (case-insensitive)
// so a user-named "WORKSPACE Q" shows as "Q", matching the Mission
// Control convention of single-letter cell captions. Empty name →
// "WS<n>" (1-based).
//
// Pure / display-only: the layout picker, CLI, and config keep the full
// workspace name; only the caption is shortened.

/// Short workspace caption from `name` (or `WS<idx+1>` when empty). A
/// user-named workspace passes through unchanged (§B retired the emoji-pool
/// decoration). NOTE: §D replaces this helper with
/// `sectionDisplayLabel(index:label:)` — the `WS<n>` empty-name form is
/// transitional until then.
public func workspaceShortLabel(name: String, idx: Int) -> String {
    if name.isEmpty { return "WS\(idx + 1)" }
    let lower = name.lowercased()
    if lower.hasPrefix("workspace "), name.count > "workspace ".count {
        return String(name.dropFirst("workspace ".count))
    }
    return name
}
