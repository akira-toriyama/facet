// Shared CLI name-policy core (#227). Tag / mark / scratchpad / workspace
// names share one set of forbidden characters so they round-trip both the
// space-separated CLI grammar (`facet … --flag VALUE`) and the `:`/`+`/`,`
// delimited DNC control strings unambiguously. `TagName` layers the
// tag-specific rules (`#` strip, `_` floor) on top of this core.

import Foundation

public enum CLIName {
    /// The shared shape rule. A clean name is non-empty, has no internal
    /// whitespace, does not start with `-` (so strict consumption can't
    /// mistake it for a flag under the yabai-style grammar), and contains
    /// none of the DNC / CLI delimiters `:` `=` `,`.
    public static func isClean(_ s: String) -> Bool {
        !s.isEmpty
            && !s.hasPrefix("-")
            && !s.contains(where: { $0.isWhitespace })
            && !s.contains(where: { "=,:".contains($0) })
    }

    /// Trim surrounding whitespace and validate against ``isClean``.
    /// Returns the cleaned name, or `nil` when it violates the policy.
    /// Used for mark / scratchpad / workspace names — the CLI parser
    /// loud-rejects a `nil` with `exit 2`. Does NOT strip a leading `#`
    /// or reserve a leading `_`; those are tag-specific (see ``TagName``).
    public static func sanitized(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        return isClean(s) ? s : nil
    }
}
