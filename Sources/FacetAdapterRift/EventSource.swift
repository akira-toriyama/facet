// Long-lived `rift-cli subscribe mach *` reader, exposed as an
// `AsyncStream<BackendEvent>`. Self-respawns with 1→2→4…→30 s
// backoff: rift restart, transient crashes, or rift-cli itself
// exiting because rift went away should all be survived without
// spamming forks. Any flowing event (or a long-lived run) resets
// backoff to 1 s.

import Foundation
import FacetCore

final class EventSource: @unchecked Sendable {
    let stream: AsyncStream<BackendEvent>
    private let continuation: AsyncStream<BackendEvent>.Continuation

    // Single serial queue owns proc + backoff state. Process I/O
    // callbacks bounce here so all mutation is single-threaded;
    // `@unchecked Sendable` is justified by this invariant.
    private let queue = DispatchQueue(
        label: "com.facet.adapter.rift.events",
        qos: .userInitiated)
    private var proc: Process?
    private var backoff: TimeInterval = 1
    private let backoffCap: TimeInterval = 30
    private var startedAt = Date()

    init() {
        var capturedContinuation: AsyncStream<BackendEvent>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) {
            capturedContinuation = $0
        }
        self.continuation = capturedContinuation
        queue.async { [weak self] in self?.spawn() }
    }

    deinit {
        proc?.terminate()
        continuation.finish()
    }

    private func spawn() {
        Log.debug("event subscribe spawn (backoff=\(backoff)s)")
        startedAt = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RiftCLI.path)
        p.arguments = ["subscribe", "mach", "*"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard !h.availableData.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.backoff = 1
                Log.debug("event refreshNeeded")
                self.continuation.yield(.refreshNeeded)
            }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                let aliveSec = Date().timeIntervalSince(self.startedAt)
                Log.debug("event subscribe died (alive=\(Int(aliveSec))s)")
                // A subscribe child that lived a while before dying
                // is "healthy" — usually rift restart, not a crash
                // loop. Reset backoff so the respawn is immediate
                // next time too.
                if aliveSec > 10 {
                    self.backoff = 1
                }
                let delay = self.backoff
                self.backoff = min(self.backoff * 2, self.backoffCap)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    [weak self] in self?.spawn()
                }
            }
        }
        do { try p.run(); proc = p } catch {}
    }
}
