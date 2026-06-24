import XCTest
import CoreGraphics
@testable import FacetCore

/// `WindowMatcher` — the pure `[[exclude]]` matcher: app/title regex +
/// role/subrole exact + size cap, all ANDed. Backend-neutral, so directly
/// unit-testable; it was previously only exercised transitively through
/// `ExclusionRulesTests`. These pin the matching semantics (search-not-
/// anchored regex, exact role, inclusive size cap, AND, invalid-regex
/// safety) — each is documented intent in the source, not incidental.
final class WindowMatcherTests: XCTestCase {

    private func probe(bundleId: String? = "com.apple.Safari",
                       title: String = "Untitled",
                       role: String? = nil, subrole: String? = nil,
                       size: CGSize? = nil) -> WindowProbe {
        WindowProbe(bundleId: bundleId, title: title,
                    role: role, subrole: subrole, size: size)
    }

    // MARK: - unconstrained guard

    func testUnconstrainedMatcherNeverMatches() {
        let m = WindowMatcher()
        XCTAssertFalse(m.isConstrained)
        XCTAssertFalse(m.matches(probe()))
    }

    func testIsConstrainedTrueWhenAnyKeySet() {
        XCTAssertTrue(WindowMatcher(app: "x").isConstrained)
        XCTAssertTrue(WindowMatcher(maxHeight: 1).isConstrained)
    }

    // MARK: - app (bundle id regex, search-not-anchored)

    func testAppRegexIsSearchNotAnchored() {
        let m = WindowMatcher(app: "Safari")
        XCTAssertTrue(m.matches(probe(bundleId: "com.apple.Safari")))
        XCTAssertTrue(m.matches(probe(bundleId: "Safari")))
    }

    func testAppRegexAnchoredWithCaretDollar() {
        let m = WindowMatcher(app: "^com\\.apple\\.Safari$")
        XCTAssertTrue(m.matches(probe(bundleId: "com.apple.Safari")))
        XCTAssertFalse(m.matches(probe(bundleId: "com.apple.SafariTech")))
    }

    func testAppNilBundleIdTreatedAsEmptyString() {
        XCTAssertFalse(WindowMatcher(app: "Safari").matches(probe(bundleId: nil)))
        XCTAssertTrue(WindowMatcher(app: "^$").matches(probe(bundleId: nil)))
    }

    // MARK: - title (regex; empty title matched by ^$)

    func testTitleRegexSubstring() {
        XCTAssertTrue(WindowMatcher(title: "Inbox")
            .matches(probe(title: "Inbox — 3 unread")))
        XCTAssertFalse(WindowMatcher(title: "Inbox").matches(probe(title: "Drafts")))
    }

    func testEmptyTitleMatchedByAnchoredEmpty() {
        XCTAssertTrue(WindowMatcher(title: "^$").matches(probe(title: "")))
        XCTAssertFalse(WindowMatcher(title: "^$").matches(probe(title: "x")))
    }

    // MARK: - role / subrole (exact; nil probe == "")

    func testRoleExactMatchAndUnprobedNoMatch() {
        let m = WindowMatcher(role: "AXWindow")
        XCTAssertTrue(m.matches(probe(role: "AXWindow")))
        XCTAssertFalse(m.matches(probe(role: "AXSheet")))
        XCTAssertFalse(m.matches(probe(role: nil)))   // unprobed → no match
    }

    func testSubroleExactMatchAndUnprobedNoMatch() {
        let m = WindowMatcher(subrole: "AXDialog")
        XCTAssertTrue(m.matches(probe(subrole: "AXDialog")))
        XCTAssertFalse(m.matches(probe(subrole: nil)))
    }

    func testNeedsAXRoleFlag() {
        XCTAssertFalse(WindowMatcher(app: "x").needsAXRole)
        XCTAssertTrue(WindowMatcher(role: "AXWindow").needsAXRole)
        XCTAssertTrue(WindowMatcher(subrole: "AXDialog").needsAXRole)
    }

    // MARK: - size caps (≤ limit, inclusive; nil size never satisfies)

    func testMaxWidthInclusiveAndNeedsSize() {
        let m = WindowMatcher(maxWidth: 400)
        XCTAssertTrue(m.matches(probe(size: CGSize(width: 400, height: 999))))  // inclusive
        XCTAssertTrue(m.matches(probe(size: CGSize(width: 200, height: 999))))
        XCTAssertFalse(m.matches(probe(size: CGSize(width: 401, height: 10))))
        XCTAssertFalse(m.matches(probe(size: nil)))   // unknown size → can't satisfy
    }

    func testMaxHeightInclusiveAndNeedsSize() {
        let m = WindowMatcher(maxHeight: 300)
        XCTAssertTrue(m.matches(probe(size: CGSize(width: 9, height: 300))))
        XCTAssertFalse(m.matches(probe(size: CGSize(width: 9, height: 301))))
        XCTAssertFalse(m.matches(probe(size: nil)))
    }

    // MARK: - AND semantics (every specified key must hold)

    func testAllKeysMustHold() {
        let m = WindowMatcher(app: "Safari", title: "Inbox", maxWidth: 500)
        let ok = probe(bundleId: "com.apple.Safari", title: "Inbox",
                       size: CGSize(width: 400, height: 1))
        XCTAssertTrue(m.matches(ok))
        // each single-key failure flips the whole match to false
        XCTAssertFalse(m.matches(probe(bundleId: "com.apple.Safari",
            title: "Drafts", size: CGSize(width: 400, height: 1))))
        XCTAssertFalse(m.matches(probe(bundleId: "com.google.Chrome",
            title: "Inbox", size: CGSize(width: 400, height: 1))))
        XCTAssertFalse(m.matches(probe(bundleId: "com.apple.Safari",
            title: "Inbox", size: CGSize(width: 600, height: 1))))
    }

    // MARK: - invalid regex (no crash, no match)

    func testInvalidPatternDoesNotCrashOrMatch() {
        XCTAssertFalse(WindowMatcher.regexMatches("[unterminated", "anything"))
        XCTAssertFalse(WindowMatcher(app: "[bad(").matches(probe(bundleId: "x")))
    }

    // MARK: - Equatable (value semantics, used by rule dedup / reload diff)

    func testEquatable() {
        XCTAssertEqual(WindowMatcher(app: "x", maxWidth: 10),
                       WindowMatcher(app: "x", maxWidth: 10))
        XCTAssertNotEqual(WindowMatcher(app: "x"), WindowMatcher(app: "y"))
    }
}
