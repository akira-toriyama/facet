import Testing
@testable import FacetCore

/// The `[[desktop.N.tab]]` migration guard — the ONE piece of board code that
/// survived the abolition (t-0sbm), and the only one that must.
///
/// Why it is load-bearing: boards no longer decode. A config that types its
/// desktops ONLY with `[[desktop.N.tab]]` declares nothing facet recognises —
/// `macDesktopSectionConfigs` and `macDesktopMetaConfigs` both come back empty.
///
/// That USED to flip `isMacDesktopManaged` to `true` for EVERY ordinal: the
/// user's opt-in ("manage just desktop 1") silently became "manage all of them",
/// and facet would adopt, park and tile desktops they had never handed it. The
/// guard's job was to shout about the flip. t-r5yz FIXED the flip instead —
/// whether a user is opt-in is declared by the TEXT, not by the survivors, so a
/// config whose desktop blocks all got dropped now manages NOTHING and says why.
/// The guard survives as the thing that names the retired block.
struct RetiredBoardGuardTests {

    // MARK: - detection

    @Test func findsRetiredBoardHeaders() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.2.tab]]
        label = "Web"

        [[desktop.1.tab]]
        label = "Code"
        """)
        #expect(found == ["desktop.1.tab", "desktop.2.tab"])   // sorted
    }

    /// The match is on the literal array-of-tables header, so it is
    /// nesting-agnostic: a board's nested section blocks surface too, and a
    /// legacy `[[desktop.N.tab.section]]` can never be mistaken for a real
    /// `[[desktop.N.section]]` (its ordinal parses as `Int("1.tab")` → nil).
    @Test func findsBoardsRegardlessOfNesting() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.1.tab]]
        label = "Web"

        [[desktop.1.tab.section]]
        label = "Docs"
        """)
        #expect(found == ["desktop.1.tab"])
    }

    @Test func migratedConfigIsQuiet() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [desktop.1]
        type = "workspace"

        [[desktop.1.section]]
        label = "Code"

        [desktop.2]
        type = "isolate"
        match = 'app=Safari'
        """)
        #expect(found.isEmpty)
    }

    /// `tab` must be the last path component — a section merely LABELLED "tab"
    /// is not a board.
    @Test func doesNotFalsePositiveOnSomethingNamedTab() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.1.section]]
        label = "tab"
        """)
        #expect(found.isEmpty)
    }

    // MARK: - the flip, and its repair (t-r5yz / (c))

    /// ⬅ This test used to assert the OPPOSITE (`boardConfigFlipsToManageEveryDesktop`):
    /// a board-only config managed every mac desktop. That was the bug. The user
    /// said "manage desktop 1"; facet heard nothing, concluded no one had ever
    /// configured it, and seized all of them.
    @Test func boardOnlyConfigKeepsTheOptInAndManagesNothing() {
        let c = FacetConfig.load(source: """
        [[desktop.1.tab]]
        label = "Web"
        """)
        // Nothing decoded — the board block is inert.
        #expect(c.effectiveMacDesktopSectionConfigs.isEmpty)
        #expect(c.macDesktopMetaConfigs.isEmpty)
        // …but the DECLARATION is right there in the text, so the opt-in stands.
        #expect(c.declaresDesktopBlocks)
        #expect(!c.isMacDesktopManaged(ordinal: 1),
                "a dropped block must not promote facet to manage-everything")
        #expect(!c.isMacDesktopManaged(ordinal: 7))
        // And it is LOUD about why it is doing nothing: the retired block, plus
        // the all-dropped summary.
        #expect(c.diagnostics.hasErrors)
        #expect(c.diagnostics.contains { $0.message.contains("desktop.1.tab") })
        #expect(c.diagnostics.contains { $0.message.contains("NONE of them decoded") })
    }

    /// The unconfigured default is untouched: no desktop blocks at all → facet
    /// manages every mac desktop, as it always has. This is the case (c) must NOT
    /// break — "nothing declared" and "everything I declared died" are different
    /// questions, and only the TEXT can tell them apart.
    @Test func aConfigWithNoDesktopBlocksStillManagesEveryDesktop() {
        let c = FacetConfig.load(source: """
        [theme]
        name = "terminal"
        """)
        #expect(!c.declaresDesktopBlocks)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isMacDesktopManaged(ordinal: 7))
        #expect(!c.diagnostics.hasErrors)
    }

    /// A PARTIAL failure was already correct and stays so: desktop 1 decodes,
    /// desktop 2's isolate table is dropped for want of a `match` → desktop 1 is
    /// managed, everything else (including the broken 2) is hands-off.
    @Test func oneSurvivingBlockIsEnoughToKeepManagingIt() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Code"

        [desktop.2]
        type = "isolate"
        label = "Web"
        """)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 2))
        #expect(!c.isMacDesktopManaged(ordinal: 7))
        #expect(c.diagnostics.hasErrors, "the dropped [desktop.2] is still loud")
    }

    /// The contrast: migrate the same intent and the opt-in holds — desktop 1
    /// is managed, desktop 7 is hands-off.
    @Test func migratedConfigKeepsTheOptIn() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Code"
        """)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 7))
    }
}
