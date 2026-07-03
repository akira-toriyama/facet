import Testing
@testable import FacetAccessibility

/// Regression guard for t-bcpw.
///
/// `MacDesktops`' read-only SkyLight queries (`activeID` / `ordinal(for:)` /
/// `ordinalMap`) funnel into `SLSCopyManagedDisplaySpaces` →
/// `SLSWindowManagementClientOperationsEnabled` → `SLSWMBridgeDelegate()`,
/// which lazily creates/tears down an `SLSWindowManagementFallbackBridge` and
/// stores a *weak* reference to it. That SkyLight path is NOT thread-safe.
///
/// Swift Testing runs suites in parallel on the cooperative pool, so many
/// concurrent `NativeAdapter.init`s (each reads `MacDesktops` in init)
/// hammered SLS at once and intermittently tripped an objc
/// "Cannot form weak reference to instance … of class
/// SLSWindowManagementFallbackBridge … over-released" SIGABRT. The t-bcpw
/// crash logs caught every one of the 12 cooperative threads inside
/// `SLSCopyManagedDisplaySpaces` — one mid-`dealloc`, one forming a weak ref
/// to the object being deallocated.
///
/// facet can't fix Apple's SkyLight, but it fully controls *its own*
/// concurrency into it: `MacDesktops` serializes every SLS call behind one
/// process-wide lock, so the fallback bridge is only ever touched
/// single-threaded. This test forces the exact concurrency the crash showed —
/// pre-fix it aborts the whole test process, post-fix it runs clean.
struct MacDesktopsConcurrencyTests {

    @Test func concurrentSkyLightQueriesDoNotRaceTheFallbackBridge() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<50 {
                        let id = MacDesktops.activeID()
                        _ = MacDesktops.ordinal(for: id)
                        _ = MacDesktops.ordinalMap()
                        _ = MacDesktops.available
                    }
                }
            }
        }
    }
}
