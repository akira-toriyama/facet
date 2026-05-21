// Tests for FacetCore's pure CLI parse helpers (no AppKit, no
// stderr/exit side-effects). The FacetApp layer wraps these with
// the actual stderr writes + exit(2); contract is just here.

import XCTest
@testable import FacetCore

final class CLIParseTests: XCTestCase {

    // MARK: - parseGeomInt

    func testParseGeomInt_PlainInteger() {
        XCTAssertEqual(parseGeomInt("123"), .success(123))
    }

    func testParseGeomInt_NegativeAllowedByDefault() {
        // --pos-x / --pos-y can legitimately be negative on
        // multi-monitor setups.
        XCTAssertEqual(parseGeomInt("-50"), .success(-50))
    }

    func testParseGeomInt_TrimsWhitespace() {
        XCTAssertEqual(parseGeomInt("  42  "), .success(42))
    }

    func testParseGeomInt_RejectsNonInteger() {
        XCTAssertEqual(parseGeomInt("abc"),
                       .failure(.notAnInteger(value: "abc")))
    }

    func testParseGeomInt_RejectsEmpty() {
        XCTAssertEqual(parseGeomInt(""),
                       .failure(.notAnInteger(value: "")))
    }

    func testParseGeomInt_RequirePositive_RejectsZero() {
        XCTAssertEqual(parseGeomInt("0", requirePositive: true),
                       .failure(.notPositive(value: 0)))
    }

    func testParseGeomInt_RequirePositive_RejectsNegative() {
        XCTAssertEqual(parseGeomInt("-5", requirePositive: true),
                       .failure(.notPositive(value: -5)))
    }

    func testParseGeomInt_RequirePositive_AcceptsPositive() {
        XCTAssertEqual(parseGeomInt("100", requirePositive: true),
                       .success(100))
    }

    // MARK: - canonicalize

    func testCanonicalize_ExactMatch() {
        XCTAssertEqual(canonicalize("tree", allowed: ["tree", "grid"]),
                       .success("tree"))
    }

    func testCanonicalize_LowercasesInput() {
        XCTAssertEqual(canonicalize("TREE", allowed: ["tree", "grid"]),
                       .success("tree"))
    }

    func testCanonicalize_TrimsWhitespace() {
        XCTAssertEqual(canonicalize("  grid ", allowed: ["tree", "grid"]),
                       .success("grid"))
    }

    func testCanonicalize_RejectsUnknown_ReportsExpected() {
        XCTAssertEqual(
            canonicalize("xyz", allowed: ["tree", "grid"]),
            .failure(.unknownValue(value: "xyz",
                                   expected: ["tree", "grid"])))
    }

    // MARK: - validateGeom

    func testValidateGeom_AllNil_None() {
        XCTAssertEqual(validateGeom(posX: nil, posY: nil,
                                    width: nil, height: nil), .none)
    }

    func testValidateGeom_AllSet_Complete() {
        XCTAssertEqual(
            validateGeom(posX: 100, posY: 200, width: 400, height: 600),
            .complete(x: 100, y: 200, w: 400, h: 600))
    }

    func testValidateGeom_OneMissing_Partial() {
        XCTAssertEqual(
            validateGeom(posX: 100, posY: 200, width: 400, height: nil),
            .partial(count: 3))
    }

    func testValidateGeom_OnlyOne_Partial() {
        XCTAssertEqual(
            validateGeom(posX: 100, posY: nil, width: nil, height: nil),
            .partial(count: 1))
    }
}
