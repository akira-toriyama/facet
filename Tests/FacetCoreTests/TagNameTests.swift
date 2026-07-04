import Testing
@testable import FacetCore

/// `TagName.sanitized` / `.normalized` — the shared CLI + GUI tag-name
/// validators (#191, policy tightened in #227: leading `-` + internal
/// whitespace now rejected; `.normalized` collapses spaces to `-`).
struct TagNameTests {

    /// `TagName.sanitized` — strip a leading `#`, trim, then validate. Rejects
    /// empty, a reserved `_` prefix, delimiter chars (`: , =`), a leading `-`
    /// (#227: would be mistaken for a flag under the space-separated grammar's
    /// strict consumption), and internal whitespace (#227: the shell already
    /// split CLI tokens, so a space inside one is a genuine error — the GUI
    /// path uses `normalized`). Inner `-` / `_` / `.` and non-ASCII stay legal.
    /// Each row runs (and reports failures) independently.
    @Test("sanitized: strip #, trim, then validate", arguments: [
        // strips leading hash and trims
        (input: "web", expected: "web"),
        (input: "  web ", expected: "web"),
        (input: "#web", expected: "web"),
        (input: "  # code ", expected: "code"),
        // rejects empty
        (input: "", expected: nil),
        (input: "   ", expected: nil),
        (input: "#", expected: nil),        // only a hash → empty
        (input: "#  ", expected: nil),
        // rejects reserved underscore prefix
        (input: "_default", expected: nil),
        (input: "_x", expected: nil),
        (input: "#_x", expected: nil),      // hash strip then leading _
        // rejects delimiter chars
        (input: "a:b", expected: nil),
        (input: "a,b", expected: nil),
        (input: "a=b", expected: nil),
        // #227: rejects leading dash (would be mistaken for a flag)
        (input: "-foo", expected: nil),
        (input: "  -foo ", expected: nil),
        (input: "#-foo", expected: nil),    // hash strip then leading -
        // #227: rejects internal whitespace (shell already split CLI tokens)
        (input: "a b", expected: nil),
        (input: "a\tb", expected: nil),
        (input: "my tag", expected: nil),
        // keeps inner non-delimiter characters
        (input: "my-tag.2", expected: "my-tag.2"),
        (input: "a_b", expected: "a_b"),    // inner _ is fine
        (input: "日本語", expected: "日本語"),
    ])
    func sanitized(input: String, expected: String?) {
        #expect(TagName.sanitized(input) == expected)
    }

    /// #227: `normalized` is the lenient variant for free-typed input (GUI
    /// box, config `[[tag]] name`) — it collapses internal whitespace runs to
    /// `-` before validating, so "my tag" → "my-tag". It still rejects what no
    /// amount of space-collapsing can fix: a delimiter, a leading `_` / `-`, or
    /// an empty result. Each row reports independently.
    @Test("normalized: collapse whitespace to dash, then validate", arguments: [
        // collapses spaces to dash
        (input: "my tag", expected: "my-tag"),
        (input: "  multi   word  name ", expected: "multi-word-name"),
        (input: "#my tag", expected: "my-tag"),
        (input: "web", expected: "web"),    // no-op on clean
        // still rejects hard violations
        (input: "a:b", expected: nil),
        (input: "_x", expected: nil),
        (input: "-foo", expected: nil),
        (input: "   ", expected: nil),
    ])
    func normalized(input: String, expected: String?) {
        #expect(TagName.normalized(input) == expected)
    }
}
