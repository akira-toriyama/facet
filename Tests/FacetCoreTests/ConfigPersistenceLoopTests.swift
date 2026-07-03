import Testing
import Foundation
@testable import FacetCore

/// t-hdxb integration: the full persistence loop with real file I/O — render a
/// snapshot (B4) the way the Controller's dirty hook would, write it to the
/// `[config] export-path` (relative, resolved against the config dir), then
/// bootstrap (B2) and confirm the edit is promoted onto config.toml. Covers the
/// seam between the pure renderer and the startup promote that the unit tests
/// exercise separately.
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
    type = "lens"
    label = "Web"
    match = 'app=Safari'
    """

    /// Edit a lens match → export snapshot → restart → the edit is promoted.
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
        ov.match = [1: ["section:0:Web": "app=Firefox"]]
        let rendered = ConfigSnapshot.render(
            configText: try String(contentsOfFile: configPath, encoding: .utf8),
            overrides: ov)
        try write(resolved, rendered, mtime: Date(timeIntervalSince1970: 2_000)) // newer

        // 2. Next launch: bootstrap promotes the newer snapshot.
        let cfg1 = FacetConfig.bootstrapWithAutoPromote(path: configPath)

        // config.toml was overwritten with the promoted snapshot…
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(onDisk.contains(#"match = "app=Firefox""#),
                      "the edited match was promoted onto config.toml")
        #expect(!(onDisk.contains("app=Safari")))

        // …and the loaded config reflects it (decode the lens section back).
        let sec = try #require(cfg1.macDesktopSectionConfigs[1]?.first)
        #expect(sec.match == "app=Firefox", "loaded config carries the edit")
    }

    /// A hand-edit to config.toml between sessions beats a stale snapshot.
    @Test func handEditBeatsStaleSnapshot() throws {
        // Snapshot is OLDER than config.toml (user hand-edited config since).
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Firefox"]]
        let rendered = ConfigSnapshot.render(configText: configText, overrides: ov)
        try write(snapshotPath, rendered, mtime: Date(timeIntervalSince1970: 1_000))
        try write(configPath, configText, mtime: Date(timeIntervalSince1970: 2_000)) // newer

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        let sec = try #require(cfg.macDesktopSectionConfigs[1]?.first)
        #expect(sec.match == "app=Safari", "hand-edit wins; stale snapshot ignored")
        #expect(!(try String(contentsOfFile: configPath, encoding: .utf8)
            .contains("Firefox")))
    }
}
