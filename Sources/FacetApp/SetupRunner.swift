// External shell-hook runner — invokes each path in
// `config.toml`'s `[workspace] setupFiles = [...]` once at startup,
// in declared order, fire-and-forget after spawn.
//
// Why this exists
//
//   Architecture.md Phase α frozen decisions: facet does NOT
//   persist workspace assignments itself ("Persistence: not in
//   facet. External sh hook via `setupFiles` config key
//   (Vitest-style)"). The hook is the user's escape hatch to
//   recreate their preferred layout on launch — they write a
//   script that uses the normal `facet --workspace=N` and
//   `facet window --move-to=N` CLI to move windows where they
//   want them.
//
// Invocation model
//
//   - Fire-and-forget after the DNC listener is up, so the script
//     can immediately invoke `facet status` / `facet --workspace=N`
//     and reach the running server. No blocking — a hung script
//     can't stall facet startup.
//   - Each script gets its own `Process`; failures (missing file,
//     non-zero exit, spawn refused) surface as a single line in
//     the errors stream so they land in `facet status`'s lastError
//     slot exactly like adapter errors.
//   - stdout / stderr → `Log.debug` with the script path as
//     prefix, so `--debug` runs show what each hook did.

import Foundation
import FacetCore

public enum SetupRunner {

    /// Spawn every script in `paths` (already tilde / env-expanded).
    /// `onError` is called once per script that fails — caller wires
    /// it to the adapter's `errors` continuation.
    public static func runAll(
        paths: [String],
        onError: @escaping @Sendable (String) -> Void
    ) {
        guard !paths.isEmpty else { return }
        Log.debug("setup: spawning \(paths.count) hook(s)")
        for path in paths {
            spawn(path: path, onError: onError)
        }
    }

    private static func spawn(
        path: String,
        onError: @escaping @Sendable (String) -> Void
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            onError("setupFiles: \(path) — file not found")
            return
        }
        // `isExecutableFile` is a perms check, not a filetype one;
        // a non-executable script gets a clearer error here than
        // the opaque NSPosixError from Process.run.
        guard fm.isExecutableFile(atPath: path) else {
            onError("setupFiles: \(path) — not executable "
                + "(chmod +x?)")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Forward stdout / stderr line-by-line into the log. Both
        // pipes drain on background queues — the Process exits as
        // soon as the script does; we don't `waitUntilExit()` so
        // hooks stay fire-and-forget.
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            forwardToLog(prefix: "setup[\(path)]", data: data)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            forwardToLog(prefix: "setup[\(path)] stderr",
                         data: data)
        }
        proc.terminationHandler = { p in
            if p.terminationStatus != 0 {
                onError("setupFiles: \(path) exited "
                    + "\(p.terminationStatus)")
            } else {
                Log.debug("setup: \(path) done")
            }
        }
        do {
            try proc.run()
            Log.debug("setup: spawned \(path) pid="
                + "\(proc.processIdentifier)")
        } catch {
            onError("setupFiles: \(path) — spawn failed: "
                + "\(error.localizedDescription)")
        }
    }

    private static func forwardToLog(prefix: String, data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        for line in s.split(separator: "\n",
                            omittingEmptySubsequences: true) {
            Log.debug("\(prefix): \(line)")
        }
    }
}
