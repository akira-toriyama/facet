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
//   FacetViewRail       bottom-of-screen workspace rail (compact
//                       Mission-Control-style bar: click a box to
//                       switch, hover for window thumbnails, drag a
//                       window between boxes).
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
    dependencies: [
        // Shared theming foundation (plan atelier). Pinned to a SemVer
        // tag for release/CI reproducibility; `.upToNextMinor` keeps it
        // on a single pre-1.0 minor (a pre-1.0 minor can break, so don't
        // auto-jump). Floor 0.7.1 = the `Toml` module (the family's ONE
        // hand-rolled TOML subset parser; facet's in-tree parser folded
        // into it in atelier Phase 1.6) + its escape-aware comment fix.
        // For local, atomic sill↔facet editing, temporarily swap this
        // line for `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        // FacetCore links sill's PURE `Palette` module (AppKit-free, so it
        // doesn't break FacetCore's no-AppKit rule) for `canonical(_:)` —
        // the single source of truth for valid `--theme=` names — and the
        // `Toml` module (pure, Foundation-only) for config parsing.
        .target(name: "FacetCore", dependencies: [
            .product(name: "Palette", package: "sill"),
            .product(name: "Toml", package: "sill"),
        ]),
        .target(name: "FacetAccessibility", dependencies: ["FacetCore"]),
        .target(name: "FacetAdapterNative",
                dependencies: ["FacetCore", "FacetAccessibility"]),
        .target(name: "FacetView", dependencies: [
            "FacetCore",
            .product(name: "Palette", package: "sill"),
            .product(name: "PaletteKit", package: "sill"),
            .product(name: "Effects", package: "sill"),
        ]),
        .target(name: "FacetViewTree", dependencies: ["FacetView", "FacetCore"]),
        .target(name: "FacetViewGrid", dependencies: ["FacetView", "FacetCore"]),
        .target(name: "FacetViewRail", dependencies: ["FacetView", "FacetCore"]),
        .executableTarget(
            name: "FacetApp",
            dependencies: [
                "FacetCore",
                "FacetAccessibility",
                "FacetAdapterNative",
                "FacetView",
                "FacetViewTree",
                "FacetViewGrid",
                "FacetViewRail",
            ]),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"]),
        .testTarget(name: "FacetAdapterNativeTests",
                    dependencies: ["FacetAdapterNative", "FacetCore"]),
        .testTarget(name: "FacetAccessibilityTests",
                    dependencies: ["FacetAccessibility", "FacetCore"]),
        .testTarget(name: "FacetViewGridTests",
                    dependencies: ["FacetViewGrid"]),
    ]
)
