// Filter alias resolution (t-5312) — the pure substitution step behind the
// `@name` grammar (`FacetFilter.aliasRef`).
//
// A FILTER ALIAS is a named `facet filter` sub-expression from the config's
// `[alias]` table (`web = 'app~=Chrome or app~=Safari'`), referenced as
// `@web` anywhere a filter appears: `[desktop.N] match`, `[[rule]] match`,
// `facet section --match`, `facet query --filter`. Aliases may reference
// other aliases; a cycle is detected loudly (visited-path, not a depth cap).
//
// Resolution is a PURE AST substitution over an already-parsed filter — NOT
// text expansion — so a quoted `@` stays literal for free and parse-error
// carets keep pointing into the ORIGINAL source. The alias table maps
// LOWERCASE kebab names to verbatim expression strings (decode enforces the
// name shape; lookup lowercases the ref, matching the filter language's
// case-insensitive default).
//
// TOTAL, like everything in the filter family: an undefined / cyclic /
// malformed reference is REPORTED and left in place as `.aliasRef`, which
// matches nothing at eval. Each surface then applies its own policy:
//   • config (isolate / rule match)  → DROP the block + `.error` (t-5312 —
//     degrading an isolate match to no-match would anchor-park EVERY window)
//   • `section --match`              → loud reject, keep the working match
//   • `query --filter`               → warn + no-match (the unknown-field
//     precedent — non-fatal, read-only)

public extension FacetFilter {
    /// The outcome of substituting `@name` references against an alias table.
    /// `filter` always comes back usable: every resolvable ref is replaced by
    /// its (recursively resolved) expansion; an unresolvable one stays
    /// `.aliasRef` and matches nothing at eval.
    struct AliasResolution: Sendable, Equatable {
        /// The filter with every resolvable `@name` substituted.
        public let filter: FacetFilter
        /// Referenced names with no `[alias]` entry — sorted, lowercase.
        /// (Includes a name whose stored expression is EMPTY or fails to
        /// parse: a decoded config never contains one — `[alias]` decode
        /// drops those loudly — so from the resolver's seat "you cannot use
        /// this name" and "this name does not exist" are the same verdict.)
        public let undefined: [String]
        /// Rendered reference cycles (`"@a → @b → @a"`) — sorted.
        public let cycles: [String]

        public var isClean: Bool { undefined.isEmpty && cycles.isEmpty }

        public init(filter: FacetFilter, undefined: [String], cycles: [String]) {
            self.filter = filter
            self.undefined = undefined
            self.cycles = cycles
        }
    }

    /// Substitute every `@name` reference against `table` (lowercase name →
    /// verbatim expression). Pure and total — never throws; see
    /// `AliasResolution` for the degrade contract.
    func resolvingAliases(_ table: [String: String]) -> AliasResolution {
        var undefined = Set<String>()
        var cycles = Set<String>()

        // `path` = the alias names currently being expanded, root-first —
        // the visited set that turns infinite recursion into a rendered
        // cycle chain.
        func resolve(_ node: FacetFilter, path: [String]) -> FacetFilter {
            switch node {
            case .all, .atom:
                return node
            case .not(let f):
                return .not(resolve(f, path: path))
            case .and(let parts):
                return .and(parts.map { resolve($0, path: path) })
            case .or(let parts):
                return .or(parts.map { resolve($0, path: path) })
            case .aliasRef(let raw):
                let name = raw.lowercased()
                if let i = path.firstIndex(of: name) {
                    cycles.insert((path[i...] + [name])
                        .map { "@" + $0 }.joined(separator: " → "))
                    return node
                }
                guard let expr = table[name],
                      !expr.trimmingCharacters(in: .whitespaces).isEmpty,
                      case .success(let sub) = FacetFilter.parse(expr)
                else {
                    // Absent, empty, or unparseable — all "no such alias"
                    // here (decode already reported the latter two loudly
                    // and dropped them from any real config's table). The
                    // empty guard matters: `parse("")` is `.success(.all)`,
                    // and silently substituting match-EVERYTHING is exactly
                    // the accident the blank-alias drop exists to close.
                    undefined.insert(name)
                    return node
                }
                return resolve(sub, path: path + [name])
            }
        }

        let resolved = resolve(self, path: [])
        return AliasResolution(filter: resolved,
                               undefined: undefined.sorted(),
                               cycles: cycles.sorted())
    }
}

