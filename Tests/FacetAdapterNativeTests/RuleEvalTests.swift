import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `[[rule]]` adopt-rule evaluation (#282/#286 Phase 3, PR-B). These pin the
/// pure `ruleApplyOps` multi-match accumulation + the `compiledRules`
/// malformed-skip; the full `refreshCatalog` adopt path runs through
/// AX/CGWindowList (host-verified, not CI). `NativeAdapter(config:)` does only
/// read-only SkyLight reads in init; the ordinal is forced to 1 for determinism.
/// CI-only (no XCTest on CommandLineTools).
final class RuleEvalTests: XCTestCase {

    private func adapter(_ rules: [Rule]) -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.rules = rules
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        return a
    }

    func testSingleRuleMatchAccumulatesItsApply() {
        let a = adapter([Rule(match: "app=Safari",
                              apply: [.addTag("web"), .setFloating(true)])])
        let w = window(10, appName: "Safari")
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil),
                       [.addTag("web"), .setFloating(true)])
    }

    func testNoMatchYieldsEmpty() {
        let a = adapter([Rule(match: "app=Safari", apply: [.addTag("web")])])
        let w = window(20, appName: "Slack")
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil), [])
    }

    func testMultiMatchAccumulatesInDeclarationOrder() {
        // A window matching several rules accumulates EVERY rule's apply, in
        // declaration order.
        let a = adapter([
            Rule(match: "app=Safari", apply: [.addTag("web")]),
            Rule(match: "app~=Safari", apply: [.addTag("browser"), .setSticky(true)]),
        ])
        let w = window(10, appName: "Safari")   // matches both (exact + token)
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil),
                       [.addTag("web"), .addTag("browser"), .setSticky(true)])
    }

    func testMultiMatchSetWorkspaceAccumulatesInDeclarationOrder() {
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
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil),
                       [.setWorkspace("A"), .setWorkspace("B")])
    }

    func testMalformedRuleDroppedOthersStillRun() {
        // `tag~web` is malformed (`~` not followed by `=`) → dropped from
        // compiledRules (loud + non-fatal). The valid sibling still matches —
        // and because eval is post-adoption, role-auto-float is untouched.
        let a = adapter([
            Rule(match: "tag~web", apply: [.addTag("bad")]),
            Rule(match: "app=Safari", apply: [.addTag("web")]),
        ])
        XCTAssertEqual(a.compiledRules().count, 1)
        XCTAssertEqual(a.compiledRules().first?.rule.match, "app=Safari")
        let w = window(10, appName: "Safari")
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil), [.addTag("web")])
    }

    func testEmptyWhenNoRules() {
        let a = adapter([])
        let w = window(10, appName: "Safari")
        XCTAssertEqual(a.ruleApplyOps(for: w, inWorkspaceNamed: nil), [])
    }

    /// The role-auto-float HARD guard (#286). `[[rule]]` eval lives in
    /// `refreshCatalog` AFTER the classify gate (post-adoption), never inside
    /// it, so a malformed rule cannot disturb role-auto-float of a sheet /
    /// dialog by construction: it compiles to nothing and yields zero ops for
    /// ANY window, leaving the gate's float verdict untouched.
    func testMalformedOnlyRuleSetIsNoOp() {
        let a = adapter([Rule(match: "tag~web",            // malformed
                              apply: [.addTag("bad"), .setFloating(false)])])
        XCTAssertTrue(a.compiledRules().isEmpty,
                      "a malformed rule is dropped before the adopt loop")
        XCTAssertEqual(a.ruleApplyOps(for: window(1, appName: "Safari"),
                                      inWorkspaceNamed: nil), [])
        XCTAssertEqual(a.ruleApplyOps(for: window(2, appName: "System Settings"),
                                      inWorkspaceNamed: nil), [])
    }
}
