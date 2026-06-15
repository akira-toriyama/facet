// Tag-name validation (#191, tightened in #227) — pure, backend-neutral,
// the single source of truth shared by the CLI parser (`facet window --tag`
// / `facet tag`) and the GUI tag-input box (PR-7). Tag names are
// session-only labels; the rules keep them parseable on the
// space-separated CLI surface and clear of the reserved floor.

import Foundation

public enum TagName {
    /// Strict tag-name validation. Strips a leading `#`, trims surrounding
    /// whitespace, then returns the cleaned name — or `nil` when it is
    /// empty, starts with `_` (reserved; `_default` is facet's internal
    /// floor), or violates the shared ``CLIName`` policy (starts with `-`,
    /// contains internal whitespace, or carries a `:` / `=` / `,`
    /// delimiter). The CLI wraps this with a loud `exit 2`. Use this on
    /// the CLI side, where the shell has already split tokens so a space
    /// inside a name is a genuine error rather than typing-in-progress.
    public static func sanitized(_ raw: String) -> String? {
        let s = stripHashAndTrim(raw)
        return isValidTag(s) ? s : nil
    }

    /// Lenient variant for free-typed input — the GUI tag box and config
    /// `[[tag]] name = "…"`, where the user may type spaces. Collapses
    /// internal whitespace runs to `-` before validating, so `"my tag"`
    /// becomes `"my-tag"`. Returns the normalized name, or `nil` when even
    /// after normalization it violates the policy (e.g. carries a `:`).
    public static func normalized(_ raw: String) -> String? {
        let s = stripHashAndTrim(raw)
        let collapsed = s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        return isValidTag(collapsed) ? collapsed : nil
    }

    private static func stripHashAndTrim(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func isValidTag(_ s: String) -> Bool {
        !s.hasPrefix("_") && CLIName.isClean(s)
    }
}
