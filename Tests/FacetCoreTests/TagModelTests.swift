import CoreGraphics
import XCTest
@testable import FacetCore

final class TagModelTests: XCTestCase {

    private let model = TagModel(["work", "web", "media"])

    // MARK: - TagModel bit mapping

    func testBitByDeclarationOrder() {
        XCTAssertEqual(model.bit(for: "work"), 0b001)
        XCTAssertEqual(model.bit(for: "web"), 0b010)
        XCTAssertEqual(model.bit(for: "media"), 0b100)
        XCTAssertNil(model.bit(for: "nope"))
    }

    func testMaskUnionsKnownNamesAndIgnoresUnknown() {
        XCTAssertEqual(model.mask(for: ["work", "media"]), 0b101)
        XCTAssertEqual(model.mask(for: ["web", "ghost"]), 0b010)
        XCTAssertEqual(model.mask(for: []), 0)
    }

    func testAllMask() {
        XCTAssertEqual(model.mask(for: model.names), model.allMask)
        XCTAssertEqual(model.allMask, 0b111)
        XCTAssertEqual(TagModel([]).allMask, 0)
        XCTAssertEqual(TagModel(["a"]).allMask, 0b1)
    }

    func testFirstBit() {
        XCTAssertEqual(model.firstBit, 0b001)
        XCTAssertNil(TagModel([]).firstBit)
    }

    func testPrimaryNameIsLowestSetBit() {
        XCTAssertEqual(model.primaryName(of: 0b110), "web")   // web < media
        XCTAssertEqual(model.primaryName(of: 0b100), "media")
        XCTAssertEqual(model.primaryName(of: 0b111), "work")
        XCTAssertNil(model.primaryName(of: 0))
    }

    func testNamesInMaskAreDeclarationOrder() {
        XCTAssertEqual(model.names(in: 0b101), ["work", "media"])
        XCTAssertEqual(model.names(in: 0b111), ["work", "web", "media"])
        XCTAssertEqual(model.names(in: 0), [])
    }

    func testEmptyModel() {
        let m = TagModel([])
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.count, 0)
        XCTAssertNil(m.primaryName(of: 0b1))
    }

    func testReservesTopBitForDefaultFloor() {
        XCTAssertEqual(TagModel.defaultBit, UInt64(1) << 63)
        XCTAssertEqual(TagModel.maxUserTags, 63)
        let many = (0..<100).map { "t\($0)" }
        let m = TagModel(many)
        XCTAssertEqual(m.count, 63)                 // bit 63 reserved
        XCTAssertEqual(m.bit(for: "t0"), 1)
        XCTAssertEqual(m.bit(for: "t62"), UInt64(1) << 62)
        XCTAssertNil(m.bit(for: "t63"))             // dropped (reserved)
        // allMask is the user-tag union (bits 0...62) — never the floor.
        XCTAssertEqual(m.allMask, TagModel.defaultBit - 1)
        XCTAssertEqual(m.allMask & TagModel.defaultBit, 0)
    }

    // MARK: - AssignRules

    private func probe(bundle: String? = nil, title: String = "") -> WindowProbe {
        WindowProbe(bundleId: bundle, title: title)
    }

    func testAssignUnionsAllMatchingRules() {
        let rules = AssignRules([
            AssignRule(matcher: WindowMatcher(app: "Chrome"), tags: ["web"]),
            AssignRule(matcher: WindowMatcher(title: "GitHub"),
                       tags: ["work"]),
        ])
        // Both rules match → union of tags (not first-match like exclude).
        let p = probe(bundle: "com.google.Chrome", title: "GitHub")
        XCTAssertEqual(rules.tags(for: p), ["web", "work"])
        XCTAssertEqual(rules.mask(for: p, in: model), 0b011)
    }

    func testAssignDeDupesAcrossRules() {
        let rules = AssignRules([
            AssignRule(matcher: WindowMatcher(app: "Chrome"),
                       tags: ["web", "work"]),
            AssignRule(matcher: WindowMatcher(title: "x"), tags: ["web"]),
        ])
        let p = probe(bundle: "Chrome", title: "x")
        XCTAssertEqual(rules.tags(for: p), ["web", "work"])  // web once
    }

    func testAssignEmptyWhenNoRuleMatches() {
        let rules = AssignRules([
            AssignRule(matcher: WindowMatcher(app: "Chrome"), tags: ["web"]),
        ])
        XCTAssertEqual(rules.tags(for: probe(bundle: "Safari")), [])
        XCTAssertEqual(rules.mask(for: probe(bundle: "Safari"), in: model), 0)
    }

    func testAssignMaskDropsUnknownTag() {
        let rules = AssignRules([
            AssignRule(matcher: WindowMatcher(app: "X"),
                       tags: ["web", "ghost"]),
        ])
        // "ghost" not in model → dropped from the mask.
        XCTAssertEqual(rules.mask(for: probe(bundle: "X"), in: model), 0b010)
    }

    // MARK: - WindowMatcher (shared by [[exclude]] and [[assign]])

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
