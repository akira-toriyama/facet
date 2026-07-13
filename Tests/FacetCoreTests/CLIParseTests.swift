// Tests for FacetCore's pure CLI parse helpers (no AppKit, no
// stderr/exit side-effects). The FacetApp layer wraps these with
// the actual stderr writes + exit(2); contract is just here.

import Testing
@testable import FacetCore

struct CLIParseTests {

    // MARK: - parseGeomInt

    /// Parse an integer flag value: plain / trimmed / signed, plus the
    /// `requirePositive` guard that rejects `0` and negatives (width / height).
    @Test("parseGeomInt: parse, trim, sign, and requirePositive guard",
          arguments: [
        (input: "123", requirePositive: false, expected: .success(123)),
        // --pos-x / --pos-y can legitimately be negative on multi-monitor setups.
        (input: "-50", requirePositive: false, expected: .success(-50)),
        (input: "  42  ", requirePositive: false, expected: .success(42)),
        (input: "abc", requirePositive: false,
            expected: .failure(.notAnInteger(value: "abc"))),
        (input: "", requirePositive: false,
            expected: .failure(.notAnInteger(value: ""))),
        (input: "0", requirePositive: true,
            expected: .failure(.notPositive(value: 0))),
        (input: "-5", requirePositive: true,
            expected: .failure(.notPositive(value: -5))),
        (input: "100", requirePositive: true, expected: .success(100)),
    ] as [(input: String, requirePositive: Bool,
           expected: Result<Int, CLIParseError>)])
    func parseGeomIntCases(input: String, requirePositive: Bool,
                           expected: Result<Int, CLIParseError>) {
        #expect(parseGeomInt(input, requirePositive: requirePositive) == expected)
    }

    // MARK: - canonicalize

    /// Canonicalise against a fixed allow-list: exact / lowercased / trimmed
    /// matches succeed; an unknown value rejects with the expected list.
    @Test("canonicalize: exact/lowercase/trim match; unknown rejects",
          arguments: [
        (input: "tree", expected: .success("tree")),
        (input: "TREE", expected: .success("tree")),
        (input: "  grid ", expected: .success("grid")),
        (input: "xyz",
            expected: .failure(.unknownValue(value: "xyz",
                                             expected: ["tree", "grid"]))),
    ] as [(input: String, expected: Result<String, CLIParseError>)])
    func canonicalizeCases(input: String,
                           expected: Result<String, CLIParseError>) {
        #expect(canonicalize(input, allowed: ["tree", "grid"]) == expected)
    }

    // MARK: - validateGeom

