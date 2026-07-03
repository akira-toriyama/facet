import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// `[[rule]]` adopt-rule evaluation (#282/#286 Phase 3, PR-B). These pin the
/// pure `ruleApplyOps` multi-match accumulation + the `compiledRules`
/// malformed-skip; the full `refreshCatalog` adopt path runs through
/// AX/CGWindowList (host-verified, not CI). `NativeAdapter(config:)` does only
/// read-only SkyLight reads in init; the ordinal is forced to 1 for determinism.
/// CI-only (no XCTest on CommandLineTools).
struct RuleEvalTests {

    private func adapter(_ rules: [Rule]) -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.rules = rules
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        return a
    }

    @Test func singleRuleMatchAccumulatesItsApply() {
        let a = adapter([Rule(match: "app=Safari",
                              apply: [.addTag("web"), .setFloating(true)])])
        let w = window(10, appName: "Safari")
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) ==
                       [.addTag("web"), .setFloating(true)])
    }

    @Test func noMatchYieldsEmpty() {
        let a = adapter([Rule(match: "app=Safari", apply: [.addTag("web")])])
        let w = window(20, appName: "Slack")
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) == [])
    }

    @Test func multiMatchAccumulatesInDeclarationOrder() {
        // A window matching several rules accumulates EVERY rule's apply, in
        // declaration order.
        let a = adapter([
            Rule(match: "app=Safari", apply: [.addTag("web")]),
            Rule(match: "app~=Safari", apply: [.addTag("browser"), .setSticky(true)]),
        ])
        let w = window(10, appName: "Safari")   // matches both (exact + token)
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) ==
                       [.addTag("web"), .addTag("browser"), .setSticky(true)])
    }

    @Test func multiMatchSetWorkspaceAccumulatesInDeclarationOrder() {
        // Two rules each placing the window pin the declaration-order
        // accumulation of `setWorkspace` — the op the glossary's
        // "setWorkspace は単数値 last-wins" claim names. ruleApplyOps returns
        // BOTH in order; the executor (applyRuleOp → moveWindow, host-verified)
        // realizes last-wins by overwriting, so the LAST declared workspace wins.
        let a = adapter([
            Rule(match: "app=Safari", apply: [.setWorkspace("A")]),
            Rule(match: "app~=Safari", apply: [.setWorkspace("B")]),
        ])
        let w = window(10, appName: "Safari")   // matches both (exact + token)
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) ==
                       [.setWorkspace("A"), .setWorkspace("B")])
    }

    @Test func malformedRuleDroppedOthersStillRun() {
        // `tag~web` is malformed (`~` not followed by `=`) → dropped from
        // compiledRules (loud + non-fatal). The valid sibling still matches —
        // and because eval is post-adoption, role-auto-float is untouched.
        let a = adapter([
            Rule(match: "tag~web", apply: [.addTag("bad")]),
            Rule(match: "app=Safari", apply: [.addTag("web")]),
        ])
        #expect(a.compiledRules().count == 1)
        #expect(a.compiledRules().first?.rule.match == "app=Safari")
        let w = window(10, appName: "Safari")
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) == [.addTag("web")])
    }

    @Test func emptyWhenNoRules() {
        let a = adapter([])
        let w = window(10, appName: "Safari")
        #expect(a.ruleApplyOps(for: w, inWorkspaceNamed: nil) == [])
    }

    /// The role-auto-float HARD guard (#286). `[[rule]]` eval lives in
    /// `refreshCatalog` AFTER the classify gate (post-adoption), never inside
    /// it, so a malformed rule cannot disturb role-auto-float of a sheet /
    /// dialog by construction: it compiles to nothing and yields zero ops for
    /// ANY window, leaving the gate's float verdict untouched.
    @Test func malformedOnlyRuleSetIsNoOp() {
        let a = adapter([Rule(match: "tag~web",            // malformed
                              apply: [.addTag("bad"), .setFloating(false)])])
        #expect(a.compiledRules().isEmpty,
                      "a malformed rule is dropped before the adopt loop")
        #expect(a.ruleApplyOps(for: window(1, appName: "Safari"),
                                      inWorkspaceNamed: nil) == [])
        #expect(a.ruleApplyOps(for: window(2, appName: "System Settings"),
                                      inWorkspaceNamed: nil) == [])
    }
}
