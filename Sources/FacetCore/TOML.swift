// Minimal TOML parser — keeps facet zero-dep (no SwiftPM TOML
// library pulled in). Supports just what the schema needs today:
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
    /// Inline array of strings: `key = ["a", "b"]`. Only the
    /// homogeneous string-array form is parsed; mixed-type arrays
    /// and multi-line arrays are silently skipped (consistent with
    /// the rest of this parser's "skip what we don't recognise"
    /// policy). Empty array `[]` is permitted.
    case stringArray([String])
    /// Inline table: `key = { k = v, k2 = v2 }`. Values use the
    /// same scalar grammar as the rest of the parser
    /// (int / string / bool / stringArray / table). Empty table
    /// `{}` is permitted. Limit: `#` inside an inline-table string
    /// value is read as a comment start (same subset stance as
    /// elsewhere), so layout names ("bsp", "stack", …) are safe
    /// but `name = "tag # 1"` isn't.
    case table([String: TOMLValue])
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
        let rawVal = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let parsed = parseTOMLScalar(rawVal)
        else { continue }
        out[section, default: [:]][key] = parsed
    }
    return out
}

/// Parse repeated `[[name]]` array-of-tables blocks, in file order.
/// One dict per occurrence; keys use the same scalar grammar as
/// `parseTOMLSubset`. Lines outside a matching `[[name]]` block —
/// other array-tables, `[section]` headers, top-level keys — are
/// ignored. A `[section]` or a different `[[other]]` header closes
/// the current block.
///
/// Why a second pass instead of folding into `parseTOMLSubset`: that
/// returns `[section: [key: value]]`, which can't hold *multiple*
/// tables of the same name (the OR semantics `[[exclude]]` needs).
public func parseTOMLArrayOfTables(_ text: String, table name: String)
    -> [[String: TOMLValue]]
{
    var out: [[String: TOMLValue]] = []
    var inTarget = false
    for raw in text.split(separator: "\n",
                          omittingEmptySubsequences: false) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        // [[name]] — check the double-bracket form BEFORE [section],
        // since `[[x]]` also satisfies the single-bracket test.
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            let n = String(trimmed.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
            if n == name { out.append([:]); inTarget = true }
            else { inTarget = false }
            continue
        }
        // A plain [section] header ends the current array-table.
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            inTarget = false
            continue
        }
        guard inTarget, !out.isEmpty else { continue }
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq])
            .trimmingCharacters(in: .whitespaces)
        let rawVal = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let v = parseTOMLScalar(rawVal) else { continue }
        out[out.count - 1][key] = v
    }
    return out
}

/// Parse the value half of a `key = value` line into a `TOMLValue`,
/// stripping an inline `# …` comment first. Returns `nil` for an
/// empty or unrecognised value (caller skips that key). Shared by
/// `parseTOMLSubset` and `parseTOMLArrayOfTables`.
func parseTOMLScalar(_ raw: String) -> TOMLValue? {
    var val = raw
    // Inline `# …` comment. Two cases:
    //   - val starts with `"`: skip until the *closing* quote, then
    //     strip any `# …` that follows. `#` inside the quoted body
    //     stays as data.
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
    guard !val.isEmpty else { return nil }
    if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
        return .string(String(val.dropFirst().dropLast()))
    } else if val.hasPrefix("["), val.hasSuffix("]") {
        // Inline string array: `["a", "b"]`. Strict: every element
        // must be double-quoted; any malformed element skips the
        // whole value (matches the parser's "lose one line on typo"
        // failure mode).
        guard let strs = parseStringArray(val) else { return nil }
        return .stringArray(strs)
    } else if val.hasPrefix("{"), val.hasSuffix("}") {
        // Inline table: `{ k = "v", k2 = 1 }`. Comma-separated
        // pairs at top level; commas inside strings / nested
        // brackets / nested braces don't split (so an element value
        // can itself be an array or a sub-table). A malformed pair
        // skips the whole table (same "lose one line on typo"
        // policy as elsewhere).
        guard let dict = parseInlineTable(val) else { return nil }
        return .table(dict)
    } else if val == "true" { return .bool(true) }
    else if val == "false" { return .bool(false) }
    else if let i = Int(val) { return .int(i) }
    return nil                                   // skip unknown shapes
}

/// Parse `["a", "b"]` → `["a", "b"]`. Returns nil if any element
/// isn't a double-quoted string. Whitespace inside the brackets is
/// tolerated; commas inside string bodies are not (no escaping —
/// matches the rest of this parser's "subset" stance).
private func parseStringArray(_ raw: String) -> [String]? {
    let inner = raw.dropFirst().dropLast()
        .trimmingCharacters(in: .whitespaces)
    if inner.isEmpty { return [] }
    var out: [String] = []
    for piece in inner.split(separator: ",") {
        let p = piece.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("\""), p.hasSuffix("\""), p.count >= 2
        else { return nil }
        out.append(String(p.dropFirst().dropLast()))
    }
    return out
}

/// Parse `{ k = "v", k2 = 1 }` → `[k: .string("v"), k2: .int(1)]`.
/// Returns nil on a malformed pair (no `=`, empty key, value the
/// scalar parser rejects). Comma splitting is **string- and
/// nesting-aware**: a top-level comma separates pairs, but a comma
/// inside `"…"` / `[…]` / `{…}` stays as part of the value.
private func parseInlineTable(_ raw: String) -> [String: TOMLValue]? {
    let inner = raw.dropFirst().dropLast()
        .trimmingCharacters(in: .whitespaces)
    if inner.isEmpty { return [:] }
    var out: [String: TOMLValue] = [:]
    for piece in splitTopLevelCommas(inner) {
        let p = piece.trimmingCharacters(in: .whitespaces)
        guard let eq = p.firstIndex(of: "=") else { return nil }
        let key = p[..<eq].trimmingCharacters(in: .whitespaces)
        let rawVal = p[p.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              let parsed = parseTOMLScalar(rawVal) else { return nil }
        out[key] = parsed
    }
    return out
}

/// Split `s` on top-level commas, ignoring commas inside `"…"` or
/// inside nested `[…]` / `{…}` (so an inline-table value can itself
/// be an array or a sub-table). Returns the comma-separated pieces
/// as substrings (caller trims).
private func splitTopLevelCommas(_ s: String) -> [Substring] {
    var out: [Substring] = []
    var depth = 0
    var inString = false
    var lastSplit = s.startIndex
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if inString {
            if c == "\"" { inString = false }
        } else if c == "\"" {
            inString = true
        } else if c == "[" || c == "{" {
            depth += 1
        } else if c == "]" || c == "}" {
            if depth > 0 { depth -= 1 }
        } else if c == "," && depth == 0 {
            out.append(s[lastSplit..<i])
            lastSplit = s.index(after: i)
        }
        i = s.index(after: i)
    }
    out.append(s[lastSplit..<s.endIndex])
    return out
}
