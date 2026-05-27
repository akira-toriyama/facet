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
//   FacetAdapterRift    speaks `rift-cli`. Conforms to the backend
//                       protocol declared in FacetCore so the rest
//                       of the app doesn't know rift exists.
//
//   FacetAdapterNative  Swift implementation using AX / CGS / SLS
//                       directly. Phase-α onward — empty for now
//                       and grown alongside the rift adapter.
//
//   FacetAccessibility  AX / CGS helpers shared by both adapters
//                       (focus, title resolution, geometry, the
//                       private `_AXUIElementGetWindow` dlsym).
//                       Used to live inside FacetAdapterRift with
//                       `// MOVE-AT-M5` markers; lifted out when
//                       the native adapter became the second
//                       consumer.
//
//   FacetView           shared view primitives (theme, palette,
//                       fonts, common key monitor).
//
//   FacetViewTree       sidebar view (translucent tree panel).
//
//   FacetViewGrid       full-screen overview overlay (TS3-style).
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
        .target(name: "FacetAdapterRift",
                dependencies: ["FacetCore", "FacetAccessibility"]),
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
                "FacetAdapterRift",
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
        .testTarget(name: "FacetAdapterRiftTests",
                    dependencies: ["FacetAdapterRift", "FacetCore"]),
        .testTarget(name: "FacetAdapterNativeTests",
                    dependencies: ["FacetAdapterNative", "FacetCore"]),
        .testTarget(name: "FacetAccessibilityTests",
                    dependencies: ["FacetAccessibility", "FacetCore"]),
        .testTarget(name: "FacetViewGridTests",
                    dependencies: ["FacetViewGrid"]),
    ]
)
