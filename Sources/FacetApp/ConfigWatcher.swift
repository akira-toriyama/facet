// File-system watcher for ~/.config/facet/config.toml so the
// Controller can hot-reload theme / preview-mode / [workspaces]
// changes without a restart.
//
// Design (memory facet-cli-surface N11 + N15):
//   - A path: this watcher fires `onChange` whenever the file
//     mutates. Default behaviour.
//   - B path: `facet --reload` (DNC trigger, handled in
//     Controller) bypasses the watcher and calls the same
//     `reloadConfig()` directly. Both paths converge.
//
// Atomic-rename resilience: editors (vim / VSCode) and shell
// templates use the `mktemp + rename` idiom, which deletes the
// original file and the watched fd goes stale. We re-arm on
// `.delete` events by closing the old source and re-opening
// the file by path after a short backoff (lets the rename
// complete + file appear).

import Darwin
import Foundation
import FacetCore

@MainActor
final class ConfigWatcher {

    /// Coalesce window — multiple events within this interval
    /// collapse into a single `onChange` call. Picks 0.2s as a
    /// compromise: long enough that an editor's "delete + create
    /// + write" burst becomes one reload, short enough that
    /// reload feels instant to a human.
    private let debounceInterval: TimeInterval = 0.2

    /// Wait this long after a file disappears before trying to
    /// re-open. atomic rename usually completes well under
    /// 100ms; 50ms is plenty for the new inode to settle.
    private let reopenBackoff: TimeInterval = 0.05

    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debouncePending = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        openAndWatch()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func openAndWatch() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Log.debug("ConfigWatcher: open(\(path)) failed (\(errno))")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = src.data
            // .delete / .rename → fd is now stale, reopen.
            if mask.contains(.delete) || mask.contains(.rename) {
                self.reopen()
                self.scheduleDebouncedChange()
                return
            }
            self.scheduleDebouncedChange()
        }
        src.setCancelHandler { [fd] in
            if fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
        Log.debug("ConfigWatcher: watching \(path)")
    }

    private func reopen() {
        source?.cancel()
        source = nil
        fd = -1
        DispatchQueue.main.asyncAfter(
            deadline: .now() + reopenBackoff
        ) { [weak self] in
            self?.openAndWatch()
        }
    }

    /// Coalesce a burst of events into one `onChange` call. The
    /// MainActor isolation is fine because DispatchSource posts
    /// to `.main` and `onChange` is called on the main thread.
    private func scheduleDebouncedChange() {
        guard !debouncePending else { return }
        debouncePending = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + debounceInterval
        ) { [weak self] in
            guard let self else { return }
            self.debouncePending = false
            self.onChange()
        }
    }
}