    /// All-or-nothing geometry tuple: none when all nil, complete when all
    /// four set, partial (with the provided count) otherwise.
    @Test("validateGeom: none / complete / partial by provided-count",
          arguments: [
        (posX: nil, posY: nil, width: nil, height: nil,
            expected: GeomValidation.none),
        (posX: 100, posY: 200, width: 400, height: 600,
            expected: .complete(x: 100, y: 200, w: 400, h: 600)),
        (posX: 100, posY: 200, width: 400, height: nil,
            expected: .partial(count: 3)),
        (posX: 100, posY: nil, width: nil, height: nil,
            expected: .partial(count: 1)),
    ] as [(posX: Int?, posY: Int?, width: Int?, height: Int?,
           expected: GeomValidation)])
    func validateGeomCases(posX: Int?, posY: Int?, width: Int?, height: Int?,
                           expected: GeomValidation) {
        #expect(validateGeom(posX: posX, posY: posY,
                             width: width, height: height) == expected)
    }

    // MARK: - §E validateSectionLabel (loose display-label policy)

    /// §E loose display-label policy: spaces / punctuation / ':' kept
    /// verbatim; empty is the explicit revert gesture; all-whitespace or ANY
    /// leading-dash value (flag-guard parity with `parseSectionFocusLabel` /
    /// `CLIName`) rejects; the success value is preserved VERBATIM (untrimmed).
    @Test("validateSectionLabel: loose accept, empty-revert, reject blank/dash",
          arguments: [
        (input: "Web", expected: .success("Web")),
        // Display labels are config strings — spaces / punctuation kept verbatim.
        (input: "My Lens!", expected: .success("My Lens!")),
        (input: "with: colon", expected: .success("with: colon")),
        // Truly empty = the explicit "revert to number / config label" gesture.
        (input: "", expected: .success("")),
        (input: "   ",
            expected: .failure(.unknownValue(value: "   ", expected: []))),
        (input: "-",
            expected: .failure(.unknownValue(value: "-", expected: []))),
        // ANY leading-dash value is rejected (a mistyped flag `--focus` lands
        // here as the consumed LABEL value — reject it loudly).
        (input: "-x",
            expected: .failure(.unknownValue(value: "-x", expected: []))),
        (input: "--focus",
            expected: .failure(.unknownValue(value: "--focus", expected: []))),
        // Success value kept VERBATIM (untrimmed); the trim is only the guard.
        (input: " Web ", expected: .success(" Web ")),
    ] as [(input: String, expected: Result<String, CLIParseError>)])
    func validateSectionLabelCases(input: String,
                                   expected: Result<String, CLIParseError>) {
        #expect(validateSectionLabel(input) == expected)
    }

    // MARK: - §E section-rename wire encode / decode round-trip

    @Test func encodeSectionRename_BasicForm() {
        #expect(encodeSectionRename(index: 2, label: "Web") ==
                       "section-rename:2:Web")
    }

    /// encode → decode round-trip: the label half may contain ':' — split
    /// ONCE so it stays intact.
    @Test("decodeSectionRename: encode→decode round-trips (label keeps ':')",
          arguments: [
        (index: 3, label: "My Lens"),
        (index: 1, label: "with: colon"),
    ])
    func decodeSectionRenameRoundTrip(index: Int, label: String) {
        let wire = encodeSectionRename(index: index, label: label)
        let got = decodeSectionRename(wire)
        #expect(got?.index == index)
        #expect(got?.label == label)
    }

    /// Decode literal bodies: empty label decodes; a prefix-less body is
    /// treated as the whole payload (the dispatch passes it through).
    @Test("decodeSectionRename: literal bodies (empty label / prefix-less)",
          arguments: [
        (wire: "section-rename:5:", index: 5, label: ""),
        (wire: "4:Mail", index: 4, label: "Mail"),
    ])
    func decodeSectionRenameLiteral(wire: String, index: Int, label: String) {
        let got = decodeSectionRename(wire)
        #expect(got?.index == index)
        #expect(got?.label == label)
    }

    /// Rejects (returns nil): non-integer / zero / negative index (the
    /// leading-dash split keeps "-1" whole → index half → rejected), and a
    /// missing second colon.
    @Test("decodeSectionRename: rejects (returns nil)", arguments: [
        "section-rename:x:Web",
        "section-rename:0:Web",
        "section-rename:-1:Web",
        "section-rename:2",
    ])
    func decodeSectionRenameRejects(wire: String) {
        #expect(decodeSectionRename(wire) == nil)
    }

    // MARK: - t-0020 section-match wire encode / decode round-trip

    @Test func encodeSectionMatch_BasicForm() {
        #expect(encodeSectionMatch(index: 2, predicate: "tag~=web") ==
                       "section-match:2:tag~=web")
    }

    /// encode → decode round-trip: a predicate half may contain ':' (e.g. a
    /// quoted value) — split ONCE so it stays intact.
    @Test("decodeSectionMatch: encode→decode round-trips (predicate keeps ':')",
          arguments: [
        (index: 3, predicate: "app=Safari"),
        (index: 1, predicate: "title~=\"a: b\""),
    ])
    func decodeSectionMatchRoundTrip(index: Int, predicate: String) {
        let wire = encodeSectionMatch(index: index, predicate: predicate)
        let got = decodeSectionMatch(wire)
        #expect(got?.index == index)
        #expect(got?.predicate == predicate)
    }

    /// Decode literal bodies: empty predicate is a valid REVERT gesture (the
    /// caller deletes the override) and must round-trip; a prefix-less body is
    /// treated as the whole payload.
    @Test("decodeSectionMatch: literal bodies (empty predicate / prefix-less)",
          arguments: [
        (wire: "section-match:5:", index: 5, predicate: ""),
        (wire: "4:tag~=mail", index: 4, predicate: "tag~=mail"),
    ])
    func decodeSectionMatchLiteral(wire: String, index: Int, predicate: String) {
        let got = decodeSectionMatch(wire)
        #expect(got?.index == index)
        #expect(got?.predicate == predicate)
    }

    /// Rejects (returns nil): non-integer / zero / negative index, and a
    /// missing second colon.
    @Test("decodeSectionMatch: rejects (returns nil)", arguments: [
        "section-match:x:tag~=web",
        "section-match:0:tag~=web",
        "section-match:-1:tag~=web",
        "section-match:2",
    ])
    func decodeSectionMatchRejects(wire: String) {
        #expect(decodeSectionMatch(wire) == nil)
    }
}
