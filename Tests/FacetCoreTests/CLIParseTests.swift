// Tests for FacetCore's pure CLI parse helpers (no AppKit, no
// stderr/exit side-effects). The FacetApp layer wraps these with
// the actual stderr writes + exit(2); contract is just here.

import Testing
@testable import FacetCore

struct CLIParseTests {

    // MARK: - parseGeomInt

    @Test func parseGeomInt_PlainInteger() {
        #expect(parseGeomInt("123") == .success(123))
    }

    @Test func parseGeomInt_NegativeAllowedByDefault() {
        // --pos-x / --pos-y can legitimately be negative on
        // multi-monitor setups.
        #expect(parseGeomInt("-50") == .success(-50))
    }

    @Test func parseGeomInt_TrimsWhitespace() {
        #expect(parseGeomInt("  42  ") == .success(42))
    }

    @Test func parseGeomInt_RejectsNonInteger() {
        #expect(parseGeomInt("abc") ==
                       .failure(.notAnInteger(value: "abc")))
    }

    @Test func parseGeomInt_RejectsEmpty() {
        #expect(parseGeomInt("") ==
                       .failure(.notAnInteger(value: "")))
    }

    @Test func parseGeomInt_RequirePositive_RejectsZero() {
        #expect(parseGeomInt("0", requirePositive: true) ==
                       .failure(.notPositive(value: 0)))
    }

    @Test func parseGeomInt_RequirePositive_RejectsNegative() {
        #expect(parseGeomInt("-5", requirePositive: true) ==
                       .failure(.notPositive(value: -5)))
    }

    @Test func parseGeomInt_RequirePositive_AcceptsPositive() {
        #expect(parseGeomInt("100", requirePositive: true) ==
                       .success(100))
    }

    // MARK: - canonicalize

    @Test func canonicalize_ExactMatch() {
        #expect(canonicalize("tree", allowed: ["tree", "grid"]) ==
                       .success("tree"))
    }

    @Test func canonicalize_LowercasesInput() {
        #expect(canonicalize("TREE", allowed: ["tree", "grid"]) ==
                       .success("tree"))
    }

    @Test func canonicalize_TrimsWhitespace() {
        #expect(canonicalize("  grid ", allowed: ["tree", "grid"]) ==
                       .success("grid"))
    }

    @Test func canonicalize_RejectsUnknown_ReportsExpected() {
        #expect(
            canonicalize("xyz", allowed: ["tree", "grid"]) ==
            .failure(.unknownValue(value: "xyz",
                                   expected: ["tree", "grid"])))
    }

    // MARK: - validateGeom

    @Test func validateGeom_AllNil_None() {
        #expect(validateGeom(posX: nil, posY: nil,
                                    width: nil, height: nil) == .none)
    }

    @Test func validateGeom_AllSet_Complete() {
        #expect(
            validateGeom(posX: 100, posY: 200, width: 400, height: 600) ==
            .complete(x: 100, y: 200, w: 400, h: 600))
    }

    @Test func validateGeom_OneMissing_Partial() {
        #expect(
            validateGeom(posX: 100, posY: 200, width: 400, height: nil) ==
            .partial(count: 3))
    }

    @Test func validateGeom_OnlyOne_Partial() {
        #expect(
            validateGeom(posX: 100, posY: nil, width: nil, height: nil) ==
            .partial(count: 1))
    }

    // MARK: - §E validateSectionLabel (loose display-label policy)

    @Test func validateSectionLabel_PlainLabel() {
        #expect(validateSectionLabel("Web") == .success("Web"))
    }

    @Test func validateSectionLabel_AllowsSpacesAndPunctuation() {
        // Display labels are config strings — spaces / punctuation kept verbatim.
        #expect(validateSectionLabel("My Lens!") == .success("My Lens!"))
    }

    @Test func validateSectionLabel_AllowsColonVerbatim() {
        #expect(validateSectionLabel("with: colon") ==
                       .success("with: colon"))
    }

    @Test func validateSectionLabel_EmptyAllowedAsRevertGesture() {
        // Truly empty = the explicit "revert to number / config label" gesture
        // the server resolver acts on; allowed (not a typo).
        #expect(validateSectionLabel("") == .success(""))
    }

    @Test func validateSectionLabel_RejectsAllWhitespace() {
        #expect(validateSectionLabel("   ") ==
                       .failure(.unknownValue(value: "   ", expected: [])))
    }

    @Test func validateSectionLabel_RejectsLoneDash() {
        #expect(validateSectionLabel("-") ==
                       .failure(.unknownValue(value: "-", expected: [])))
    }

    @Test func validateSectionLabel_RejectsLeadingDashValue() {
        // ANY leading-dash value is rejected (flag-guard parity with
        // `parseLensSectionLabel` / `CLIName`): `--rename`'s LABEL is consumed
        // unconditionally, so a mistyped flag (`--focus`) lands here as the
        // value — reject it loudly instead of renaming to the flag string.
        #expect(validateSectionLabel("-x") ==
                       .failure(.unknownValue(value: "-x", expected: [])))
        #expect(validateSectionLabel("--focus") ==
                       .failure(.unknownValue(value: "--focus", expected: [])))
    }

    @Test func validateSectionLabel_PreservesLeadingTrailingSpacesVerbatim() {
        // The success value is kept VERBATIM (untrimmed) — the trim is only for
        // the reject guard. Normalization (the actual trim of a stored label)
        // happens at the server's store site, not here.
        #expect(validateSectionLabel(" Web ") == .success(" Web "))
    }

    // MARK: - §E section-rename wire encode / decode round-trip

    @Test func encodeSectionRename_BasicForm() {
        #expect(encodeSectionRename(index: 2, label: "Web") ==
                       "section-rename:2:Web")
    }

    @Test func decodeSectionRename_RoundTrip() {
        let wire = encodeSectionRename(index: 3, label: "My Lens")
        let got = decodeSectionRename(wire)
        #expect(got?.index == 3)
        #expect(got?.label == "My Lens")
    }

    @Test func decodeSectionRename_LabelWithColonSurvivesVerbatim() {
        // The label half may contain ':' — split ONCE so it stays intact.
        let wire = encodeSectionRename(index: 1, label: "with: colon")
        let got = decodeSectionRename(wire)
        #expect(got?.index == 1)
        #expect(got?.label == "with: colon")
    }

    @Test func decodeSectionRename_EmptyLabelDecodes() {
        let got = decodeSectionRename("section-rename:5:")
        #expect(got?.index == 5)
        #expect(got?.label == "")
    }

    @Test func decodeSectionRename_AcceptsBodyWithoutPrefix() {
        // The decoder strips the prefix if present, else treats the whole
        // string as the body (the dispatch passes the full payload).
        let got = decodeSectionRename("4:Mail")
        #expect(got?.index == 4)
        #expect(got?.label == "Mail")
    }

    @Test func decodeSectionRename_RejectsNonIntegerIndex() {
        #expect(decodeSectionRename("section-rename:x:Web") == nil)
    }

    @Test func decodeSectionRename_RejectsZeroIndex() {
        #expect(decodeSectionRename("section-rename:0:Web") == nil)
    }

    @Test func decodeSectionRename_RejectsNegativeIndex() {
        // "-1" parses as Int but is < 1; the leading-dash split keeps "-1"
        // whole (one ':' only), so it's the index half → rejected.
        #expect(decodeSectionRename("section-rename:-1:Web") == nil)
    }

    @Test func decodeSectionRename_RejectsMissingColon() {
        #expect(decodeSectionRename("section-rename:2") == nil)
    }

    // MARK: - t-0020 section-match wire encode / decode round-trip

    @Test func encodeSectionMatch_BasicForm() {
        #expect(encodeSectionMatch(index: 2, predicate: "tag~=web") ==
                       "section-match:2:tag~=web")
    }

    @Test func decodeSectionMatch_RoundTrip() {
        let wire = encodeSectionMatch(index: 3, predicate: "app=Safari")
        let got = decodeSectionMatch(wire)
        #expect(got?.index == 3)
        #expect(got?.predicate == "app=Safari")
    }

    @Test func decodeSectionMatch_PredicateWithColonSurvivesVerbatim() {
        // A predicate half may contain ':' (e.g. a quoted value) — split ONCE
        // so it stays intact.
        let wire = encodeSectionMatch(index: 1, predicate: "title~=\"a: b\"")
        let got = decodeSectionMatch(wire)
        #expect(got?.index == 1)
        #expect(got?.predicate == "title~=\"a: b\"")
    }

    @Test func decodeSectionMatch_EmptyPredicateDecodes() {
        // Empty predicate is a valid REVERT gesture (the caller deletes the
        // override); the decoder must round-trip it, not reject it.
        let got = decodeSectionMatch("section-match:5:")
        #expect(got?.index == 5)
        #expect(got?.predicate == "")
    }

    @Test func decodeSectionMatch_AcceptsBodyWithoutPrefix() {
        let got = decodeSectionMatch("4:tag~=mail")
        #expect(got?.index == 4)
        #expect(got?.predicate == "tag~=mail")
    }

    @Test func decodeSectionMatch_RejectsNonIntegerIndex() {
        #expect(decodeSectionMatch("section-match:x:tag~=web") == nil)
    }

    @Test func decodeSectionMatch_RejectsZeroIndex() {
        #expect(decodeSectionMatch("section-match:0:tag~=web") == nil)
    }

    @Test func decodeSectionMatch_RejectsNegativeIndex() {
        #expect(decodeSectionMatch("section-match:-1:tag~=web") == nil)
    }

    @Test func decodeSectionMatch_RejectsMissingColon() {
        #expect(decodeSectionMatch("section-match:2") == nil)
    }
}
