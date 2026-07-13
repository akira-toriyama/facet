import Testing
@testable import FacetCore

/// t-6rbc — the orphan retirement, and the ONE trap that made it dangerous.
///
/// `unassigned = true` marked a `[[desktop.N.section]]` row as the lost-and-found
/// receptacle: it collected the "leftover" — windows shown in no other section.
/// The leftover was provably always EMPTY. A window with no workspace could only
/// be minted by `setOrphan`, whose only caller (`orphanWindow`) lost ITS only
/// caller when t-qtpx removed the ws→lens DnD. So facet rendered, in every view,
/// a section that could never hold anything: a permanent lie, and six modules of
/// plumbing to keep it lit.
///
/// ⚠️ THE TRAP, and it has TWO faces — the first cut of this feature walked into
/// the second one.
///
/// **Ignore the key and you GROW the substrate.** An unknown key is IGNORED by
/// decode, so a stale `unassigned = true` row would quietly become an ordinary
/// workspace cell: the desktop gains a workspace and the user's layout changes
/// under them, with no message anywhere. (`workspaceSubstrateSections` used to
/// filter receptacles OUT of the workspace list; deleting that filter is what
/// would promote them.) So the key is RETIRED, not merely removed: the row is
/// DROPPED, loudly.
///
/// **Drop it on ANY value and you SHRINK the substrate.** `unassigned = false`
/// was never a receptacle — the old parse marked one on `true` alone — so that
/// row was already an ordinary workspace cell, and dropping it DELETES a
/// workspace the user has today. The value is what decides.
///
/// That is the whole point of these tests — the retirement must be a no-op for
/// the substrate. **Same config text in, same workspaces out**, in BOTH
/// directions: a `true` row was never a workspace and must not become one; a
/// `false` row always WAS one and must not stop being one.
struct RetiredUnassignedKeyTests {

    /// ⬅ THE migration test. A config that still carries the receptacle (every
    /// user who followed the old template — it said "Recommended!! … DON'T
    /// DELETE") must get the SAME two workspaces it has today.
    @Test func staleUnassignedRowIsDroppedNotPromotedToAWorkspace() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Main"
        layout = "bsp"

        [[desktop.1.section]]
        unassigned = true
        label = "Lost & Found"

        [[desktop.1.section]]
        layout = "stack"
        """)
        // The row is GONE — not present as a section…
        #expect(c.macDesktopSectionConfigs[1]?.count == 2)
        #expect(c.macDesktopSectionConfigs[1]?.map(\.label) == ["Main", ""])
        // …and, crucially, it did NOT become a third workspace.
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 2, "a retired row must not grow the workspace count")
        #expect(list[0].config.name == "Main")
        #expect(list[0].config.layout == "bsp")
        #expect(list[1].config.layout == "stack")
        // The desktop stays managed, and the section model stays ON.
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isSectionModelActive(ordinal: 1))
    }

    /// And it is LOUD: `config --validate` exits 1 and tells you to delete it.
    /// Silence is the worst possible answer here — the user cannot see a layout
    /// they never asked for.
    @Test func theRetiredKeyIsAnError() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Main"

        [[desktop.1.section]]
        unassigned = true
        """)
        #expect(c.diagnostics.hasErrors)
        #expect(c.diagnostics.contains {
            $0.message.contains("`unassigned = true` was retired")
        }, "\(c.diagnostics.map(\.message))")
    }

    /// ⬅ THE OTHER DIRECTION, and the first cut of this feature got it WRONG.
    ///
    /// `unassigned = false` was NEVER a receptacle: the old parse set the marker on
    /// `true` alone, so a `false` row was already an ordinary workspace cell —
    /// named, laid out, seeding a real workspace. Dropping it (which a
    /// `if case .bool?` guard does, since it matches `false` too) DELETES a
    /// workspace the user has today: the very harm the retirement exists to
    /// prevent, in the opposite direction. And it is REACHABLE — flipping the key
    /// the old template told you to keep is the natural way to turn the receptacle
    /// off.
    ///
    /// The rule is not "the key is retired, so kill the row". It is "the same
    /// config text must still yield the same workspaces". Only `true` was a
    /// receptacle; only `true` drops.
    @Test func aFalseUnassignedKeepsTheWorkspaceItAlreadyWas() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Main"

        [[desktop.1.section]]
        unassigned = false
        label = "Side"
        layout = "bsp"
        """)
        #expect(c.macDesktopSectionConfigs[1]?.count == 2)
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == 2, "the retirement removes a CONCEPT, never a workspace")
        #expect(list.map(\.config.name) == ["Main", "Side"])
        #expect(list[1].config.layout == "bsp", "its layout survives too")
        // Kept, so it is a WARNING — nothing the user wrote was discarded.
        #expect(!c.diagnostics.hasErrors)
        #expect(c.diagnostics.contains { $0.message.contains("stays the workspace cell") })
    }

    /// The same row as the ONLY section: on `true` the desktop decodes to nothing
    /// (and the opt-in rule makes it hands-off — see below). On `false` it must
    /// still be a managed desktop with one workspace, exactly as today. One boolean
    /// literal must not flip a managed desktop to hands-off.
    @Test func aLoneFalseUnassignedStillManagesItsDesktop() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        unassigned = false
        label = "Work"
        """)
        #expect(c.macDesktopSectionConfigs[1]?.count == 1)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isSectionModelActive(ordinal: 1))
        #expect(c.effectiveWorkspaceList(forMacDesktopOrdinal: 1).map(\.config.name) == ["Work"])
    }

    /// A desktop whose sections were ALL receptacles now decodes to nothing at
    /// all. Under the opt-in rule that means facet manages NOTHING there — it
    /// does not "recover" into managing every desktop (t-r5yz / (c)), and it
    /// does not conjure phantom workspaces either. Loud, and safe.
    @Test func aReceptacleOnlyDesktopDecodesToNothingAndIsLoud() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        unassigned = true
        label = "Lost & Found"
        """)
        #expect(c.macDesktopSectionConfigs.isEmpty)
        #expect(c.declaresDesktopBlocks, "the DECLARATION is still in the text")
        #expect(!c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 7),
                "a dropped block must never promote facet to manage-everything")
        #expect(c.diagnostics.hasErrors)
    }

    /// The schema knows too — `additionalProperties: false` reports the retired
    /// key as unknown, so `--validate` fails it from BOTH channels (belt and
    /// braces: the decode diagnostic names it as retired, the schema catches it
    /// even if the decoder ever stopped looking).
    @Test func theRetiredKeyIsAlsoAnUnknownSchemaKey() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.1.section]]
        unassigned = true
        """)
        #expect(errors.contains { $0.message.contains("unassigned") },
                "\(errors.map(\.message))")
    }

    /// `DesktopType` is the mac-DESKTOP discriminator (`[desktop.N] type =
    /// "workspace" | "isolate"`) and never grew a receptacle case. CaseIterable
    /// makes this a compile+runtime pin. (Relocated from the retired
    /// `UnassignedMarkerTests`.)
    @Test func desktopTypeIsWorkspaceOrIsolateOnly() {
        #expect(DesktopType.allCases == [.workspace, .isolate])
    }
}
