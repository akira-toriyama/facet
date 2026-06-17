// `facet query --windows --filter EXPR` — the post-filter applied to the
// window-query array (pivot Phase 1, #284 PR#3).
//
// This is the FIRST production wiring of `facet filter` (the WHERE-clause
// language from #283): the safest possible one — read-only, off the hot
// path, a pure post-filter the CLIENT runs over the already-written
// `/tmp/facet-query.json`. The server is untouched; it still writes EVERY
// window. `facet query --windows --filter EXPR` decodes that array, keeps
// the windows the expression matches, and re-emits the subset.
//
// The DECISION (parse → degrade-or-filter, collect diagnostics) is pure
// and lives here so it is unit-testable in `FacetCoreTests`
// (`QueryFilterTests`) — the executable `FacetApp` has no test target. The
// I/O and exit codes (read the file, write stderr, `exit`) stay in
// `FacetApp.runQueryWindows`, which is a thin shell over this.
//
// Loud-but-NON-FATAL, by design (matches the `facet filter` philosophy —
// a typo never aborts):
//   • a malformed EXPR → `parseErrorCaret` is set, `entries` degrades to
//     ALL windows (show-all). The caller logs the caret and prints
//     everything; it exits 0, NOT 2 (a bad filter VALUE is not a flag /
//     arity usage error).
//   • an EXPR referencing an unknown field → `unknownFields` lists it.
//     Those atoms simply no-match in the evaluator; the caller warns and
//     prints the (matching) subset anyway.

/// The outcome of applying a `--filter EXPR` to a `[WindowQueryEntry]`.
public enum QueryFilter {
    public struct Outcome: Sendable, Equatable {
        /// The windows to print. The matching subset on a clean parse; on
        /// a parse error, ALL of the input (the show-all degrade).
        public let entries: [WindowQueryEntry]
        /// A caret-rendered parse error to log loudly, or `nil`. When
        /// present it sits ALONGSIDE a full `entries` (show-all) — it is a
        /// non-fatal diagnostic, not a failure result.
        public let parseErrorCaret: String?
        /// Referenced field names not in `FacetFilter.knownFields`, sorted
        /// — a loud-but-non-fatal typo warning. Empty when every field is
        /// known (or the parse failed, so no fields resolved).
        public let unknownFields: [String]

        public init(entries: [WindowQueryEntry],
                    parseErrorCaret: String?,
                    unknownFields: [String]) {
            self.entries = entries
            self.parseErrorCaret = parseErrorCaret
            self.unknownFields = unknownFields
        }
    }

    /// Parse `expr` and filter `entries`. Total — never throws. An empty /
    /// whitespace-only `expr` parses to `.all` and keeps every window (the
    /// natural "no filter" value).
    public static func apply(_ expr: String,
                             to entries: [WindowQueryEntry]) -> Outcome {
        switch FacetFilter.parse(expr) {
        case .failure(let error):
            // Degrade to show-all; hand the caller the caret to log.
            return Outcome(entries: entries,
                           parseErrorCaret: error.caret(in: expr),
                           unknownFields: [])
        case .success(let filter):
            let unknown = filter.fieldsReferenced()
                .subtracting(FacetFilter.knownFields)
                .sorted()
            let matched = entries.filter { filter.matches($0) }
            return Outcome(entries: matched,
                           parseErrorCaret: nil,
                           unknownFields: unknown)
        }
    }
}
