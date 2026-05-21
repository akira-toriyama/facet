// All `rift-cli` invocation in one place. Callers (controller,
// view-layer refresh tasks) are responsible for dispatching off the
// main thread — each spawn forks a process and blocks the calling
// thread until it exits (~10 ms).

import Foundation

enum RiftCLI {
    // Hard-coded for now; rift is brew-installed under Apple silicon's
    // Homebrew prefix. M5+ replaces this entire module with the
    // native adapter, so configurability isn't worth the boilerplate.
    static let path = "/opt/homebrew/bin/rift-cli"

    @discardableResult
    static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // stderr → /dev/null. An unread Pipe can fill its ~64 KB
        // buffer and deadlock the child (stderr write) against the
        // parent (reading stdout). rift-cli's stderr is never useful
        // to us, so drop it outright.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
