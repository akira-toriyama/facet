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

/// Parse an integer flag value (the part after ``=``).
/// `requirePositive` rejects ``0`` and negatives — use for width /
/// height where a 0-sized panel is meaningless.
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
