import Testing
import Foundation
@testable import FacetCore

/// `FacetConfig.validate(_:)` is the STRICT counterpart to the lenient
/// `load()` — it surfaces the type / enum / range / unknown-key mismatches
/// the loader silently clamps or drops (sill 1.29.0 `Spec.validate` bridge,
/// driven by the SAME `configSpec` that decodes + emits the schema, t-0029).
/// `config --validate` shows these; `load()` still forgives them at runtime.
struct ConfigValidateTests {

    /// The committed `config.toml` template MUST validate with zero errors —
    /// the safety net proving facet's bespoke `[[exclude]]` / `[[rule]]` /
    /// `[[desktop.N.section]]` blocks don't trip the strict validator.
    @Test func committedTemplateValidatesClean() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let errors = try FacetConfig.validate(source)
        #expect(errors == [],
                "shipped config.toml should validate clean; got: \(errors.map(\.message).joined(separator: "; "))")
    }

    /// An empty document (the missing-file case → all defaults) is valid.
    @Test func emptyDocumentIsValid() throws {
        #expect(try FacetConfig.validate("") == [])
    }

    /// `load()` silently ignores unknown keys; `validate` surfaces them.
    @Test func unknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = 4
        bogus-key = 1
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "unknown key should be reported; got \(errors.map(\.rule))")
    }

    /// `[grid].cols` is an integer; a string is a type mismatch.
    @Test func wrongTypeIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = "four"
        """)
        #expect(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "cols" }
            return false
        }, "type mismatch should be reported; got \(errors.map(\.rule))")
    }

    /// A genuine TOML syntax error throws (distinct from a schema violation).
    @Test func unparseableSourceThrows() {
        #expect(throws: (any Error).self) { try FacetConfig.validate("[grid\nbad") }
    }

    // MARK: - Coverage boundary on facet's bespoke arrays (t-0057 item #5)

    /// `[[exclude]]` is an `.arrayOfTables` section — STRICTLY validated, so
    /// a typo'd key IS reported (the spec's `descOnly` fields are the keyset).
    @Test func excludeArrayOfTablesUnknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[exclude]]
        app = "Safari"
        bogus-key = 1
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "exclude is arrayOfTables (strict); got \(errors.map(\.rule))")
    }

    // MARK: - Desktop typed open-map (t-kz0m) — `[[desktop.N.section]]` is now
    // STRICTLY validated via the `dynamicValue` value shape. The raw-text decode
    // is untouched (it never consulted the schema); only `--validate` / taplo
    // gained field-level strictness. Flips the old permissive boundary.

    /// A typo'd section key IS now reported (the value shape owns the section
    /// vocabulary: type/label/match/layout/unassigned/apply).
    @Test func desktopSectionUnknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.1.section]]
        type = "workspace"
        not-a-real-key = 1
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "not-a-real-key" }
            return false
        }, "desktop section is now strict; got \(errors.map(\.rule))")
    }

    /// A section's `type` is an enum {workspace, lens}; a bogus value is caught.
    @Test func desktopSectionBadTypeEnumIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.1.section]]
        type = "banana"
        """)
        #expect(errors.contains {
            if case .notInEnum(let k, _, _) = $0.rule { return k == "type" }
            return false
        }, "bad `type` enum should be reported; got \(errors.map(\.rule))")
    }

    /// The ordinal key must match `^0*[1-9][0-9]*$` (mirrors the runtime
    /// `Int(mid) >= 1` guard): a non-numeric desktop key is rejected.
    @Test func desktopNonOrdinalKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.foo.section]]
        type = "workspace"
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "foo" }
            return false
        }, "non-ordinal desktop key should be reported; got \(errors.map(\.rule))")
    }

    /// `[desktop.0]` is out of the ordinal domain (runtime drops `0`) — the
    /// pattern rejects it so the editor can't silently accept a dead key.
    @Test func desktopZeroOrdinalIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.0.section]]
        type = "workspace"
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "0" }
            return false
        }, "`[desktop.0]` should be reported; got \(errors.map(\.rule))")
    }

    // MARK: - A1: schema warnings recorded on the LOAD path (data-on-config)

    /// A schema violation surfaces on the LENIENT load path as a recorded
    /// warning while load STILL clamps — it must never reject (A1).
    @Test func loadPathRecordsSchemaViolationAndStillClamps() throws {
        let cfg = FacetConfig.load(source: """
        [grid]
        cols = "four"
        """)
        // (1) load recorded the violation as a warning
        #expect(cfg.schemaWarnings.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "cols" }
            return false
        }, "load(source:) should record the schema violation; got \(cfg.schemaWarnings.map(\.rule))")
        // (2) but load stayed lenient — cols fell back to its clamp default (4)
        #expect(cfg.effectiveGridCols == 4)
    }

    /// A clean config records zero load-path warnings (no false positives).
    @Test func loadPathCleanConfigHasNoSchemaWarnings() {
        #expect(FacetConfig.load(source: "").schemaWarnings.isEmpty)
    }
}
