import CoreGraphics
import XCTest
@testable import FacetCore

final class ExclusionRulesTests: XCTestCase {

    private func probe(bundle: String? = nil, title: String = "",
                       role: String? = nil, subrole: String? = nil,
                       size: CGSize? = nil) -> WindowProbe {
        WindowProbe(bundleId: bundle, title: title,
                    role: role, subrole: subrole, size: size)
    }

    func testNoRulesMatchesNothing() {
        let r = ExclusionRules([])
        XCTAssertNil(r.action(for: probe(bundle: "com.apple.finder")))
        XCTAssertTrue(r.isEmpty)
    }

    func testEmptyRuleNeverMatches() {
        // A rule with no constraints must not silently drop windows.
        let r = ExclusionRules([ExclusionRule(action: .ignore)])
        XCTAssertNil(r.action(for: probe(bundle: "anything", title: "x")))
    }

    func testAppRegexMatch() {
        let r = ExclusionRules([
            ExclusionRule(app: #"^com\.apple\.finder$"#, action: .float),
        ])
        XCTAssertEqual(r.action(for: probe(bundle: "com.apple.finder")), .float)
        XCTAssertNil(r.action(for: probe(bundle: "com.apple.Safari")))
        XCTAssertNil(r.action(for: probe(bundle: nil)))
    }

    func testEmptyTitleMatchesUnnamedWindow() {
        let r = ExclusionRules([
            ExclusionRule(title: "^$", action: .ignore),
        ])
        XCTAssertEqual(r.action(for: probe(title: "")), .ignore)
        XCTAssertNil(r.action(for: probe(title: "Untitled")))
    }

    func testKeysWithinRuleAreANDed() {
        let r = ExclusionRules([
            ExclusionRule(app: "Chrome", title: "Save", action: .float),
        ])
        XCTAssertEqual(
            r.action(for: probe(bundle: "com.google.Chrome", title: "Save As")),
            .float)
        // app matches but title doesn't -> no match (AND).
        XCTAssertNil(
            r.action(for: probe(bundle: "com.google.Chrome", title: "GitHub")))
    }

    func testMultipleRulesAreORedFirstWins() {
        let r = ExclusionRules([
            ExclusionRule(app: "Chrome", action: .ignore),
            ExclusionRule(title: "Palette", action: .float),
        ])
        XCTAssertEqual(r.action(for: probe(bundle: "com.google.Chrome")), .ignore)
        XCTAssertEqual(r.action(for: probe(title: "Color Palette")), .float)
        // First match wins: Chrome rule (ignore) precedes a title rule.
        let r2 = ExclusionRules([
            ExclusionRule(app: "Chrome", action: .ignore),
            ExclusionRule(app: "Chrome", action: .float),
        ])
        XCTAssertEqual(r2.action(for: probe(bundle: "com.google.Chrome")), .ignore)
    }

    func testRoleAndSubroleExactMatch() {
        let r = ExclusionRules([
            ExclusionRule(subrole: "AXDialog", action: .float),
        ])
        XCTAssertEqual(
            r.action(for: probe(role: "AXWindow", subrole: "AXDialog")), .float)
        XCTAssertNil(r.action(for: probe(role: "AXWindow", subrole: "AXStandardWindow")))
        // subrole absent (AX not probed) -> role/subrole rule can't match.
        XCTAssertNil(r.action(for: probe(subrole: nil)))
    }

    func testSizeThresholdMatchesSmallWindows() {
        let r = ExclusionRules([
            ExclusionRule(maxWidth: 400, maxHeight: 300, action: .ignore),
        ])
        XCTAssertEqual(
            r.action(for: probe(size: CGSize(width: 200, height: 150))), .ignore)
        // Too wide -> no match.
        XCTAssertNil(
            r.action(for: probe(size: CGSize(width: 800, height: 150))))
        // Size unknown (no frame) -> size rule can't match.
        XCTAssertNil(r.action(for: probe(size: nil)))
    }

    func testNeedsAXRoleReporting() {
        XCTAssertFalse(ExclusionRule(app: "x").needsAXRole)
        XCTAssertTrue(ExclusionRule(role: "AXWindow").needsAXRole)
        XCTAssertTrue(ExclusionRule(subrole: "AXDialog").needsAXRole)
        XCTAssertTrue(ExclusionRules([
            ExclusionRule(app: "x"), ExclusionRule(subrole: "AXDialog"),
        ]).anyNeedsAXRole)
        XCTAssertFalse(ExclusionRules([ExclusionRule(app: "x")]).anyNeedsAXRole)
    }

    // MARK: - WindowMatcher (the shared matcher; `[[exclude]]`'s sole
    // consumer since `[[assign]]` was retired in #191)

    func testUnconstrainedMatcherNeverMatches() {
        XCTAssertFalse(WindowMatcher().isConstrained)
        XCTAssertFalse(WindowMatcher().matches(probe(bundle: "any", title: "x")))
    }

    func testMatcherANDsKeys() {
        let m = WindowMatcher(app: "Chrome", title: "Save")
        XCTAssertTrue(m.matches(probe(bundle: "Chrome", title: "Save As")))
        XCTAssertFalse(m.matches(probe(bundle: "Chrome", title: "Open")))
        XCTAssertFalse(m.matches(probe(bundle: "Safari", title: "Save As")))
    }

    func testMatcherNeedsAXRole() {
        XCTAssertTrue(WindowMatcher(role: "AXWindow").needsAXRole)
        XCTAssertTrue(WindowMatcher(subrole: "AXDialog").needsAXRole)
        XCTAssertFalse(WindowMatcher(app: "X").needsAXRole)
    }
}
