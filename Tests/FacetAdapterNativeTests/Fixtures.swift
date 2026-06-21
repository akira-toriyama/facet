import CoreGraphics
@testable import FacetCore
@testable import FacetAdapterNative

// Shared test scaffolding for the FacetAdapterNativeTests target
// (tests-02 dedup). These free, file-scope helpers replace the
// per-file `private func` copies that were byte-identical (or
// trivially parameterized) across the suite. All are pure — none
// touch instance state — so a free function is a faithful drop-in
// for the former private methods.

/// Window id from a small int.
func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }

/// Test window. The defaulted labels are a SUPERSET of every former
/// per-file `window(_:)`, so existing call sites stay zero-diff:
/// `window(10)`, `window(10, pid: 9)`, `window(20, onscreen: false)`,
/// `window(30, floating: true)`.
/// Pass `appName:` to override the default `"A"` so a lens `match='app=…'`
/// can discriminate windows in cross-workspace gather tests.
func window(_ n: Int, pid: Int = 1000,
            onscreen: Bool = true,
            floating: Bool = false,
            appName: String = "A") -> Window {
    Window(id: wid(n), pid: pid, appName: appName,
           title: "w\(n)", isFocused: false,
           isFloating: floating, frame: nil, isOnscreen: onscreen)
}

/// `n` contiguous unnamed workspaces — the plain seed shared by the
/// catalog / sticky / scratchpad / hide-reclaim suites.
func seededCatalog(_ n: Int = 5) -> WorkspaceCatalog {
    var c = WorkspaceCatalog()
    c.seed(configs: (1...n).map {
        (index: $0, config: WorkspaceConfig(name: ""))
    })
    return c
}

/// `wid(1) | wid(2)` vertical split (the DnD / resize / rotate suites
/// all build this in a 1600x900 rect).
func twoVertical(in rect: CGRect = CGRect(x: 0, y: 0, width: 1600, height: 900)) -> LayoutTree {
    var t = LayoutTree()
    t.insert(wid(1), focused: nil, in: rect)
    t.insert(wid(2), focused: wid(1), in: rect)
    return t
}

/// Bare adapter for suites that don't read config (windowMenu / query).
func adapter() -> NativeAdapter { NativeAdapter(config: FacetConfig()) }
