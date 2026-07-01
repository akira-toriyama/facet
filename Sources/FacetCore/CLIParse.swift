// Pure CLI argument parsing helpers. Decoupled from FacetApp so they
// can be unit-tested without dragging AppKit / executable side-effects
// (exit(2), stderr writes) into the test target. Callers in FacetApp
// translate `.failure` into stderr + exit; tests assert on the Result.

import Foundation

public enum CLIParseError: Error, Equatable, Sendable {
    case notAnInteger(value: String)
    case notPositive(value: Int)
    case unknownValue(value: String, expected: [String])
}

/// Cursor over the argv tail for the space-separated flag grammar (#227,
/// yabai-style `--flag VALUE`). ``next()`` consumes one token
/// unconditionally — lookahead-zero / *strict consumption* — so a flag's
/// declared value token is taken verbatim even when it starts with `-`
/// (a negative coordinate `-1440`, a literal `0`); per-flag validators
/// decide whether the consumed value is acceptable. Pure (no `exit` /
/// stderr) so it is unit-testable; FacetApp adds a `value(for:)`
/// convenience that loud-exits on underflow.
public struct ArgCursor {
    private let args: [String]
    private var idx: Int = 0

    public init(_ args: [String]) { self.args = args }

    /// True once every token has been consumed.
    public var isAtEnd: Bool { idx >= args.count }

    /// The next token without consuming it (`nil` when exhausted).
    public func peek() -> String? { idx < args.count ? args[idx] : nil }

    /// Consume and return the next token, or `nil` when exhausted.
    public mutating func next() -> String? {
        guard idx < args.count else { return nil }
        defer { idx += 1 }
        return args[idx]
    }
}

/// Parse an integer flag value (the token the cursor consumed for this
/// flag — #227 space-separated grammar). `requirePositive` rejects ``0``
/// and negatives — use for width / height where a 0-sized panel is
/// meaningless.
public func parseGeomInt(_ raw: String,
                         requirePositive: Bool = false)
        -> Result<Int, CLIParseError> {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard let n = Int(trimmed) else {
        return .failure(.notAnInteger(value: trimmed))
    }
    if requirePositive && n <= 0 {
        return .failure(.notPositive(value: n))
    }
    return .success(n)
}

/// Validate / canonicalise a name (e.g. view, theme) against an
/// allow-list. Lowercases + trims whitespace; rejects with the
/// expected list so the caller can build a useful error message.
public func canonicalize(_ name: String,
                         allowed: [String])
        -> Result<String, CLIParseError> {
    let n = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard allowed.contains(n) else {
        return .failure(.unknownValue(value: n, expected: allowed))
    }
    return .success(n)
}

/// All-or-nothing geometry tuple. Used by ``--pos-x/--pos-y/--width/
/// --height``: either all four are set or none. A partial set is a
/// user mistake.
public enum GeomValidation: Equatable, Sendable {
    case none
    case complete(x: Int, y: Int, w: Int, h: Int)
    case partial(count: Int)
}

public func validateGeom(posX: Int?, posY: Int?,
                         width: Int?, height: Int?) -> GeomValidation {
    let provided = [posX, posY, width, height].compactMap { $0 }.count
    switch provided {
    case 0:
        return .none
    case 4:
        return .complete(x: posX!, y: posY!, w: width!, h: height!)
    default:
        return .partial(count: provided)
    }
}

/// §E: validate a section DISPLAY label (the LABEL of `facet section
/// --rename N LABEL`). LOOSE like the lens-section label policy: section
/// labels are config-authored display strings, so spaces and most
/// punctuation (including `:`) are fine and kept VERBATIM.
///
/// One deliberate asymmetry: a TRULY EMPTY string (`""`) is ALLOWED — it is
/// the explicit "revert to the number / config label" gesture the server's
/// resolver acts on (workspace → number, lens → drop override). An ALL-
/// WHITESPACE value (`"   "`) is REJECTED as a typo (it would blank the
/// header without the revert intent), as is ANY value whose trimmed form
/// starts with `-`: `--rename`'s LABEL is consumed unconditionally (strict
/// consumption), so a mistyped flag in the LABEL slot (`facet section
/// --rename 2 --focus`) reaches here as the value — reject it loudly rather
/// than silently renaming the section to a flag string. This mirrors the
/// leading-dash guard in `parseLensSectionLabel` / `CLIName.isClean` (the
/// flag-guard convention every sibling two-value flag follows). Pure (no exit
/// / stderr) so it is unit-testable; the FacetApp wrapper translates
/// `.failure` into a loud exit(2). The success value is kept VERBATIM
/// (untrimmed) — normalization (the trim) happens at the server's store site.
public func validateSectionLabel(_ value: String)
        -> Result<String, CLIParseError> {
    if value.isEmpty { return .success(value) }     // explicit revert gesture
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
        return .failure(.unknownValue(value: value, expected: []))
    }
    return .success(value)
}

