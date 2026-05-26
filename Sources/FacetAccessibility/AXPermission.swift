// Single-helper module for the "is Accessibility granted?" check
// + user-facing error message. Both `FacetAdapterRift` and
// `FacetAdapterNative` need to surface the same hint in their
// `errors` AsyncStream when the user hasn't granted facet
// Accessibility in System Settings — without this helper each
// adapter would carry the same multi-line string verbatim.

import ApplicationServices

public enum AXPermission {

    /// User-facing message to push into the adapter's `errors`
    /// stream when AX is missing. `nil` when the grant is in
    /// place — callers can `if let msg = ... { push(msg) }` to
    /// keep the no-op fast path obvious.
    ///
    /// Intentionally **not** prompt-based: the rift adapter
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
