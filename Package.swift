// swift-tools-version:6.0
//
// facet — Swift workspace + window manager for macOS.
//
// Multi-target layout (see docs/architecture.md):
//
//   FacetCore           pure logic: WS/Window state, focus rules,
//                       layout engines, event types. No AppKit,
//                       no backend. Fully testable.
//
//   FacetAdapterNative  Swift implementation using AX / CGS + the
//                       private `_AXUIElementGetWindow` dlsym.
//                       Sole `WindowBackend` implementation since
//                       Phase ε (v2.0.0) retired the rift adapter.
//
//   FacetAccessibility  AX / CGS helpers (focus, title resolution,
//                       geometry, display change detection).
//                       Originally extracted at M5 to share between
//                       the (then-coexisting) rift and native
//                       adapters; ε kept it as the single home
//                       for AX-touching code outside the adapter
//                       itself.
//
//   FacetView           shared view primitives (theme, palette,
//                       fonts, common key monitor).
//
//   FacetViewTree       sidebar view (translucent tree panel).
//
//   FacetViewGrid       full-screen overview overlay (Mission
//                       Control-style cells with ScreenCaptureKit
//                       thumbnails).
//
//   FacetApp            executable target: @main, CLI argv,
//                       Controller orchestration.
//
// Tests are split per module under Tests/<Module>Tests. GUI
// modules (Views, App) deliberately skipped — pure logic in Core
// + Adapter contract checks is where the value is.

import PackageDescription

let package = Package(
    name: "facet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "facet", targets: ["FacetApp"]),
        .executable(name: "native-spike", targets: ["NativeSpike"]),
        .library(name: "FacetCore", targets: ["FacetCore"]),
    ],
    targets: [
        .target(name: "FacetCore"),
        .target(name: "FacetAccessibility", dependencies: ["FacetCore"]),
        .target(name: "FacetAdapterNative",
                dependencies: ["FacetCore", "FacetAccessibility"]),
        .target(name: "FacetView", dependencies: ["FacetCore"]),
        .target(name: "FacetViewTree", dependencies: ["FacetView", "FacetCore"]),
        .target(name: "FacetViewGrid", dependencies: ["FacetView", "FacetCore"]),
        .executableTarget(
            name: "FacetApp",
            dependencies: [
                "FacetCore",
                "FacetAccessibility",
                "FacetAdapterNative",
                "FacetView",
                "FacetViewTree",
                "FacetViewGrid",
            ]),
        // Native-adapter feasibility spike (M5 Phase α). Throwaway:
        // probes CGWindowList enumeration, AX off-screen park /
        // restore (the virtual-workspace hide mechanism), AX focus,
        // and CGS/SLS space queries via dlsym. No facet deps.
        .executableTarget(name: "NativeSpike"),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"]),
        .testTarget(name: "FacetAdapterNativeTests",
                    dependencies: ["FacetAdapterNative", "FacetCore"]),
        .testTarget(name: "FacetAccessibilityTests",
                    dependencies: ["FacetAccessibility", "FacetCore"]),
        .testTarget(name: "FacetViewGridTests",
                    dependencies: ["FacetViewGrid"]),
    ]
)
