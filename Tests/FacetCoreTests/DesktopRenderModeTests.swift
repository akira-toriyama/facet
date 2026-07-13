import Testing
@testable import FacetCore

/// `FacetConfig.desktopRenderMode` — how a mac desktop composes its tree, under
/// **one mac desktop = one type**.
///
/// This exists because of a bug it now makes impossible. The old question,
/// `isSectionModelActive`, means "does this desktop author `[[desktop.N.section]]`
/// spatial cells?" — which is **false on a lens desktop**, even though a lens
/// desktop very much renders sections (1–2, synthesized from `match`). Every
/// caller that meant "does it render sections?" had to spell it
/// `isSectionModelActive(…) || isLensDesktop`, and the three TAG entry points
/// forgot. Result: you could not tag a window on a lens desktop — the one kind
/// of desktop whose membership a tag can define (`match = 'tag~=web'`).
///
/// `theBugThatMadeThisType` below is that exact hole, pinned.
struct DesktopRenderModeTests {

    private func cfg(_ toml: String) -> FacetConfig { FacetConfig.load(source: toml) }

    // MARK: - the three cases

    @Test func workspaceDesktopWithCellsRendersSections() {
        let c = cfg("""
        [[desktop.1.section]]
        label = "Code"
        """)
        #expect(c.desktopRenderMode(ordinal: 1) == .sections)
        #expect(c.desktopRenderMode(ordinal: 1).rendersSections)
    }

    @Test func workspaceDesktopWithNoCellsDegrades() {
        let c = cfg("""
        [desktop.1]
        type = "workspace"
        """)
        #expect(c.desktopRenderMode(ordinal: 1) == .degrade)
        #expect(!c.desktopRenderMode(ordinal: 1).rendersSections)
    }

    @Test func lensDesktopIsItsOwnMode() {
        let c = cfg("""
        [desktop.2]
        type = "lens"
        match = 'app~=Safari'
        """)
        #expect(c.desktopRenderMode(ordinal: 2) == .lens)
    }

    /// An unresolvable ordinal (SkyLight unavailable / single-desktop) takes the
    /// default-slot path, like an unconfigured desktop.
    @Test func nilOrdinalDegrades() {
        let c = cfg("""
        [[desktop.1.section]]
        label = "Code"
        """)
        #expect(c.desktopRenderMode(ordinal: nil) == .degrade)
    }

    // MARK: - THE BUG

    /// The hole that made tagging dead on a lens desktop: it renders sections,
    /// yet `isSectionModelActive` says no. Any gate written on the old question
    /// silently loses its feature there.
    @Test func theBugThatMadeThisType() {
        let c = cfg("""
        [desktop.2]
        type = "lens"
        match = 'tag~=web'
        """)
        #expect(!c.isSectionModelActive(ordinal: 2),
                "a lens desktop authors no spatial cells — this is why the old gate failed")
        #expect(c.desktopRenderMode(ordinal: 2).rendersSections,
                "…but it DOES render sections, which is what every caller actually meant")
    }

    // MARK: - precedence + the SSOT it shares with effectiveWorkspaceList

    /// `type = "lens"` wins over stray section rows — the same precedence
    /// `effectiveWorkspaceList` uses (lens → sections → degrade). If these two
    /// ever disagreed, a desktop could render N sections while seeding 1
    /// workspace.
    @Test func lensWinsOverStraySections() {
        let c = cfg("""
        [desktop.2]
        type = "lens"
        match = 'app~=Safari'

        [[desktop.2.section]]
        label = "Stray"
        """)
        #expect(c.desktopRenderMode(ordinal: 2) == .lens)
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 2).count == 1,
                "a lens desktop is FLAT — the N=1 the anchor-park scope relies on")
    }

    /// The receptacle is not a spatial cell, so a desktop that declares ONLY an
    /// `unassigned` row has no substrate and degrades.
    @Test func unassignedOnlyIsNotASubstrate() {
        let c = cfg("""
        [[desktop.1.section]]
        unassigned = true
        label = "Lost & Found"
        """)
        #expect(c.desktopRenderMode(ordinal: 1) == .degrade)
    }

    /// The mode and the workspace seed must agree for every case — that is the
    /// invariant `desktopRenderMode` exists to keep, so pin it directly.
    @Test func modeAgreesWithTheWorkspaceSeed() {
        let c = cfg("""
        [[desktop.1.section]]
        label = "Code"

        [[desktop.1.section]]
        label = "Web"

        [desktop.2]
        type = "lens"
        match = 'app~=Safari'

        [desktop.3]
        type = "workspace"
        """)
        #expect(c.desktopRenderMode(ordinal: 1) == .sections)
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).count == 2)

        #expect(c.desktopRenderMode(ordinal: 2) == .lens)
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 2).count == 1)

        #expect(c.desktopRenderMode(ordinal: 3) == .degrade)
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 3).count
                == FacetConfig.defaultWorkspaceCount)
    }
}
