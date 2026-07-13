import Testing
@testable import FacetCore

/// The opt-in management gate (`isMacDesktopManaged`) + the section-model
/// gate (`isSectionModelActive`) — the section model's PR2. A section-only
/// config (the model's intended shape — workspaces auto-named, user writes
/// only sections) must be recognised as managed; the all-empty default must
/// stay byte-identical. Since the section-lens type was retired (t-ec9s),
/// every `[[desktop.N.section]]` is a workspace spatial cell; the only
/// managed-but-model-inactive case is an `unassigned`-only receptacle.
/// CI-only (CLT can't run `swift test`).
struct ManagementGateTests {

    private func wsSection() -> DesktopSection { DesktopSection() }
    private func receptacleSection() -> DesktopSection {
        DesktopSection(unassigned: true)
    }

    // MARK: - default (byte-identical degrade)

    @Test func sectionlessConfigManagedEverywhere() {
        let c = FacetConfig()  // no [desktop.N], no [[desktop.N.section]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isMacDesktopManaged(ordinal: 7))
        #expect(c.isMacDesktopManaged(ordinal: nil))
        #expect(!c.isSectionModelActive(ordinal: 1))
        #expect(!c.isSectionModelActive(ordinal: nil))
    }

    // MARK: - section-only opt-in (the BLOCKER fix)

    @Test func sectionOnlyConfigIsOptIn() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1),
                "a desktop with sections is managed")
        #expect(!c.isMacDesktopManaged(ordinal: 2),
                "section presence makes facet opt-in (desktop 2 untouched)")
        #expect(c.isMacDesktopManaged(ordinal: nil))
        #expect(c.isSectionModelActive(ordinal: 1),
                "a workspace-cell section activates the model")
        #expect(!c.isSectionModelActive(ordinal: 2))
        #expect(!c.isSectionModelActive(ordinal: nil),
                "section model is a per-ordinal opt-in")
    }

    /// The opt-in gate keys on per-ordinal MEMBERSHIP, not a `min..max` range
    /// or a count: two NON-contiguous configured ordinals (1 and 3) leave the
    /// gap (2) and the tail (4) unmanaged. Guards against a future
    /// range-based regression (`isMacDesktopManaged` does `sections[ordinal]
    /// != nil`).
    @Test func optInKeysOnPerOrdinalMembership() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()], 3: [wsSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 2),
                "the gap between configured ordinals is hands-off")
        #expect(c.isMacDesktopManaged(ordinal: 3))
        #expect(!c.isMacDesktopManaged(ordinal: 4),
                "past the highest configured ordinal is hands-off")
        #expect(c.isMacDesktopManaged(ordinal: nil))
    }

    /// A desktop with ONLY an `unassigned` receptacle (no workspace cell) is
    /// MANAGED (opt-in fires on any section), but the section MODEL is not
    /// active — the receptacle is excluded from the workspace substrate, so
    /// there is nothing to seed and the desktop falls back to default slots.
    /// (Successor to the retired lens-only test — the only managed-but-model-
    /// inactive section shape now is the `unassigned` receptacle, t-ec9s.)
    @Test func receptacleOnlySectionManagedButModelInactive() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [receptacleSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isSectionModelActive(ordinal: 1))
    }

    // MARK: - typed desktops ([desktop.N], t-0sbm): the opt-in gate is the
    // UNION of section ordinals and typed-desktop ordinals

    /// Flat sections on desktop 1, a `[desktop.3]` typed table on desktop 3 →
    /// both managed; the gap (2) and tail (4) stay hands-off. (Successor to
    /// the retired section∪tab union test — tabs no longer exist.)
    @Test func managedKeysOnUnionOfSectionAndMetaOrdinals() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()]]
        c.macDesktopMetaConfigs = [3: DesktopMeta(type: .isolate, match: "app=x")]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 2))
        #expect(c.isMacDesktopManaged(ordinal: 3))
        #expect(!c.isMacDesktopManaged(ordinal: 4))
        #expect(c.isMacDesktopManaged(ordinal: nil))
    }
}
