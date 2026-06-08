// Shared window matcher — pure, backend-neutral, unit-testable.
//
// Both `[[exclude]]` (float/ignore/manage a window) and `[[assign]]`
// (give a window tags, M11-3) match windows by the SAME facts:
// app (bundle id) / title / AX role / subrole / size. This is that
// one matcher, extracted so the two rule sets share it (DRY — the
// regex + size + AND semantics live in exactly one place).
//
// The adapter supplies a `WindowProbe` (AX role/subrole from its
// on-demand probe; bundleId/title/size from the window model); a
// `WindowMatcher` answers whether a rule's constraints all hold.

import CoreGraphics
import Foundation

/// The window facts a rule is matched against. `role`/`subrole` are
/// optional because the adapter only probes AX for them within a
/// budget — when absent, role/subrole-keyed rules simply don't match.
public struct WindowProbe: Sendable, Equatable {
    public let bundleId: String?
    public let title: String
    public let role: String?
    public let subrole: String?
    public let size: CGSize?

    public init(bundleId: String?, title: String,
                role: String? = nil, subrole: String? = nil,
                size: CGSize? = nil) {
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.subrole = subrole
        self.size = size
    }
}

/// A set of window-fact constraints. Keys are ANDed; an unspecified
/// key is not a constraint. A matcher with no constraints matches
/// nothing (`isConstrained == false`) — this guards against a blank
/// rule silently matching every window.
public struct WindowMatcher: Sendable, Equatable {
    /// Regex matched against the window's bundle id (search, not
    /// anchored — write `^…$` to anchor).
    public let app: String?
    /// Regex matched against the window title. Empty title (unnamed
    /// window) is matched by `^$`.
    public let title: String?
    /// Exact AX role (e.g. `AXWindow`).
    public let role: String?
    /// Exact AX subrole (e.g. `AXDialog`).
    public let subrole: String?
    /// Match windows whose width is ≤ this (catches small popups).
    public let maxWidth: Double?
    /// Match windows whose height is ≤ this.
    public let maxHeight: Double?

    public init(app: String? = nil, title: String? = nil,
                role: String? = nil, subrole: String? = nil,
                maxWidth: Double? = nil, maxHeight: Double? = nil) {
        self.app = app
        self.title = title
        self.role = role
        self.subrole = subrole
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// Whether at least one constraint is set. A matcher with none
    /// never matches.
    public var isConstrained: Bool {
        app != nil || title != nil || role != nil || subrole != nil
            || maxWidth != nil || maxHeight != nil
    }

    /// Whether this matcher references AX role/subrole — lets the
    /// adapter skip the AX probe when no rule needs it.
    public var needsAXRole: Bool { role != nil || subrole != nil }

    /// True iff every specified key matches `p`. An unconstrained
    /// matcher never matches.
    public func matches(_ p: WindowProbe) -> Bool {
        guard isConstrained else { return false }
        if let app, !Self.regexMatches(app, p.bundleId ?? "") { return false }
        if let title, !Self.regexMatches(title, p.title) { return false }
        if let role, role != (p.role ?? "") { return false }
        if let subrole, subrole != (p.subrole ?? "") { return false }
        if let maxWidth {
            guard let s = p.size, Double(s.width) <= maxWidth else {
                return false
            }
        }
        if let maxHeight {
            guard let s = p.size, Double(s.height) <= maxHeight else {
                return false
            }
        }
        return true
    }

    /// Invalid patterns can't match (no crash) — consistent with the
    /// TOML parser's "a typo only loses that one thing" stance.
    static func regexMatches(_ pattern: String, _ subject: String) -> Bool {
        subject.range(of: pattern, options: .regularExpression) != nil
    }
}
