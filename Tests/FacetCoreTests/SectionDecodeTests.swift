import Foundation
import Testing
@testable import FacetCore

/// `[[desktop.N.section]]` config decode (parse-only). Since the section-lens
/// type was retired (t-ec9s), every section is a WORKSPACE spatial cell
/// (`{label, layout, unassigned}`); a stray `type` / `match` / `apply` from the
/// retired section-lens era is IGNORED by decode (and flagged by
/// `config --validate`). The array order IS the tree display order; non-empty
/// labels are de-duped per mac desktop (first-wins). CI-only (CLT can't run
/// `swift test`).
struct SectionDecodeTests {

    // MARK: - workspace-cell decode

    @Test func decodesWorkspaceCells() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        layout = "bsp"
        [[desktop.1.section]]
        label = "Web"
        layout = "stack"
        [[desktop.1.section]]
        unassigned = true
        label = "Other"
        """)
        #expect(s[1]?.count == 3)
        #expect(s[1]?[0] == DesktopSection(layout: "bsp"))
        #expect(s[1]?[1] == DesktopSection(label: "Web", layout: "stack"))
        #expect(s[1]?[2] == DesktopSection(label: "Other", unassigned: true))
    }

    /// A stray `type` / `match` / `apply` (retired section-lens keys) is IGNORED —
    /// the row decodes as a plain workspace cell, no drop, no note.
    @Test func straySectionLensKeysIgnored() {
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("lens"), "label": .string("Web"),
            "match": .string("tag~=web"),
            "apply": .table(["tags": .array([.string("web")])]),
        ])
        #expect(section == DesktopSection(label: "Web"))
        #expect(note == nil)
    }

    /// A section with no `type` (the new normal) decodes as a workspace cell —
    /// the old "absent type drops the row" behavior is gone with section-lens.
    @Test func absentTypeDecodesAsWorkspaceCell() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "Web"
        """)
        #expect(s[1]?.count == 1)
        #expect(s[1]?[0] == DesktopSection(label: "Web"))
    }

    /// An empty-string `layout` is treated as absent (stored nil) so callers see
    /// "no layout authored" rather than the empty string leaking through.
    @Test func emptyLayoutIsNil() {
        let (section, _) = DesktopSection.parse(fromTOMLRow: [
            "label": .string("Tools"), "layout": .string(""),
        ])
        #expect(section?.layout == nil)
    }

    // MARK: - unassigned receptacle

    /// §A / W2.6: a receptacle's `label` is optional — both a label-less and a
    /// labelled `unassigned = true` row decode (FilterProjection enforces the
    /// ≤1-shown rule, not the decoder).
    @Test func unassignedSectionLabelOptional() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        unassigned = true
        [[desktop.1.section]]
        unassigned = true
        label = "Other"
        """)
        #expect(s[1]?.map(\.label) == ["", "Other"])
        #expect(s[1]?.map(\.unassigned) == [true, true])
    }

    // MARK: - §A label uniqueness (non-empty unique per mac desktop)

    /// Within one mac desktop a NON-EMPTY label must be unique: a duplicate is
    /// dropped (loud + first-wins), keeping the first.
    @Test func duplicateNonEmptyLabelFirstWins() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "Web"
        layout = "bsp"
        [[desktop.1.section]]
        label = "Web"
        layout = "stack"
        """)
        #expect(s[1]?.count == 1)            // first-wins
        #expect(s[1]?[0].layout == "bsp")
    }

    /// EMPTY labels are exempt from uniqueness — they may repeat freely.
    @Test func emptyLabelsMayRepeat() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        layout = "bsp"
        [[desktop.1.section]]
        layout = "stack"
        [[desktop.1.section]]
        unassigned = true
        """)
        #expect(s[1]?.count == 3)
        #expect(s[1]?.map(\.label) == ["", "", ""])
    }

    /// Uniqueness is PER mac desktop — the same label on two desktops is fine.
    @Test func sameLabelOnDifferentDesktopsAllowed() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "Web"
        [[desktop.2.section]]
        label = "Web"
        """)
        #expect(s[1]?[0].label == "Web")
        #expect(s[2]?[0].label == "Web")
    }

    /// The uniqueness pass spans header SPELLINGS that fold into one ordinal:
    /// `desktop.1` + `desktop.01` are de-duped together (first-wins by sorted
    /// header order — "01" sorts before "1", so it wins).
    @Test func duplicateLabelDedupedAcrossOrdinalSpellings() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "Web"
        layout = "bsp"
        [[desktop.01.section]]
        label = "Web"
        layout = "stack"
        """)
        #expect(s[1]?.count == 1)
        #expect(s[1]?[0].layout == "stack")   // "01" < "1" → zero-padded wins
    }

    // MARK: - ordering / ordinals

    @Test func arrayPreservesDeclarationOrder() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "A"
        [[desktop.1.section]]
        layout = "bsp"
        [[desktop.1.section]]
        label = "B"
        """)
        #expect(s[1]?.map(\.label) == ["A", "", "B"])
    }

    @Test func multipleDesktopsKeyedByOrdinal() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "One"
        [[desktop.3.section]]
        label = "Three"
        """)
        #expect(Set(s.keys) == [1, 3])
        #expect(s[1]?[0].label == "One")
        #expect(s[3]?[0].label == "Three")
    }

    @Test func outOfRangeAndMalformedOrdinalsSkipped() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.0.section]]
        label = "Zero"
        [[desktop.-1.section]]
        label = "Neg"
        [[desktop.section]]
        label = "NoOrdinal"
        [[desktop.1.2.section]]
        label = "Dotted"
        [[desktop.2.section]]
        label = "Good"
        """)
        #expect(Set(s.keys) == [2])
        #expect(s[2]?[0].label == "Good")
    }

    /// Two spellings that normalize to the same ordinal MERGE deterministically
    /// (sorted header order), never overwrite by Dictionary hash-seed order.
    @Test func duplicateOrdinalSpellingsMergeDeterministically() {
        let text = """
        [[desktop.1.section]]
        label = "Plain"
        [[desktop.01.section]]
        label = "ZeroPad"
        """
        let first = FacetConfig.decodeDesktopSectionSections(fromTOML: text)
        for _ in 0..<8 {
            #expect(
                FacetConfig.decodeDesktopSectionSections(fromTOML: text) == first)
        }
        // Both spellings land in desktop 1; sorted header order = "01" < "1".
        #expect(first[1]?.map(\.label) == ["ZeroPad", "Plain"])
    }

    /// t-hdxb B4: when two DISTINCT-label spellings fold into one ordinal, each
    /// surviving origin keeps its OWN raw header spelling + its per-spelling
    /// `rawOrdinal` — the merge must NOT re-index to a global ordinal or
    /// normalize the header. The LOAD-BEARING pin: BOTH `rawOrdinal` are 0 (each
    /// is row 0 of its own spelling) yet the two `headerName` values DIFFER, so
    /// the snapshot writer replays the correct `[[desktop.N.section]]` block.
    @Test func bothSurvivingSpellingsKeepOwnHeaderAndRawOrdinal() {
        let text = """
        [[desktop.1.section]]
        label = "Plain"
        [[desktop.01.section]]
        label = "Zero"
        """
        let origins = FacetConfig.decodeDesktopSectionOrigins(fromTOML: text)
        #expect(origins[1]?.count == 2)
        // Sorted header order: "desktop.01.section" < "desktop.1.section".
        #expect(origins[1]?[0].section.label == "Zero")
        #expect(origins[1]?[0].declOrder == 0)
        #expect(origins[1]?[0].headerName == "desktop.01.section")
        #expect(origins[1]?[0].rawOrdinal == 0)
        #expect(origins[1]?[1].section.label == "Plain")
        #expect(origins[1]?[1].declOrder == 1)
        #expect(origins[1]?[1].headerName == "desktop.1.section")
        #expect(origins[1]?[1].rawOrdinal == 0)
        // LOAD-BEARING: both rawOrdinal == 0, yet the headers DIFFER.
        #expect(origins[1]?[0].rawOrdinal == origins[1]?[1].rawOrdinal)
        #expect(origins[1]?[0].headerName != origins[1]?[1].headerName)
    }

    @Test func noSectionsAtAll() {
        #expect(FacetConfig.decodeDesktopSectionSections(
            fromTOML: "[desktop.1]\n1 = { name = \"Dev\" }\n").isEmpty)
    }

    /// A bare `[desktop.N]` table sits in the same file as a
    /// `[[desktop.N.section]]` array; the section decode keys off the `.section`
    /// suffix only, so the bare table never shadows or pollutes it.
    @Test func sectionDecodeIgnoresBareDesktopTable() {
        let text = """
        [desktop.1]
        1 = { name = "Dev" }
        [[desktop.1.section]]
        label = "Web"
        """
        let sections = FacetConfig.decodeDesktopSectionSections(fromTOML: text)
        #expect(sections[1]?.count == 1)
        #expect(sections[1]?[0].label == "Web")
    }

    // MARK: - effective accessor + load wiring

    @Test func effectiveSectionsPassThroughInWorkspaceMode() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs =
            [1: [DesktopSection(label: "W", layout: "bsp")]]
        #expect(c.effectiveMacDesktopSectionConfigs[1]?[0].label == "W")
    }

    private func loadConfig(_ toml: String) -> FacetConfig {
        let path = NSTemporaryDirectory()
            + "facet-test-\(UUID().uuidString)/config.toml"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return FacetConfig.load(path: path)
    }

    @Test func loadPopulatesSectionsInWorkspaceMode() {
        let c = loadConfig("""
        [[desktop.1.section]]
        label = "Web"
        layout = "bsp"
        """)
        #expect(c.macDesktopSectionConfigs[1]?[0].label == "Web")
        #expect(c.effectiveMacDesktopSectionConfigs[1]?[0].layout == "bsp")
    }
}
