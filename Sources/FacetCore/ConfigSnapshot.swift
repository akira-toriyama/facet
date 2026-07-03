// ConfigSnapshot — the pure snapshot renderer (t-hdxb B4). Apply the
// session-only config overrides (lens match, section / workspace rename,
// workspace layout, tag vocabulary) onto config.toml's SOURCE TEXT and return
// the new TOML — every untouched byte preserved (surgical edits via
// swift-toml-edit's value ops). No I/O, no Controller / backend types, so it
// is unit-tested in FacetCoreTests. The Controller's dirty hook (B3) reads
// config.toml, calls this, and atomic-writes the result to `[config]
// export-path`; config.toml itself is never touched here.
//
// The mapping from a projected section id back to a raw `[[desktop.N.section]]`
// element is done through `decodeDesktopSectionOrigins` — the SAME decode the
// projection reads — so it can never drift from `FilterProjection`'s
// `declOrder`. v1 scope: only FLAT desktops are edited; a desktop that declares
// `[[desktop.N.tab]]` (boards) has its nested sections skipped (logged) — the
// `[tags]` write is global and still applies.

import Foundation
import Toml

public enum ConfigSnapshot {

    /// The session overrides to bake into the snapshot, keyed exactly the way
    /// the Controller holds them (see `Controller` + `FilterProjection`).
    public struct Overrides: Sendable, Equatable {
        /// `[macDesktopOrdinal: [ProjectedSection.id: match]]` — lens match edits.
        public var match: [Int: [String: String]]
        /// `[macDesktopOrdinal: [ProjectedSection.id: label]]` — lens /
        /// unassigned display renames (a workspace rename lives in
        /// `workspaceLabel`, not here — its id keys the catalog, not config).
        public var label: [Int: [String: String]]
        /// `[macDesktopOrdinal: [wsSlot: name]]` — workspace names. `wsSlot` is
        /// the 0-based index among `type="workspace"` sections (matching
        /// `FilterProjection`'s `wsCursor`), which the k-th live workspace fills.
        /// Only the CURRENT desktop's workspaces are knowable, so this is
        /// populated for that ordinal alone.
        public var workspaceLabel: [Int: [Int: String]]
        /// `[macDesktopOrdinal: [wsSlot: layoutMode]]` — workspace layout modes,
        /// same `wsSlot` keying as `workspaceLabel`.
        public var workspaceLayout: [Int: [Int: String]]
        /// Tag names in use to union into `[tags] defined` (`[]` = leave the
        /// existing vocabulary untouched). The renderer unions these with the
        /// config's own `[tags] defined` so a hand-authored vocabulary survives.
        public var definedTags: [String]

        public init(match: [Int: [String: String]] = [:],
                    label: [Int: [String: String]] = [:],
                    workspaceLabel: [Int: [Int: String]] = [:],
                    workspaceLayout: [Int: [Int: String]] = [:],
                    definedTags: [String] = []) {
            self.match = match
            self.label = label
            self.workspaceLabel = workspaceLabel
            self.workspaceLayout = workspaceLayout
            self.definedTags = definedTags
        }

        /// True when there is nothing to bake — the caller can skip the write.
        public var isEmpty: Bool {
            match.allSatisfy { $0.value.isEmpty }
                && label.allSatisfy { $0.value.isEmpty }
                && workspaceLabel.allSatisfy { $0.value.isEmpty }
                && workspaceLayout.allSatisfy { $0.value.isEmpty }
                && definedTags.isEmpty
        }
    }

