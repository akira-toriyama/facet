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
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "facet", targets: ["FacetApp"]),
        .library(name: "FacetCore", targets: ["FacetCore"]),
    ],
    dependencies: [
        // Shared theming foundation (plan atelier). Pinned to a SemVer
        // tag for release/CI reproducibility; `.upToNextMinor` keeps it on
        // a single minor. Floor 1.27.0 = the sill release that moved its OWN
        // swift-toml-edit floor to 2.0.0 (the breaking `Toml.Row`/source-span
        // bump, chord#148) — so facet's DIRECT swift-toml-edit 2.x pin below
        // and sill's transitive one resolve to the same 2.x, never a split
        // graph. (Pre-2.0.0 it was 1.26.0 = the `ConfigSchema` module after
        // #138 S3 routed `Spec.jsonSchema()` through the shared `SchemaEmit`
        // lowering and added `Spec.Field.enumDocs`.) For local, atomic
        // sill↔facet editing, temporarily swap this for `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "1.27.0")),
        // swift-toml-edit — the family's ONE TOML implementation. It was
        // sill's in-tree `Toml` until sill 0.11.0 moved it into its own repo;
        // FacetCore takes `Toml` (pure, Foundation-only) from here now. The
        // module name is unchanged, so `import Toml` survives. Floor 2.0.0:
        // the family unified on swift-toml-edit 2.x (chord#148). 2.0.0's break
        // — source spans carried on a typed `Toml.Row`, the synthetic
        // `__line__` key dropped — is confined to the STRICT nested `parse` /
        // `Value.arrayOfTables` surface; facet reads only `parseFlat`
        // (`.tables` / `.arrays`, element type unchanged) and the lossless
        // `Toml.Annotated` DOM (board nesting, `parseTOMLNestedTabs`), neither
        // of which 2.0.0 touched — so this is a pin-only bump, no code change.
        // `.upToNextMajor` mirrors sill's own pin for this bedrock dependency.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        // FacetCore links sill's PURE `Palette` module (AppKit-free, so it
        // doesn't break FacetCore's no-AppKit rule) for `canonical(_:)` —
        // the single source of truth for valid `--theme=` names — and the
        // `Toml` module (pure, Foundation-only) for config parsing, now from
        // swift-toml-edit (split out of sill at 0.11.0).
        .target(name: "FacetCore", dependencies: [
            .product(name: "Palette", package: "sill"),
            .product(name: "Toml", package: "swift-toml-edit"),
            // ConfigSchema: one declarative `Spec` drives BOTH the
            // config.toml decode and the JSON Schema emitted for taplo
            // completion (`facet --emit-schema`) — so the two never drift.
            .product(name: "ConfigSchema", package: "sill"),
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
        // Capture adapter: the sole ScreenCaptureKit consumer, behind
        // FacetCore's `WindowCapturing` port (so FacetView stays free of
        // OS-backend imports). Same role as FacetAdapterNative for AX/CGS.
        .target(name: "FacetCapture", dependencies: ["FacetCore"]),
        .executableTarget(
            name: "FacetApp",
            dependencies: [
                "FacetCore",
                "FacetAccessibility",
                "FacetAdapterNative",
                "FacetCapture",
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
        .testTarget(name: "FacetViewTreeTests",
                    dependencies: ["FacetViewTree"]),
    ]
)
