// Controller+ConfigPersistence — the config auto-export dirty hook (t-hdxb B3).
//
// Every session edit that has a home in config.toml (lens match, section /
// workspace rename, workspace layout, tag vocabulary) calls `markConfigDirty()`
// from its success branch. When `[config] export-path` is set, that schedules a
// debounced snapshot: the current effective config is gathered on the main
// actor, then rendered + atomic-written to the snapshot file on `cliQueue`
// (file I/O off the main actor). config.toml itself is NEVER touched here — the
// only sanctioned write to it is the startup auto-promote (B2). The snapshot is
// a separate, git-ignorable file that "grows" the live effective config; the
// user opts into promoting it back at the next launch.

import AppKit
import FacetCore

extension Controller {

    /// Mark the session config dirty → schedule a debounced snapshot export.
    /// A cheap no-op when auto-export is off (`[config] export-path` unset), so
    /// every call site can fire it unconditionally. TRAILING-edge debounced:
    /// while an export is armed, a later edit sets `configDirtyRedo` so the
    /// armed timer re-arms rather than firing — the export lands
    /// `configExportDebounce` after the LAST edit, by which point every edit's
    /// async backend round-trip has reconciled into `lastWorkspaces` (rename /
    /// layout / tag read that snapshot). This coalesces a burst AND avoids
    /// snapshotting a trailing edit stale.
    func markConfigDirty() {
        guard config.effectiveExportPath != nil else { return }  // auto-export off
        if configDirtyPending { configDirtyRedo = true; return }
        configDirtyPending = true
        armConfigExport()
    }

    private func armConfigExport() {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configExportDebounce
        ) { [weak self] in
            guard let self else { return }
            if self.configDirtyRedo {
                self.configDirtyRedo = false   // a later edit arrived — wait one
                self.armConfigExport()         // more window for its reconcile
                return
            }
            self.configDirtyPending = false
            self.exportConfigSnapshot()
        }
    }

    /// Gather the current overrides on the main actor, then render + atomic-write
    /// the snapshot on `cliQueue`. The render reads config.toml's text and
    /// surgically applies the overrides (see `ConfigSnapshot.render`); it never
    /// mutates config.toml.
    private func exportConfigSnapshot() {
        guard let rawExport = config.effectiveExportPath else { return }
        let baseDir = (configPath as NSString).deletingLastPathComponent
        let snapshotPath = FacetConfig.resolvePath(rawExport, relativeTo: baseDir)
        // Never write the snapshot onto config.toml — that would trip the
        // ConfigWatcher → reloadConfig loop (and violate the read-only rule).
        // Canonical same-file compare so `./config.toml` / `../facet/config.toml`
        // / a symlink alias can't slip past a raw-string check.
        guard !FacetConfig.isSameFile(snapshotPath, configPath) else {
            Log.line("config: [config] export-path must differ from config.toml "
                + "— auto-export skipped")
            return
        }
        let overrides = gatherOverrides()       // main-actor reads, into a Sendable value
        let cfgPath = configPath
        cliQueue.async {
            guard let text = try? String(contentsOfFile: cfgPath, encoding: .utf8)
            else {
                Log.debug("config: auto-export could not read \(cfgPath)")
                return
            }
            let rendered = ConfigSnapshot.render(configText: text, overrides: overrides)
            do {
                try rendered.write(toFile: snapshotPath, atomically: true,
                                   encoding: .utf8)
                Log.debug("config: auto-exported snapshot → \(snapshotPath)")
            } catch {
                Log.line("config: auto-export could not write \(snapshotPath): "
                    + "\(error)")
            }
        }
    }

    /// Build the `ConfigSnapshot.Overrides` from live Controller state (all
    /// main-actor reads). Match / label overrides accumulate per mac desktop
    /// across the session; workspace names / layouts are only knowable for the
    /// CURRENT desktop (`lastWorkspaces`), so they're populated for that ordinal
    /// alone, positionally (the k-th live workspace ↔ the k-th workspace slot).
    private func gatherOverrides() -> ConfigSnapshot.Overrides {
        var ov = ConfigSnapshot.Overrides()
        ov.label = sectionLabelOverride
        if let ordinal = currentMacDesktopOrdinal() {
            var labels: [Int: String] = [:]
            var layouts: [Int: String] = [:]
            for (slot, ws) in lastWorkspaces.enumerated() {
                labels[slot] = ws.name
                layouts[slot] = ws.layoutMode
            }
            ov.workspaceLabel = [ordinal: labels]
            ov.workspaceLayout = [ordinal: layouts]
        }
        ov.definedTags = inUseTagNames()
        return ov
    }

    /// The tag names currently on any live window — the `[tags] defined` union
    /// input (the renderer unions these with the config's own vocabulary, so a
    /// hand-authored `defined` list is never shrunk).
    private func inUseTagNames() -> [String] {
        var names = Set<String>()
        for ws in lastWorkspaces { for w in ws.windows { names.formUnion(w.tags) } }
        return names.sorted()
    }
}
