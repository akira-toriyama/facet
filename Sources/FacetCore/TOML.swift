// Minimal TOML parser. Lifted verbatim from ws-tabs's
// `parseTOMLSubset` — keeps facet zero-dep (no SwiftPM TOML library
// pulled in). Supports just what the schema needs today:
//
//   - `[section]` headers
//   - `key = value` lines, where value is int / "string" / bool
//   - `#` line comments and inline `# …` comments (skipped only when
//     the value isn't a quoted string — `#` inside `"…"` stays as
//     data)
//   - Anything else is silently skipped (a typo only loses that one
//     line — the rest of the file still loads)
//
// Empty section name `""` is used for top-level keys.

import Foundation

public enum TOMLValue: Sendable, Equatable {
    case int(Int)
    case string(String)
    case bool(Bool)
}

/// Pure-function TOML subset parser. Output keyed by section name
/// (`""` for top-level), then key.
public func parseTOMLSubset(_ text: String)
    -> [String: [String: TOMLValue]]
{
    var out: [String: [String: TOMLValue]] = [:]
    var section = ""                               // "" = top-level
    for raw in text.split(separator: "\n",
                          omittingEmptySubsequences: false) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        // [section]
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            if out[section] == nil { out[section] = [:] }
            continue
        }
        // key = value
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq])
            .trimmingCharacters(in: .whitespaces)
        var val = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        // Inline `# …` comment. Two cases:
        //   - val starts with `"`: skip until the *closing* quote,
        //     then strip any `# …` that follows. `#` inside the
        //     quoted body stays as data.
        //   - val unquoted: any `#` starts the inline comment.
        if val.hasPrefix("\"") {
            let afterOpen = val.index(after: val.startIndex)
            if let closeIdx = val[afterOpen...].firstIndex(of: "\"") {
                let afterClose = val.index(after: closeIdx)
                if afterClose < val.endIndex,
                   let h = val[afterClose...].firstIndex(of: "#") {
                    val = String(val[..<h])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        } else if let h = val.firstIndex(of: "#") {
            val = String(val[..<h]).trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty, !val.isEmpty else { continue }
        let parsed: TOMLValue
        if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
            parsed = .string(String(val.dropFirst().dropLast()))
        } else if val == "true"  { parsed = .bool(true) }
        else  if val == "false" { parsed = .bool(false) }
        else  if let i = Int(val) { parsed = .int(i) }
        else  { continue }                          // skip unknown shapes
        out[section, default: [:]][key] = parsed
    }
    return out
}
