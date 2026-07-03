import Testing
@testable import FacetCore

/// `TagName.sanitized` / `.normalized` — the shared CLI + GUI tag-name
/// validators (#191, policy tightened in #227: leading `-` + internal
/// whitespace now rejected; `.normalized` collapses spaces to `-`).
struct TagNameTests {

    @Test func stripsLeadingHashAndTrims() {
        #expect(TagName.sanitized("web") == "web")
        #expect(TagName.sanitized("  web ") == "web")
        #expect(TagName.sanitized("#web") == "web")
        #expect(TagName.sanitized("  # code ") == "code")
    }

    @Test func rejectsEmpty() {
        #expect(TagName.sanitized("") == nil)
        #expect(TagName.sanitized("   ") == nil)
        #expect(TagName.sanitized("#") == nil)      // only a hash → empty
        #expect(TagName.sanitized("#  ") == nil)
    }

    @Test func rejectsReservedUnderscorePrefix() {
        #expect(TagName.sanitized("_default") == nil)
        #expect(TagName.sanitized("_x") == nil)
        #expect(TagName.sanitized("#_x") == nil)    // hash strip then leading _
    }

    @Test func rejectsDelimiterChars() {
        #expect(TagName.sanitized("a:b") == nil)
        #expect(TagName.sanitized("a,b") == nil)
        #expect(TagName.sanitized("a=b") == nil)
    }

    /// #227: a leading `-` would be mistaken for a flag under the
    /// space-separated grammar's strict consumption, so it's rejected.
    /// An inner `-` stays legal (see `testKeepsInnerNonDelimiterCharacters`).
    @Test func rejectsLeadingDash() {
        #expect(TagName.sanitized("-foo") == nil)
        #expect(TagName.sanitized("  -foo ") == nil)
        #expect(TagName.sanitized("#-foo") == nil)  // hash strip then leading -
    }

    /// #227: internal whitespace is rejected by the strict validator
    /// (the shell already split CLI tokens, so a space inside one is a
    /// genuine error). The GUI path uses `normalized` instead.
    @Test func rejectsInternalWhitespace() {
        #expect(TagName.sanitized("a b") == nil)
        #expect(TagName.sanitized("a\tb") == nil)
        #expect(TagName.sanitized("my tag") == nil)
    }

    @Test func keepsInnerNonDelimiterCharacters() {
        #expect(TagName.sanitized("my-tag.2") == "my-tag.2")
        #expect(TagName.sanitized("a_b") == "a_b")   // inner _ is fine
        #expect(TagName.sanitized("日本語") == "日本語")
    }

    /// #227: `normalized` is the lenient variant for free-typed input
    /// (GUI box, config `[[tag]] name`) — it collapses internal whitespace
    /// runs to `-` before validating, so "my tag" → "my-tag".
    @Test func normalizedCollapsesSpacesToDash() {
        #expect(TagName.normalized("my tag") == "my-tag")
        #expect(TagName.normalized("  multi   word  name ") ==
                       "multi-word-name")
        #expect(TagName.normalized("#my tag") == "my-tag")
        #expect(TagName.normalized("web") == "web")  // no-op on clean
    }

    /// `normalized` still rejects what no amount of space-collapsing can
    /// fix: a delimiter, a leading `_` / `-`, or an empty result.
    @Test func normalizedStillRejectsHardViolations() {
        #expect(TagName.normalized("a:b") == nil)
        #expect(TagName.normalized("_x") == nil)
        #expect(TagName.normalized("-foo") == nil)
        #expect(TagName.normalized("   ") == nil)
    }
}
