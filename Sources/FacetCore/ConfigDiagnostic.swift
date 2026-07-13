// One semantic finding from decoding config.toml (t-r5yz).
//
// facet has two config channels, and they answer different questions:
//
//   • `schemaWarnings` ([ValidationError], sill's `Spec.validate`) — STRUCTURAL.
//     "Is this key spelled right? Is this value the right type / in range?"
//   • `diagnostics` (this type) — SEMANTIC. "Did facet actually KEEP what you
//     wrote?" A block can be perfectly well-formed and still be discarded whole
//     (an `[desktop.N] type = "isolate"` with no `match`, a `[[rule]]` with no
//     apply key, a zero-constraint `[[exclude]]`).
//
// The second question had no answer at all. Every drop already produced a
// human-readable reason, but it went to `Log.line` — which mirrors to stderr
// only under `FACET_DEBUG` — so `facet config --validate` printed
// "config valid" + exit 0 while a whole desktop had been thrown away. That is
// the exact "silent fallback" CLAUDE.md forbids.
//
// SEVERITY IS DATA, not control flow. The decoders classify; each CONSUMER
// decides what to do:
//   • the daemon (`Controller.logConfigWarnings`) LOGS every severity and
//     never rejects — a broken config still boots (unchanged contract).
//   • `facet config --validate` promotes `.error` to **exit 1** — it is the
//     tool whose entire job is answering "what will facet do with this file?".
//
// Adding a drop? Classify it by ONE rule: **something the user WROTE was
// discarded whole → `.error`. A value was clamped to a default → `.warning`.**
// ("A typo can never break the layout" stays true — clamps still clamp.)

/// A semantic finding from the config decode — see the file header.
public struct ConfigDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        /// Something the user wrote was DISCARDED (a table, an array element,
        /// a whole block). `--validate` exits 1; the daemon logs and boots.
        case error
        /// The block survives, but facet ignored or clamped part of it.
        case warning
    }

    public let severity: Severity
    /// Already user-facing, already located (e.g. `[desktop.2]: isolate desktop
    /// needs a non-empty \`match\``). Printed verbatim.
    public let message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

public extension Array where Element == ConfigDiagnostic {
    /// Does this config contain a block facet threw away?
    var hasErrors: Bool { contains { $0.severity == .error } }
    var errorCount: Int { lazy.filter { $0.severity == .error }.count }
    var warningCount: Int { lazy.filter { $0.severity == .warning }.count }
}

/// `facet config --validate`'s exit code, as a pure function of what the two
/// channels found — so the mapping is a testable value rather than a shape
/// buried around an `exit()` call.
///
///   • **1** — the file is not what the user thinks it is: a schema violation
///     (unknown key / bad enum / out-of-range) OR a block facet DISCARDED.
///   • **0** — valid. Warnings (clamps, ignored strays, a match that parses but
///     selects nothing) print but never fail the check: "a typo can never break
///     the layout" is the daemon's contract, and `--validate` reports it rather
///     than second-guessing it.
///
/// (Exit 2 — unreadable / unparseable — is decided before either channel exists
/// and lives at the call site.)
public func configValidateExitCode(schemaErrorCount: Int,
                                   diagnostics: [ConfigDiagnostic]) -> Int32 {
    (schemaErrorCount > 0 || diagnostics.hasErrors) ? 1 : 0
}
