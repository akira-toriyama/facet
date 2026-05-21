// Append-only file log. Used by AX focus + (future) preview capture
// to leave a breadcrumb trail when something goes wrong during user
// interaction — UI doesn't have a console to print to.
//
// Path is `/tmp/facet.log`; rotation / size cap intentionally absent
// (tmp is volatile and macOS cleans it on reboot).

import Foundation

enum Log {
    static let path = "/tmp/facet.log"

    static func line(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let msg = "\(ts) \(s)\n"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(msg.utf8))
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
