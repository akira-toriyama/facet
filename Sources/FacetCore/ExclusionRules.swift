// Window exclusion / float rules (config-driven), pure logic.
//
// facet auto-floats sheets / dialogs / palettes by AX role already
// (`AXGeom.isFloatingByRole`, consumed by the native adapter). But a
// window that *looks* like a normal window to AX — an unnamed popup,
// a small auxiliary panel — still gets tiled and disrupts the layout.
// `[[exclude]]` rules in config.toml let the user match such windows
// by app / title / role / subrole / size and either float them
// (keep tracking, still shown in the tree) or ignore them entirely
// (fully unmanaged, like yabai's `manage=off`).
//
// This file is the *matcher*: pure, backend-neutral, unit-testable.
// The adapter supplies a `WindowProbe` (the AX role/subrole come from
// its on-demand probe; bundleId/title/size from the window model) and
// gets back the action for the first matching rule.

import CoreGraphics
import Foundation

/// What to do with a window a rule matches.
public enum ExclusionAction: String, Sendable, Equatable {
    /// Float it: still tracked + shown in the tree, just not tiled
    /// (same lane as the built-in role auto-float). Good for a
    /// persistent auxiliary palette.
    case float
    /// Drop it entirely: never enters a workspace, never shown.
    /// Good for transient popups. Mirrors yabai `manage=off`.
    case ignore
}

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

/// One `[[exclude]]` table. Keys within a rule are ANDed; an
/// unspecified key is not a constraint. A rule with no constraints
/// matches nothing (guards against a blank `[[exclude]]` silently
/// dropping every window).
public struct ExclusionRule: Sendable, Equatable {
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
    public let action: ExclusionAction

    public init(app: String? = nil, title: String? = nil,
                role: String? = nil, subrole: String? = nil,
                maxWidth: Double? = nil, maxHeight: Double? = nil,
                action: ExclusionAction = .float) {
        self.app = app
        self.title = title
        self.role = role
        self.subrole = subrole
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.action = action
    }

    /// True iff every specified key matches `p`. A rule with no keys
    /// never matches.
    public func matches(_ p: WindowProbe) -> Bool {
        var constrained = false
        if let app {
            constrained = true
            if !Self.regexMatches(app, p.bundleId ?? "") { return false }
        }
        if let title {
            constrained = true
            if !Self.regexMatches(title, p.title) { return false }
        }
        if let role {
            constrained = true
            if role != (p.role ?? "") { return false }
        }
        if let subrole {
            constrained = true
            if subrole != (p.subrole ?? "") { return false }
        }
        if let maxWidth {
            constrained = true
            guard let s = p.size, Double(s.width) <= maxWidth else {
                return false
            }
        }
        if let maxHeight {
            constrained = true
            guard let s = p.size, Double(s.height) <= maxHeight else {
                return false
            }
        }
        return constrained
    }

    /// Whether this rule references AX role/subrole — lets the
    /// adapter skip the AX probe when no rule needs it.
    public var needsAXRole: Bool { role != nil || subrole != nil }

    /// Invalid patterns can't match (no crash) — consistent with the
    /// TOML parser's "a typo only loses that one thing" stance.
    static func regexMatches(_ pattern: String, _ subject: String) -> Bool {
        subject.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Ordered rule set. First matching rule wins (file order = priority).
public struct ExclusionRules: Sendable, Equatable {
    public let rules: [ExclusionRule]
    public init(_ rules: [ExclusionRule] = []) { self.rules = rules }

    public var isEmpty: Bool { rules.isEmpty }

    /// Whether any rule references AX role/subrole.
    public var anyNeedsAXRole: Bool { rules.contains(where: \.needsAXRole) }

    /// The action of the first rule that matches `p`, or `nil` when
    /// none match (window is managed normally).
    public func action(for p: WindowProbe) -> ExclusionAction? {
        for r in rules where r.matches(p) { return r.action }
        return nil
    }
}
