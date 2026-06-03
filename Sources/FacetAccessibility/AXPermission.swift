// Single-helper module for the "is Accessibility granted?" check
// + user-facing error message. `FacetAdapterNative` surfaces this
// hint in its `errors` AsyncStream when the user hasn't granted
// facet Accessibility in System Settings. Factored into this shared
// helper at M5 (then two adapters; native is the sole backend since
// v2.0.0) so the multi-line string lives in one place.

import ApplicationServices

public enum AXPermission {

    /// User-facing message to push into the adapter's `errors`
    /// stream when AX is missing. `nil` when the grant is in
    /// place — callers can `if let msg = ... { push(msg) }` to
    /// keep the no-op fast path obvious.
    ///
    /// Intentionally **not** prompt-based: the adapter
    /// reports passively (via `facet status`'s lastError) so the
    /// user can find it after the fact. Use `AX.ensureTrusted()`
    /// when you want the system permission dialog.
    public static func errorMessageIfMissing() -> String? {
        guard !AXIsProcessTrusted() else { return nil }
        return "Accessibility permission not granted — open "
            + "System Settings → Privacy & Security → "
            + "Accessibility, enable facet, then restart"
    }
}
