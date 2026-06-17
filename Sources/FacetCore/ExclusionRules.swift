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
// The matching itself lives in `WindowMatcher` (`[[exclude]]`-only
// since `[[assign]]` was retired in #191); this file is the exclusion
// *policy* on top of it (the action + first-match-wins rule set).
// Pure, backend-neutral, unit-testable.

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
    /// Force-manage (tile) it even though the allowlist gate would
    /// otherwise float/ignore it — for a real window an app
    /// mislabels (non-`AXStandardWindow` subrole, off-normal level).
    /// The inverse escape hatch; mirrors yabai's `WINDOW_RULE_MANAGED`.
    case manage
}

/// One `[[exclude]]` table: a `WindowMatcher` plus the action to take
/// on a window it matches. Keys within the matcher are ANDed; a rule
/// with no constraints matches nothing (guards against a blank
/// `[[exclude]]` silently dropping every window).
public struct ExclusionRule: Sendable, Equatable {
    public let matcher: WindowMatcher
    public let action: ExclusionAction

    public init(matcher: WindowMatcher,
                action: ExclusionAction = .float) {
        self.matcher = matcher
        self.action = action
    }

    /// Convenience init with the match keys flat — preserves the
    /// original call sites (config parser, tests) unchanged.
    public init(app: String? = nil, title: String? = nil,
                role: String? = nil, subrole: String? = nil,
                maxWidth: Double? = nil, maxHeight: Double? = nil,
                action: ExclusionAction = .float) {
        self.init(matcher: WindowMatcher(app: app, title: title,
                                         role: role, subrole: subrole,
                                         maxWidth: maxWidth,
                                         maxHeight: maxHeight),
                  action: action)
    }

    /// True iff the matcher's constraints all hold for `p`.
    public func matches(_ p: WindowProbe) -> Bool { matcher.matches(p) }

    /// Whether this rule references AX role/subrole — lets the
    /// adapter skip the AX probe when no rule needs it.
    public var needsAXRole: Bool { matcher.needsAXRole }
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
