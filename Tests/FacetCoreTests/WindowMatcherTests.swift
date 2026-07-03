import Testing
import CoreGraphics
@testable import FacetCore

/// `WindowMatcher` — the pure `[[exclude]]` matcher: app/title regex +
/// role/subrole exact + size cap, all ANDed. Backend-neutral, so directly
/// unit-testable; it was previously only exercised transitively through
/// `ExclusionRulesTests`. These pin the matching semantics (search-not-
/// anchored regex, exact role, inclusive size cap, AND, invalid-regex
/// safety) — each is documented intent in the source, not incidental.
struct WindowMatcherTests {

    private func probe(bundleId: String? = "com.apple.Safari",
                       title: String = "Untitled",
                       role: String? = nil, subrole: String? = nil,
                       size: CGSize? = nil) -> WindowProbe {
        WindowProbe(bundleId: bundleId, title: title,
                    role: role, subrole: subrole, size: size)
    }

    // MARK: - unconstrained guard

    @Test func unconstrainedMatcherNeverMatches() {
        let m = WindowMatcher()
        #expect(!m.isConstrained)
        #expect(!m.matches(probe()))
    }

    @Test func isConstrainedTrueWhenAnyKeySet() {
        #expect(WindowMatcher(app: "x").isConstrained)
        #expect(WindowMatcher(maxHeight: 1).isConstrained)
    }

    // MARK: - app (bundle id regex, search-not-anchored)

    @Test func appRegexIsSearchNotAnchored() {
        let m = WindowMatcher(app: "Safari")
        #expect(m.matches(probe(bundleId: "com.apple.Safari")))
        #expect(m.matches(probe(bundleId: "Safari")))
    }

    @Test func appRegexAnchoredWithCaretDollar() {
        let m = WindowMatcher(app: "^com\\.apple\\.Safari$")
        #expect(m.matches(probe(bundleId: "com.apple.Safari")))
        #expect(!m.matches(probe(bundleId: "com.apple.SafariTech")))
    }

    @Test func appNilBundleIdTreatedAsEmptyString() {
        #expect(!WindowMatcher(app: "Safari").matches(probe(bundleId: nil)))
        #expect(WindowMatcher(app: "^$").matches(probe(bundleId: nil)))
    }

    // MARK: - title (regex; empty title matched by ^$)

    @Test func titleRegexSubstring() {
        #expect(WindowMatcher(title: "Inbox")
            .matches(probe(title: "Inbox — 3 unread")))
        #expect(!WindowMatcher(title: "Inbox").matches(probe(title: "Drafts")))
    }

    @Test func emptyTitleMatchedByAnchoredEmpty() {
        #expect(WindowMatcher(title: "^$").matches(probe(title: "")))
        #expect(!WindowMatcher(title: "^$").matches(probe(title: "x")))
    }

    // MARK: - role / subrole (exact; nil probe == "")

    @Test func roleExactMatchAndUnprobedNoMatch() {
        let m = WindowMatcher(role: "AXWindow")
        #expect(m.matches(probe(role: "AXWindow")))
        #expect(!m.matches(probe(role: "AXSheet")))
        #expect(!m.matches(probe(role: nil)))   // unprobed → no match
    }

    @Test func subroleExactMatchAndUnprobedNoMatch() {
        let m = WindowMatcher(subrole: "AXDialog")
        #expect(m.matches(probe(subrole: "AXDialog")))
        #expect(!m.matches(probe(subrole: nil)))
    }

    @Test func needsAXRoleFlag() {
        #expect(!WindowMatcher(app: "x").needsAXRole)
        #expect(WindowMatcher(role: "AXWindow").needsAXRole)
        #expect(WindowMatcher(subrole: "AXDialog").needsAXRole)
    }

    // MARK: - size caps (≤ limit, inclusive; nil size never satisfies)

    @Test func maxWidthInclusiveAndNeedsSize() {
        let m = WindowMatcher(maxWidth: 400)
        #expect(m.matches(probe(size: CGSize(width: 400, height: 999))))  // inclusive
        #expect(m.matches(probe(size: CGSize(width: 200, height: 999))))
        #expect(!m.matches(probe(size: CGSize(width: 401, height: 10))))
        #expect(!m.matches(probe(size: nil)))   // unknown size → can't satisfy
    }

    @Test func maxHeightInclusiveAndNeedsSize() {
        let m = WindowMatcher(maxHeight: 300)
        #expect(m.matches(probe(size: CGSize(width: 9, height: 300))))
        #expect(!m.matches(probe(size: CGSize(width: 9, height: 301))))
        #expect(!m.matches(probe(size: nil)))
    }

    // MARK: - AND semantics (every specified key must hold)

    @Test func allKeysMustHold() {
        let m = WindowMatcher(app: "Safari", title: "Inbox", maxWidth: 500)
        let ok = probe(bundleId: "com.apple.Safari", title: "Inbox",
                       size: CGSize(width: 400, height: 1))
        #expect(m.matches(ok))
        // each single-key failure flips the whole match to false
        #expect(!m.matches(probe(bundleId: "com.apple.Safari",
            title: "Drafts", size: CGSize(width: 400, height: 1))))
        #expect(!m.matches(probe(bundleId: "com.google.Chrome",
            title: "Inbox", size: CGSize(width: 400, height: 1))))
        #expect(!m.matches(probe(bundleId: "com.apple.Safari",
            title: "Inbox", size: CGSize(width: 600, height: 1))))
    }

    // MARK: - invalid regex (no crash, no match)

    @Test func invalidPatternDoesNotCrashOrMatch() {
        #expect(!WindowMatcher.regexMatches("[unterminated", "anything"))
        #expect(!WindowMatcher(app: "[bad(").matches(probe(bundleId: "x")))
    }

    // MARK: - Equatable (value semantics, used by rule dedup / reload diff)

    @Test func equatable() {
        #expect(WindowMatcher(app: "x", maxWidth: 10) ==
                       WindowMatcher(app: "x", maxWidth: 10))
        #expect(WindowMatcher(app: "x") != WindowMatcher(app: "y"))
    }
}
