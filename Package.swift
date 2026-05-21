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
        .library(name: "FacetCore", targets: ["FacetCore"]),
    ],
    targets: [
        .target(name: "FacetCore"),
        .target(name: "FacetAdapterRift", dependencies: ["FacetCore"]),
        .target(name: "FacetAdapterNative", dependencies: ["FacetCore"]),
        .target(name: "FacetView", dependencies: ["FacetCore"]),
        .target(name: "FacetViewTree", dependencies: ["FacetView", "FacetCore"]),
        .target(name: "FacetViewGrid", dependencies: ["FacetView", "FacetCore"]),
        .executableTarget(
            name: "FacetApp",
            dependencies: [
                "FacetCore",
                "FacetAdapterRift",
                "FacetAdapterNative",
                "FacetView",
                "FacetViewTree",
                "FacetViewGrid",
            ]),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"]),
    ]
)