/// §E: the wire payload for `facet section --rename` —
/// `section-rename:<index>:<label>`. The index is a colon-free Int and the
/// label is kept VERBATIM (it may contain `:`), so the server splits ONCE on
/// the first `:`. Pure helper shared by the client (encode) and tests; the
/// server-side decode mirrors `decodeSectionRename`.
public func encodeSectionRename(index: Int, label: String) -> String {
    "section-rename:\(index):\(label)"
}

/// §E: decode the `section-rename:<index>:<label>` wire payload (the body
/// AFTER the `section-rename:` prefix is already stripped by the caller, OR
/// the full payload — both are accepted). Splits ONCE so a label containing
/// `:` survives verbatim. Returns `nil` for a malformed index (`< 1` /
/// non-integer) or a missing `:`. Pure → unit-testable round-trip with
/// `encodeSectionRename`.
public func decodeSectionRename(_ payload: String) -> (index: Int, label: String)? {
    let body = payload.hasPrefix("section-rename:")
        ? String(payload.dropFirst("section-rename:".count))
        : payload
    let parts = body
        .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard parts.count == 2, let n = Int(parts[0]), n >= 1 else { return nil }
    return (n, parts[1])
}

/// t-0020: the wire payload for `facet section --match` —
/// `section-match:<index>:<predicate>`. The TWIN of `encodeSectionRename`: the
/// index is a colon-free 1-based Int and the `facet filter` predicate is kept
/// VERBATIM (it may contain `:` inside a quoted value), so the server splits
/// ONCE on the first `:`. Pure helper shared by the client (encode) and tests;
/// the server-side decode mirrors `decodeSectionMatch`. An EMPTY predicate is
/// the explicit revert-to-config gesture and round-trips intact.
public func encodeSectionMatch(index: Int, predicate: String) -> String {
    "section-match:\(index):\(predicate)"
}

/// t-0020: decode the `section-match:<index>:<predicate>` wire payload (the body
/// AFTER the `section-match:` prefix is already stripped by the caller, OR the
/// full payload — both are accepted). Splits ONCE so a predicate containing `:`
/// survives verbatim, and an EMPTY predicate decodes (it's the revert gesture,
/// not a malformed input). Returns `nil` for a malformed index (`< 1` /
/// non-integer) or a missing `:`. Pure → unit-testable round-trip with
/// `encodeSectionMatch`.
public func decodeSectionMatch(_ payload: String) -> (index: Int, predicate: String)? {
    let body = payload.hasPrefix("section-match:")
        ? String(payload.dropFirst("section-match:".count))
        : payload
    let parts = body
        .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        .map(String.init)
    guard parts.count == 2, let n = Int(parts[0]), n >= 1 else { return nil }
    return (n, parts[1])
}

/// W2.3 (t-wrd2): the outcome of resolving a `facet board --focus` payload
/// against one mac desktop's board list. `.resolved` carries the 0-based board
/// index to select; the others are LOUD-but-non-fatal rejects the Controller
/// turns into a `setError` (typo-fails-loudly, matching `section --focus`).
public enum BoardFocusResolution: Equatable, Sendable {
    case resolved(boardIndex: Int)
    case outOfRange(requested: Int, count: Int)
    case unknownLabel(String)
    case malformed
}

/// Resolve a `facet board --focus` wire payload (`index:N` 1-based, or
/// `label:LABEL` verbatim — the encoding `parseBoardFocus` mints) to the 0-based
/// `[[desktop.N.tab]]` board index to select. `boardLabels` is the ordered list
/// of board display labels for the ACTIVE mac desktop; an EMPTY list is the
/// flat-config degrade case = ONE implicit board (addressable only as
/// `index:1`, so a flat `--focus 1` is an idempotent no-op while `--focus 2`+ is
/// rejected).
///
/// Unlike the display selector `activeBoardSections` — which CLAMPS a stale
/// session index to self-heal after a hot-reload — this REJECTS an explicit
/// out-of-range request so a CLI typo surfaces loudly. Label lookup matches the
/// FIRST non-empty equal label (config enforces label uniqueness within a
/// desktop; empty labels are index-addressed only). Pure (no exit / stderr) so
/// it is unit-testable; FacetApp's `dispatchBoardFocus` maps `.resolved` to a
/// `selectedBoard` write + reconcile and the reject cases to a loud `setError`.
public func resolveBoardFocus(_ payload: String,
                              boardLabels: [String]) -> BoardFocusResolution {
    let count = max(1, boardLabels.count)   // flat config = one implicit board
    if payload.hasPrefix("index:") {
        guard let n = Int(payload.dropFirst("index:".count)) else { return .malformed }
        guard n >= 1, n <= count else {
            return .outOfRange(requested: n, count: count)
        }
        return .resolved(boardIndex: n - 1)
    }
    if payload.hasPrefix("label:") {
        let label = String(payload.dropFirst("label:".count))
        guard let idx = boardLabels.firstIndex(where: { !$0.isEmpty && $0 == label })
        else { return .unknownLabel(label) }
        return .resolved(boardIndex: idx)
    }
    return .malformed
}
