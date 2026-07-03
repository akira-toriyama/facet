import Testing
import Foundation
@testable import FacetCore

/// B2 (t-hdxb): the startup `bootstrapWithAutoPromote` — promote a NEWER
/// snapshot onto config.toml (opt-in) with a strict mtime staleness gate,
/// self-write refusal, and fail-soft I/O.
final class ConfigAutoPromoteTests {

    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `text` to `name` in the temp dir with a fixed mtime, return path.
    @discardableResult
    private func writeFile(_ name: String, _ text: String, mtime: Date) throws
        -> String
    {
        let path = dir.appendingPathComponent(name).path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: path)
        return path
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private let old = Date(timeIntervalSince1970: 1_000_000)
    private let new = Date(timeIntervalSince1970: 2_000_000)

    private func configText(exportPath: String, autoPromote: Bool, theme: String)
        -> String
    {
        """
        [config]
        export-path = "\(exportPath)"
        auto-promote = \(autoPromote)

        [theme]
        name = "\(theme)"
        """
    }

    // MARK: - promotes when opted in and snapshot is newer

    @Test func promotesNewerSnapshot() throws {
        let snapPath = dir.appendingPathComponent("snap.toml").path
        let configPath = try writeFile("config.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "terminal"),
            mtime: old)
        try writeFile("snap.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "dracula"),
            mtime: new)

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)

        #expect(cfg.effectiveTheme == "dracula", "loaded the promoted snapshot")
        #expect(read(configPath).contains("dracula"),
                      "config.toml was overwritten with the snapshot")
    }

    // MARK: - staleness guard: older snapshot never wins

    @Test func staleSnapshotIsNotPromoted() throws {
        let snapPath = dir.appendingPathComponent("snap.toml").path
        let configPath = try writeFile("config.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "terminal"),
            mtime: new)  // config is NEWER (hand-edited between sessions)
        try writeFile("snap.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "dracula"),
            mtime: old)

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)

        #expect(cfg.effectiveTheme == "terminal", "hand-edit wins")
        #expect(!(read(configPath).contains("dracula")),
                       "config.toml untouched when snapshot is stale")
    }

    // MARK: - opt-out: auto-promote off → snapshot ignored

    @Test func autoPromoteOffIgnoresSnapshot() throws {
        let snapPath = dir.appendingPathComponent("snap.toml").path
        let configPath = try writeFile("config.toml",
            configText(exportPath: snapPath, autoPromote: false, theme: "terminal"),
            mtime: old)
        try writeFile("snap.toml",
            configText(exportPath: snapPath, autoPromote: false, theme: "dracula"),
            mtime: new)

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)

        #expect(cfg.effectiveTheme == "terminal")
        #expect(!(read(configPath).contains("dracula")))
    }

    // MARK: - missing snapshot → no-op

    @Test func missingSnapshotIsNoOp() throws {
        let snapPath = dir.appendingPathComponent("snap.toml").path  // never created
        let configPath = try writeFile("config.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "terminal"),
            mtime: old)

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        #expect(cfg.effectiveTheme == "terminal", "no snapshot → load as-is")
    }

    // MARK: - self-write refusal: export-path == config.toml

    @Test func selfWritePathIsRefused() throws {
        let configPath = try writeFile("config.toml",
            configText(exportPath: dir.appendingPathComponent("config.toml").path,
                       autoPromote: true, theme: "terminal"),
            mtime: old)
        // Even though "snapshot" (== config) is not newer than itself, assert
        // the guard by making the equal-path a no-op rather than a crash.
        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        #expect(cfg.effectiveTheme == "terminal")
    }

    // MARK: - a symlinked config.toml is written THROUGH, not clobbered

    @Test func promoteWritesThroughSymlinkedConfig() throws {
        // Dotfiles setup: config.toml is a symlink into a "repo" file.
        let repoPath = dir.appendingPathComponent("repo-config.toml").path
        let snapPath = dir.appendingPathComponent("snap.toml").path
        try writeFile("repo-config.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "terminal"),
            mtime: old)
        let linkPath = dir.appendingPathComponent("config.toml").path
        try FileManager.default.createSymbolicLink(
            atPath: linkPath, withDestinationPath: repoPath)
        try writeFile("snap.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "dracula"),
            mtime: new)

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: linkPath)

        #expect(cfg.effectiveTheme == "dracula", "promoted content loaded")
        // The link is PRESERVED (not replaced by a regular file)…
        let attrs = try FileManager.default.attributesOfItem(atPath: linkPath)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink,
                       "config.toml stays a symlink (dotfiles link intact)")
        // …and the repo target received the promoted content.
        #expect(read(repoPath).contains("dracula"),
                      "the promoted content landed on the real repo file")
    }

    // MARK: - equal mtime is NOT strictly newer → no promotion

    @Test func equalMtimeIsNotPromoted() throws {
        let snapPath = dir.appendingPathComponent("snap.toml").path
        let configPath = try writeFile("config.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "terminal"),
            mtime: old)
        try writeFile("snap.toml",
            configText(exportPath: snapPath, autoPromote: true, theme: "dracula"),
            mtime: old)  // SAME mtime

        let cfg = FacetConfig.bootstrapWithAutoPromote(path: configPath)
        #expect(cfg.effectiveTheme == "terminal",
                       "strictly-newer gate: equal mtime does not promote")
    }
}