/// Is `name` a valid `[alias]` key? Kebab-case, lowercase:
/// `[a-z][a-z0-9-]*`. The shape keeps names shell-safe and unambiguous
/// after the `@` in a filter expression (an operator-lead or space would
/// split the bareword). Enforced at decode — refs merely lowercase.
public func isValidFilterAliasName(_ name: String) -> Bool {
    guard let first = name.first, first >= "a", first <= "z" else { return false }
    return name.allSatisfy {
        ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
    }
}

// MARK: - Alias checklist composition (t-kywh)
//
// The Edit-match panel's alias PICKER is a tag-style checklist: checked =
// "this alias is a top-level OR term of the current match", and toggling a
// row rewrites the match text (applied LIVE — the isolate desktop re-tiles
// on every toggle, the tag-panel interaction model). The derive + rewrite
// logic is pure and lives here so it is unit-tested without AppKit.

/// The top-level OR terms of a match expression: `[]` for empty (`.all`),
/// the or-parts for an `or`, else the whole expression as one term. `nil`
/// when the text doesn't parse (the checklist goes inert — a malformed
/// hand-edit is the field's problem, shown by its validation message).
public func matchAliasTerms(_ text: String) -> [FacetFilter]? {
    guard case .success(let filter) = FacetFilter.parse(text) else { return nil }
    switch filter {
    case .all: return []
    case .or(let parts): return parts
    default: return [filter]
    }
}

/// The alias names (lowercased) checked in the checklist for `text` — every
/// top-level OR term that is a bare `@name` reference. `nil` = malformed.
public func matchCheckedAliases(_ text: String) -> Set<String>? {
    guard let terms = matchAliasTerms(text) else { return nil }
    return Set(terms.compactMap {
        if case .aliasRef(let n) = $0 { return n.lowercased() } else { return nil }
    })
}

/// Rewrite `text` with the `name` alias toggled as a top-level OR term:
/// present → removed, absent → appended. Non-alias terms survive (re-rendered
/// via `description` — semantics preserved; `or` is the loosest precedence,
/// so a plain " or " join needs no extra parens). Unchecking the last term
/// yields `""` — the revert-to-config gesture, which is exactly what an
/// empty checklist should mean. `nil` = malformed text (toggle refused).
public func matchTogglingAlias(_ text: String, name: String) -> String? {
    guard let terms = matchAliasTerms(text) else { return nil }
    let lname = name.lowercased()
    var out: [String] = []
    var removed = false
    for term in terms {
        if case .aliasRef(let n) = term {
            if n.lowercased() == lname { removed = true; continue }
            out.append("@" + n.lowercased())
        } else {
            out.append(term.description)
        }
    }
    if !removed { out.append("@" + lname) }
    return out.joined(separator: " or ")
}

/// t-5312 display-name inheritance: an isolate desktop whose `match` is a
/// SINGLE alias reference and whose `label` is omitted takes the alias name
/// as its display name (`match = '@web'`, no `label` → shows "web").
/// Returns `nil` when the rule doesn't apply (explicit label wins; a
/// compound match names nothing). Pure; the caller overlays the result the
/// same way as the session rename override (display-only, id-preserving —
/// applied to the projection's OUTPUT, never its input).
public func isolateAliasInheritedLabel(match: String, label: String) -> String? {
    guard label.isEmpty else { return nil }
    let trimmed = match.trimmingCharacters(in: .whitespaces)
    guard case .success(.aliasRef(let name)) = FacetFilter.parse(trimmed) else {
        return nil
    }
    return name.lowercased()
}
