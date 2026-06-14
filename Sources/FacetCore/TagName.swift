// Tag-name validation (#191) — pure, backend-neutral, the single source
// of truth shared by the CLI parser (`facet window --tag` / `facet tag`)
// and the GUI tag-input box (PR-7). Tag names are session-only labels;
// the rules keep them parseable on the CLI surface and clear of the
// reserved floor.

import Foundation

public enum TagName {
    /// Normalise + validate a user-entered tag name. Strips a leading
    /// `#`, trims surrounding whitespace, then returns the cleaned name —
    /// or `nil` when it is empty, starts with `_` (reserved; `_default`
    /// is facet's internal floor), or contains `=`, `,` or `:` (the lens
    /// / rename CLI delimiters, so a name carrying one would be
    /// ambiguous). The CLI wraps this with a loud `exit 2`; the GUI input
    /// silently ignores a `nil`.
    public static func sanitized(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty,
              !s.hasPrefix("_"),
              !s.contains(where: { "=,:".contains($0) }) else {
            return nil
        }
        return s
    }
}
