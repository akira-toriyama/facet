import Testing
@testable import FacetCore

/// W2.6 (t-wrd2): the lost-and-found receptacle is an `unassigned = true`
/// MARKER on an ordinary `[[desktop.N.section]]` cell, NOT a `type` value.
/// Since the section-lens type was retired (t-ec9s: `lens` is now ONLY a typed
/// mac desktop, `[desktop.N] type=lens`), EVERY authored section is a workspace
/// SPATIAL cell — decode is TOTAL (never drops a row), and a stray `type` /
/// `match` / `apply` (from the retired section-lens era) is IGNORED. The
/// receptacle keeps its own rendered `ProjectedSectionType.unassigned` case
/// (config vs rendered types are separate concerns).
struct UnassignedMarkerTests {

    // MARK: - DesktopType is the DESKTOP discriminator (no unassigned case)

    @Test func sectionTypeHasNoUnassignedCase() {
        // `DesktopType` is now the mac-desktop TYPE discriminator
        // (`[desktop.N] type = "workspace" | "lens"`), not a section field. It
        // is {workspace, isolate} only — the receptacle is a section marker, not a
        // type. (CaseIterable makes this a discriminating compile+runtime pin.)
        #expect(DesktopType.allCases == [.workspace, .isolate])
    }

    // MARK: - flat decoder: `unassigned = true` marker

    @Test func flatUnassignedMarkerDecodes() {
        // A flat section with `unassigned = true` decodes to a receptacle: the
        // marker is set and the optional `label` names it.
        let (s, _) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true), "label": .string("Misc"),
        ])
        #expect(s != nil)
        #expect(s?.unassigned == true)
        #expect(s?.label == "Misc")
    }

    @Test func strayLensEraKeysAreIgnored() {
        // A stray `type` / `match` / `apply` (from the retired section-lens era)
        // is IGNORED by decode — every section is a workspace cell — with no
        // caveat note (`config --validate`'s strict schema is what flags it, not
        // the decoder). The `unassigned` marker still lands.
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true),
            "type": .string("lens"),
            "match": .string("app=X"),
            "apply": .table(["tags": .array([.string("a")])]),
        ])
        #expect(s?.unassigned == true)
        #expect(note == nil)
    }

    // MARK: - non-receptacle sections keep the marker false

    @Test func workspaceSectionMarkerFalse() {
        // An ordinary section (no `unassigned` marker) is a workspace cell —
        // the receptacle marker is false and the label names it.
        let (s, _) = DesktopSection.parse(fromTOMLRow: ["label": .string("Work")])
        #expect(s?.unassigned != true)
        #expect(s?.label == "Work")
    }

    // MARK: - FilterProjection: marker emits the receptacle

    @Test func projectionMarkerEmitsUnassignedReceptacle() {
        let ws = Workspace(index: 0, name: "Main", isActive: true,
                           layoutMode: "float", windows: [])
        let orphan = Window(id: WindowID(serverID: 9), pid: 1, appName: "Z",
                            title: "z", isFocused: false, isFloating: false,
                            frame: nil, isOnscreen: true)
        let sections = [
            DesktopSection(label: "Web"),
            DesktopSection(label: "Misc", unassigned: true),
        ]
        let r = FilterProjection.project(workspaces: [ws], sections: sections,
                                         orphans: [orphan])
        let receptacle = r.sections.first { $0.sectionType == .unassigned }
        #expect(receptacle != nil)
        // the orphan lands in no workspace section → it is the leftover the
        // receptacle rescues (universe − shown).
        #expect(receptacle?.windows.map(\.id) == [WindowID(serverID: 9)])
    }
}