    /// Render the snapshot: `configText` with `overrides` surgically applied.
    /// Total — never throws. If `configText` is not parseable (a user typo the
    /// lenient loader tolerates but the strict DOM does not), it is returned
    /// UNCHANGED (fail-soft — the caller still gets a byte-for-byte snapshot of
    /// the current config rather than losing the write).
    public static func render(configText: String, overrides: Overrides) -> String {
        guard var dom = try? Toml.Annotated(parsing: configText) else {
            Log.debug("config: snapshot skipped surgery — config.toml is not "
                + "strictly parseable; emitting an unedited copy")
            return configText
        }

        // Board desktops ([[desktop.N.tab]]) → skip section edits (v1 scope:
        // nested tab sections aren't mapped). The [tags] write below is global.
        let boardOrdinals = Set(FacetConfig.decodeDesktopTabs(fromTOML: configText).keys)
        let origins = FacetConfig.decodeDesktopSectionOrigins(fromTOML: configText,
                                                              log: false)

        // Ordinal-alignment guard (see `rawOrdinal` note in DesktopSectionOrigin):
        // `rawOrdinal` counts within one LITERAL header spelling (facet's
        // parseFlat), but swift-toml-edit's `upsertingValue` ordinal counts the
        // DECODED path. They agree UNLESS a second literal spelling decodes to
        // the same path (e.g. an exotic `[[desktop . 1 . section]]` /
        // `[[desktop."1".section]]` that facet's own decode drops). When the DOM
        // sees MORE `[[path]]` elements than parseFlat grouped under the literal
        // header, the ordinals would misalign and edit the wrong element — so we
        // skip those edits (a safe no-op, config.toml untouched) rather than
        // corrupt a section.
        let rawGroupCounts = parseTOMLArraysOfTables(configText) { name in
            name.hasPrefix("desktop.") && name.hasSuffix(".section")
        }.mapValues { $0.count }

        for (ordinal, secOrigins) in origins {
            if boardOrdinals.contains(ordinal) {
                Log.debug("config: snapshot skipped section edits for desktop "
                    + "\(ordinal) (board config — nested sections out of scope)")
                continue
            }
            var wsSlot = 0
            for o in secOrigins {
                // The header spelling this section came from IS the AoT path.
                let path = o.headerName.split(separator: ".").map(String.init)
                // Only edit when the DOM's decoded-path element count matches
                // facet's literal-header count — otherwise the ordinal is
                // ambiguous (see the guard note above). wsSlot still advances so
                // any editable siblings keep their positional mapping.
                let pathSafe = dom.arrayOfTablesCount(at: path)
                    == (rawGroupCounts[o.headerName] ?? 0)
                if !pathSafe {
                    Log.debug("config: snapshot skipped desktop \(ordinal) section "
                        + "\"\(o.section.label)\" — ambiguous header spelling "
                        + "\(o.headerName)")
                }

                // `unassigned` is a MARKER checked before `type` (mirrors
                // FilterProjection) — id `unassigned:<declOrder>`, label only,
                // and it advances NO workspace slot.
                if o.section.unassigned {
                    let id = "unassigned:\(o.declOrder)"
                    if pathSafe, let l = overrides.label[ordinal]?[id] {
                        dom = dom.upsertingValue(.string(l),
                            inArrayOfTablesElement: path, ordinal: o.rawOrdinal,
                            forKey: "label")
                    }
                    continue
                }

                switch o.section.type {
                case .lens:
                    let id = "section:\(o.declOrder):\(o.section.label)"
                    if pathSafe, let m = overrides.match[ordinal]?[id] {
                        dom = dom.upsertingValue(.string(m),
                            inArrayOfTablesElement: path, ordinal: o.rawOrdinal,
                            forKey: "match")
                    }
                    if pathSafe, let l = overrides.label[ordinal]?[id] {
                        dom = dom.upsertingValue(.string(l),
                            inArrayOfTablesElement: path, ordinal: o.rawOrdinal,
                            forKey: "label")
                    }

                case .workspace:
                    // The k-th workspace section ↔ the k-th live workspace. An
                    // empty name is left unwritten (absent label = unnamed).
                    if pathSafe, let name = overrides.workspaceLabel[ordinal]?[wsSlot],
                       !name.isEmpty {
                        dom = dom.upsertingValue(.string(name),
                            inArrayOfTablesElement: path, ordinal: o.rawOrdinal,
                            forKey: "label")
                    }
                    if pathSafe, let layout = overrides.workspaceLayout[ordinal]?[wsSlot] {
                        dom = dom.upsertingValue(.string(layout),
                            inArrayOfTablesElement: path, ordinal: o.rawOrdinal,
                            forKey: "layout")
                    }
                    wsSlot += 1
                }
            }
        }

        // [tags] defined = the config's existing vocabulary UNION the in-use
        // names (first-wins order). A hand-authored `defined` list is never
        // shrunk; an absent `[tags]` table is created at document end.
        if !overrides.definedTags.isEmpty {
            let existing = FacetConfig.load(source: configText).effectiveDefinedTags
            var seen: Set<String> = []
            let union = (existing + overrides.definedTags)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            dom = dom.settingArrayValue(union.map { Toml.Value.string($0) },
                                        atTable: ["tags"], forKey: "defined")
        }

        return dom.render()
    }
}
