// ScreenCaptureKit implementation of FacetCore's `WindowCapturing` port
// (the overview thumbnails + the tree hover preview). macOS 14+; requires
// the user to grant Screen Recording on first use. Short-TTL cache so
// repeated requests (hover bounce, grid refresh tick) reuse the latest
// capture. Stale in-flight requests are dropped via a monotonically
// increasing token so a moved selection doesn't race the previous
// capture's completion handler.
//
// Lives in its own adapter module (not FacetView) so the GUI layer stays
// free of OS-backend imports — capture is a backend, like AX / CGS, and
// reaches the view layer only through the `WindowCapturing` port.

@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation
import FacetCore

@available(macOS 14.0, *)
@MainActor
public final class SCKWindowCapture: WindowCapturing {
    private var cache: [WindowID: (img: CGImage, frame: CGRect, at: Date)] = [:]
    private var inflight = Set<WindowID>()
    // 5 s TTL covers both single-window hover (instant cache hit on
    // re-hover) and the grid view's background refresh loop (the
    // Controller re-requests on a ~4 s timer so the cache is always within
    // TTL when --view grid opens, eliminating the icon-fallback flash that
    // would otherwise show for the first 50-200 ms of each show).
    private let ttl: TimeInterval = 5.0
    private var token = 0

    public init() {}

    public func bump() { token &+= 1 }

    public func invalidate(_ id: WindowID) {
        cache.removeValue(forKey: id)
    }

    public func request(_ id: WindowID,
                        _ done: @escaping @MainActor
                          (CGImage, CGRect, WindowID) -> Void) {
        if let c = cache[id], Date().timeIntervalSince(c.at) < ttl {
            done(c.img, c.frame, id); return
        }
        if inflight.contains(id) { return }
        inflight.insert(id)
        let myToken = token
        Task { @MainActor in
            defer { self.inflight.remove(id) }
            do {
                // `excludingDesktopWindows(false, onScreenWindowsOnly: false)`:
                // include windows on other mac desktops / off-screen too —
                // that's the whole point (preview windows the user
                // can't currently see).
                let content = try await SCShareableContent
                    .excludingDesktopWindows(
                        false, onScreenWindowsOnly: false)
                guard let scw = content.windows.first(where: {
                    Int($0.windowID) == id.serverID
                }) else { return }
                let cfg = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                cfg.width = max(Int(scw.frame.width * scale), 1)
                cfg.height = max(Int(scw.frame.height * scale), 1)
                cfg.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: scw)
                let cg = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: cfg)
                self.cache[id] = (cg, scw.frame, Date())
                if myToken == self.token { done(cg, scw.frame, id) }
            } catch {
                let msg = "facet: preview wid=\(id.serverID) capture failed:"
                    + " \(error) (grant Screen Recording?)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
    }
}
