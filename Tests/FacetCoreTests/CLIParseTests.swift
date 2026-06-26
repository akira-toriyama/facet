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

    // MARK: - §E validateSectionLabel (loose display-label policy)

    func testValidateSectionLabel_PlainLabel() {
        XCTAssertEqual(validateSectionLabel("Web"), .success("Web"))
    }

    func testValidateSectionLabel_AllowsSpacesAndPunctuation() {
        // Display labels are config strings — spaces / punctuation kept verbatim.
        XCTAssertEqual(validateSectionLabel("My Lens!"), .success("My Lens!"))
    }

    func testValidateSectionLabel_AllowsColonVerbatim() {
        XCTAssertEqual(validateSectionLabel("with: colon"),
                       .success("with: colon"))
    }

    func testValidateSectionLabel_EmptyAllowedAsRevertGesture() {
        // Truly empty = the explicit "revert to number / config label" gesture
        // the server resolver acts on; allowed (not a typo).
        XCTAssertEqual(validateSectionLabel(""), .success(""))
    }

    func testValidateSectionLabel_RejectsAllWhitespace() {
        XCTAssertEqual(validateSectionLabel("   "),
                       .failure(.unknownValue(value: "   ", expected: [])))
    }

    func testValidateSectionLabel_RejectsLoneDash() {
        XCTAssertEqual(validateSectionLabel("-"),
                       .failure(.unknownValue(value: "-", expected: [])))
    }

    func testValidateSectionLabel_RejectsLeadingDashValue() {
        // ANY leading-dash value is rejected (flag-guard parity with
        // `parseLensSectionLabel` / `CLIName`): `--rename`'s LABEL is consumed
        // unconditionally, so a mistyped flag (`--focus`) lands here as the
        // value — reject it loudly instead of renaming to the flag string.
        XCTAssertEqual(validateSectionLabel("-x"),
                       .failure(.unknownValue(value: "-x", expected: [])))
        XCTAssertEqual(validateSectionLabel("--focus"),
                       .failure(.unknownValue(value: "--focus", expected: [])))
    }

    func testValidateSectionLabel_PreservesLeadingTrailingSpacesVerbatim() {
        // The success value is kept VERBATIM (untrimmed) — the trim is only for
        // the reject guard. Normalization (the actual trim of a stored label)
        // happens at the server's store site, not here.
        XCTAssertEqual(validateSectionLabel(" Web "), .success(" Web "))
    }

    // MARK: - §E section-rename wire encode / decode round-trip

    func testEncodeSectionRename_BasicForm() {
        XCTAssertEqual(encodeSectionRename(index: 2, label: "Web"),
                       "section-rename:2:Web")
    }

    func testDecodeSectionRename_RoundTrip() {
        let wire = encodeSectionRename(index: 3, label: "My Lens")
        let got = decodeSectionRename(wire)
        XCTAssertEqual(got?.index, 3)
        XCTAssertEqual(got?.label, "My Lens")
    }

    func testDecodeSectionRename_LabelWithColonSurvivesVerbatim() {
        // The label half may contain ':' — split ONCE so it stays intact.
        let wire = encodeSectionRename(index: 1, label: "with: colon")
        let got = decodeSectionRename(wire)
        XCTAssertEqual(got?.index, 1)
        XCTAssertEqual(got?.label, "with: colon")
    }

    func testDecodeSectionRename_EmptyLabelDecodes() {
        let got = decodeSectionRename("section-rename:5:")
        XCTAssertEqual(got?.index, 5)
        XCTAssertEqual(got?.label, "")
    }

    func testDecodeSectionRename_AcceptsBodyWithoutPrefix() {
        // The decoder strips the prefix if present, else treats the whole
        // string as the body (the dispatch passes the full payload).
        let got = decodeSectionRename("4:Mail")
        XCTAssertEqual(got?.index, 4)
        XCTAssertEqual(got?.label, "Mail")
    }

    func testDecodeSectionRename_RejectsNonIntegerIndex() {
        XCTAssertNil(decodeSectionRename("section-rename:x:Web"))
    }

    func testDecodeSectionRename_RejectsZeroIndex() {
        XCTAssertNil(decodeSectionRename("section-rename:0:Web"))
    }

    func testDecodeSectionRename_RejectsNegativeIndex() {
        // "-1" parses as Int but is < 1; the leading-dash split keeps "-1"
        // whole (one ':' only), so it's the index half → rejected.
        XCTAssertNil(decodeSectionRename("section-rename:-1:Web"))
    }

    func testDecodeSectionRename_RejectsMissingColon() {
        XCTAssertNil(decodeSectionRename("section-rename:2"))
    }
}
