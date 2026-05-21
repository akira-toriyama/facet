// Two levels:
//
//   - ``Log.line(_:)``  always on. AX focus mismatches, preview
//                       capture failures — anything the developer
//                       wants to see after the fact.
//   - ``Log.debug(_:)`` only when ``debugMode == true`` (set from
//                       ``facet --debug`` at startup). Use freely
//                       for refresh ticks, command dispatch, drag
//                       events. Zero overhead in normal runs (one
//                       bool check).
//
// Output:
//   - File ``/tmp/facet.log`` — always (both levels). Rotation
//     deliberately absent; tmp is volatile and macOS cleans it
//     on reboot.
//   - stderr — only when ``debugMode == true``. ``facet --debug``
//     foreground users see events live; bug reports via
//     ``facet --debug 2>&1 | tee bug.log`` capture everything.

import Foundation

/// Set once at startup by ``Main.swift`` from the ``--debug`` flag.
/// Read from many call sites in ``Log.debug`` (and from ``Log.line``
/// to decide stderr fan-out). No other code branches on this.
///
/// ``nonisolated(unsafe)``: write-once at app launch, then read-only.
/// The runtime never mutates it after the GUI starts.
nonisolated(unsafe) public var debugMode = false

public enum Log {
    public static let path = "/tmp/facet.log"

    /// Always-on operational log. Also mirrors to stderr when
    /// `--debug` is on so foreground users see real-time output.
    public static func line(_ s: String) {
        emit(s, prefix: "")
    }

    /// Verbose log. No-op unless ``debugMode == true``. Goes to
    /// both the file and stderr.
    public static func debug(_ s: String) {
        guard debugMode else { return }
        emit(s, prefix: "DEBUG ")
    }

    private static func emit(_ s: String, prefix: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts) \(prefix)\(s)\n"
        let data = Data(msg.utf8)
        // File: always (both levels — Log.debug is already guarded
        // above so we don't double-check here).
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: false, encoding: .utf8)
        }
        // stderr: only in --debug mode. Non-debug runs stay quiet
        // so a `facet &` background session doesn't pollute the
        // launching shell.
        if debugMode {
            FileHandle.standardError.write(data)
        }
    }
}
