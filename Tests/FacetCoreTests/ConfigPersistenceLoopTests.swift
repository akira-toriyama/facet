import Testing
import Foundation
@testable import FacetCore

/// t-hdxb integration: the full persistence loop with real file I/O — render a
/// snapshot (B4) the way the Controller's dirty hook would, write it to the
/// `[config] export-path` (relative, resolved against the config dir), then
/// bootstrap (B2) and confirm the edit is promoted onto config.toml. Covers the
/// seam between the pure renderer and the startup promote that the unit tests
/// exercise separately. (t-ec9s: the section-lens type was retired — every
/// `[[desktop.N.section]]` is a workspace SPATIAL cell now, so the round-trip is
/// exercised through a workspace-label rename plus — t-sgqk — a lens DESKTOP's
/// `[desktop.N] match` retarget.)
final class ConfigPersistenceLoopTests {

    private let dir: URL
    private let configPath: String
    private let snapshotPath: String

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        configPath = dir.appendingPathComponent("config.toml").path
        snapshotPath = dir.appendingPathComponent("config.snapshot.toml").path
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String, mtime: Date) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: path)
    }

    private let configText = """
    [config]
    export-path  = "config.snapshot.toml"
    auto-promote = true

    [[desktop.1.section]]
    label = "Web"
    """

    /// Rename a workspace cell → export snapshot → restart → the edit is promoted.
    @Test func editExportPromoteRoundTrip() throws {
        try write(configPath, configText, mtime: Date(timeIntervalSince1970: 1_000))

        // 1. The dirty hook's work: read config.toml, render with the session
        //    override, resolve the RELATIVE export-path, write the snapshot.
        let cfg0 = FacetConfig.load(path: configPath)
        let rawExport = try #require(cfg0.effectiveExportPath)
        let resolved = FacetConfig.resolvePath(
            rawExport, relativeTo: (configPath as NSString).deletingLastPathComponent)
        #expect(resolved == snapshotPath, "relative export-path resolves to config dir")

        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"]]   // rename wsSlot 0: Web → Browsers
        let rendered = ConfigSnapshot.render(
            configText: try String(contentsOfFile: configPath, encoding: .utf8),
            overrides: ov)
        try write(resolved, rendered, mtime: Date(timeIntervalSince1970: 2_000)) // newer

        // 2. Next launch: bootstrap promotes the newer snapshot.
        let cfg1 = FacetConfig.bootstrapWithAutoPromote(path: configPath)

        // config.toml was overwritten with the promoted snapshot…
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(onDisk.contains(#"label = "Browsers""#),
                      "the edited label was promoted onto config.toml")
        #expect(!(onDisk.contains(#""Web""#)))

        // …and the loaded config reflects it (decode the section back).
        let sec = try #require(cfg1.macDesktopSectionConfigs[1]?.first)
        #expect(sec.label == "Browsers", "loaded config carries the edit")
    }

    /// Retarget an isolate desktop's match → export → restart → the edit is
    /// promoted and the loaded config drives the lens with it (t-sgqk).
    @Test func isolateMatchExportPromoteRoundTrip() throws {
        let isolateConfig = """
        [config]
        export-path  = "config.snapshot.toml"
        auto-promote = true

        [[desktop.1.section]]
        label = "Web"

        [desktop.2]
        type = "isolate"
        match = 'app=Safari'
        layout = "bsp"
        """
        try write(configPath, isolateConfig, mtime: Date(timeIntervalSince1970: 1_000))

        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: "tag~=web"]
        let rendered = ConfigSnapshot.render(
            configText: try String(contentsOfFile: configPath, encoding: .utf8),
            overrides: ov)
        try write(snapshotPath, rendered, mtime: Date(timeIntervalSince1970: 2_000))

        let cfg1 = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(onDisk.contains(#"match = "tag~=web""#),
                "the retargeted match was promoted onto config.toml")
        #expect(!(onDisk.contains("app=Safari")))
        let lens = try #require(cfg1.desktopIsolate(ordinal: 2))
        #expect(lens.match == "tag~=web", "the promoted config drives the lens")
    }

    /// Rename an isolate desktop → export → restart → the new name is promoted and
    /// the loaded config carries it (t-j7ps). The twin of the match round-trip
    /// above, and the gap it closes: the rename USED to work for the session and
    /// then evaporate, because the snapshot writer baked labels by walking
    /// authored `[[desktop.N.section]]` rows — and an isolate desktop has none.
    /// So `--match` persisted while `--rename` did not, and the label was left
    /// LYING about what the desktop held.
    @Test func isolateLabelExportPromoteRoundTrip() throws {
        let isolateConfig = """
        [config]
        export-path  = "config.snapshot.toml"
        auto-promote = true

        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app~=Chrome'
        """
        try write(configPath, isolateConfig, mtime: Date(timeIntervalSince1970: 1_000))

        var ov = ConfigSnapshot.Overrides()
        ov.isolateLabel = [2: "Editors"]
        let rendered = ConfigSnapshot.render(
            configText: try String(contentsOfFile: configPath, encoding: .utf8),
            overrides: ov)
        try write(snapshotPath, rendered, mtime: Date(timeIntervalSince1970: 2_000))

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(onDisk.contains(#"label = "Editors""#),
                "the rename was promoted onto config.toml")
        #expect(!onDisk.contains(#"label = "Web""#))
        let iso = try #require(cfg.desktopIsolate(ordinal: 2))
        #expect(iso.label == "Editors", "the promoted config names the desktop")
        #expect(iso.match == "app~=Chrome", "and its match is untouched")
    }

    /// A hand-edit to config.toml between sessions beats a stale snapshot.
    @Test func handEditBeatsStaleSnapshot() throws {
        // Snapshot is OLDER than config.toml (user hand-edited config since).
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"]]
        let rendered = ConfigSnapshot.render(configText: configText, overrides: ov)
        try write(snapshotPath, rendered, mtime: Date(timeIntervalSince1970: 1_000))
        try write(configPath, configText, mtime: Date(timeIntervalSince1970: 2_000)) // newer

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        let sec = try #require(cfg.macDesktopSectionConfigs[1]?.first)
        #expect(sec.label == "Web", "hand-edit wins; stale snapshot ignored")
        #expect(!(try String(contentsOfFile: configPath, encoding: .utf8)
            .contains("Browsers")))
    }
}
