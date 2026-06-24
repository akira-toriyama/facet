// Port for per-window image capture — the overview thumbnails (grid +
// rail) and the tree's hover preview. FacetCore owns this protocol so the
// view / app layers depend on the SEAM, not the OS capture backend —
// the same hexagonal split as `WindowBackend` (AX / CGS): "crossing
// layers always means there's a missing protocol", and this is it for
// capture. The sole implementation, `SCKWindowCapture` (ScreenCaptureKit),
// lives in the `FacetCapture` adapter; FacetView no longer imports
// ScreenCaptureKit.
//
// The callback delivers a `CGImage` (CoreGraphics — FacetCore is
// AppKit-free) plus the window's logical frame; the consumer wraps it in
// an `NSImage` for drawing (`NSImage(cgImage:size:)` with `frame.size`).
// Caching / TTL / in-flight de-duplication are the implementation's job.

import CoreGraphics

// `Sendable` so the existential `any WindowCapturing` can be captured in
// the @Sendable timer / dispatch closures the Controller schedules —
// safe because every conformer is `@MainActor` (all access serialised on
// the main actor), exactly as the old concrete `@MainActor` class was.
@MainActor
public protocol WindowCapturing: AnyObject, Sendable {
    /// Invalidate any in-flight result (e.g. the selection moved away).
    /// Doesn't cancel the capture — just makes its completion drop the
    /// result instead of firing the callback.
    func bump()

    /// Drop the cached image for one window so the next `request`
    /// re-captures. Used after a DnD that may have resized / reflowed the
    /// window (BSP / stack reflows can leave a cached thumbnail stale).
    func invalidate(_ id: WindowID)

    /// Deliver the window's current image. A cache hit (within TTL) fires
    /// `done` synchronously; otherwise an async capture fires it later on
    /// the main actor. `done` carries the captured `CGImage`, the
    /// window's logical frame, and its id.
    func request(_ id: WindowID,
                 _ done: @escaping @MainActor (CGImage, CGRect, WindowID) -> Void)
}
