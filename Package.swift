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
// Tests are split per module under Tests/<Module>Tests. The view
// modules carry their own suites (the SwiftUI view models are where
// the tree/grid/rail logic lives since #448/#456/#457); FacetApp is
// the one target deliberately left untested — its Controller is
// orchestration over surfaces the VM gate exercises instead.

import PackageDescription

let package = Package(
    name: "facet",
    // macOS 26 floor (t-tbar family policy): raised from .v15 the moment
    // facet first bumps its sill pin into the 26-floor line (sill v2.0.0+
    // requires macOS 26 for the #17b/Phase-B SwiftUI migration). Spelled as
    // the STRING "26.0" — the only form both toolchains parse (`.v26` is
    // absent from CLT's PackageDescription 6.1, and tools-version 6.2 would
    // break CLT manifest parsing), so tools-version stays 6.0. Dropping
    // macOS <26 is a deliberate breaking change (t-kz0m).
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "facet", targets: ["FacetApp"]),
        .library(name: "FacetCore", targets: ["FacetCore"]),
    ],
    dependencies: [
        // Shared theming foundation (plan atelier). Pinned to a SemVer
        // tag for release/CI reproducibility; `.upToNextMinor` keeps it on
        // a single minor. Floor 8.8.0 carries `ObjectShape.dynamicValue` —
        // the TYPED open-map value schema for dynamic-ordinal tables that
        // gives the ONE `configSpec` `[desktop.<N>]` field-level completion
        // and strict validation instead of a bare permissive object
        // (t-kz0m; see FacetConfig+Spec.swift `desktop`). sill's macOS-26
        // floor (t-tbar) is what facet's `.macOS("26.0")` above tracks.
        //
        // BUMPING THIS: facet links EIGHT sill products (see the targets
        // below), not the four this comment used to name — ThemeKit,
        // ThemeKitUI, ListCore and GridCore joined with the SwiftUI view
        // migration (#448/#456/#457). Every sill major from 4.0.0 on has
        // touched at least one of them, measured by
        // `git diff --name-only <prev> <tag> -- Sources`:
        //   4.0.0  ConfigSchema, Effects
        //   5.0.0  Palette, PaletteKit, ThemeKit, ThemeKitUI
        //   6.0.0  Palette, PaletteKit, Effects, ThemeKitUI
        //   7.0.0  all of the above plus ConfigSchema and GridCore
        //   8.0.0  ThemeKitUI
        // So there is no module facet can assume is insulated, and
        // ThemeKitUI is the highest-traffic one: the last two pin bumps
        // (#458 → 8.8.1, #462 → 8.8.2) both shipped to fix a ThemeKitUI
        // regression facet's own suite did not catch. Read sill's release
        // notes for the linked eight and re-run the VM gate; a green
        // `swift build` proves nothing about the view layer.
        //
        // For local, atomic sill↔facet editing, temporarily swap this for
        // `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "8.8.0")),
        // swift-toml-edit — the family's ONE TOML implementation. It was
        // sill's in-tree `Toml` until sill 0.11.0 moved it into its own repo;
        // FacetCore takes `Toml` (pure, Foundation-only) from here now. The
        // module name is unchanged, so `import Toml` survives. Floor 3.0.0,
        // matching sill's own `.upToNextMajor(from: "3.0.0")` — the two
        // resolve to one 3.x, never a split graph. 3.0.0 retired the
        // line-based strict scanner and made `parse` delegate to
        // `parseWithSpans` (swift-toml-edit#19): an engine rewrite BEHIND
        // the same `parse` / `parseFlat` surface, so it was a pin-only bump.
        // facet reads `parseFlat` (`.tables` / `.arrays`), the lossless
        // `Toml.Annotated` DOM, and the scalar `settingValue(_:atTable:forKey:)`
        // that ConfigSnapshot writes an isolate desktop's retargeted
        // `[desktop.N] match=` with (t-sgqk).
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "3.0.0")),
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
            // ConfigSchema: one declarative `Spec` drives the config.toml
            // decode, the JSON Schema emitted for taplo completion
            // (`facet config --emit-schema`), AND `facet config --validate`
            // (sill 1.29.0 bridge) — so all three never drift.
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
            .product(name: "ThemeKit", package: "sill"),
        ]),
        .target(name: "FacetViewTree", dependencies: [
            "FacetView", "FacetCore",
            .product(name: "ThemeKitUI", package: "sill"),
            // ListCore: the pure DnD math (dragCandidates / chunkMemberIDs /
            // DropTarget) behind the host-driven keyboard lift (facet-2).
            .product(name: "ListCore", package: "sill"),
        ]),
        .target(name: "FacetViewGrid", dependencies: [
            "FacetView", "FacetCore",
            .product(name: "ThemeKitUI", package: "sill"),
            // GridCore: the pure grid math (nextGridIndex / fit sizing) behind
            // the host-driven keyboard nav, mirroring the tree's ListCore role.
            .product(name: "GridCore", package: "sill"),
        ]),
        .target(name: "FacetViewRail", dependencies: [
            "FacetView", "FacetCore",
            // ThemeKitUI: AnimatedBorderView renders the `[border]` neon
            // frame; the carousel itself is host-side (t-n3be: no sill
            // grid kit under the rail — rule-of-three fails).
            .product(name: "ThemeKitUI", package: "sill"),
        ]),
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
                // ConfigSchema: `facet config --validate` surfaces sill's
                // ValidationError values from FacetConfig.validate (t-0029).
                .product(name: "ConfigSchema", package: "sill"),
                // ListCore: DragContext/DropTarget in the tree's drop route
                // (Controller.treeDrop — facet-2).
                .product(name: "ListCore", package: "sill"),
            ]),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"]),
        .testTarget(name: "FacetAdapterNativeTests",
                    dependencies: ["FacetAdapterNative", "FacetCore"]),
        .testTarget(name: "FacetAccessibilityTests",
                    dependencies: ["FacetAccessibility", "FacetCore"]),
        .testTarget(name: "FacetViewTests",
                    dependencies: ["FacetView"]),
        .testTarget(name: "FacetViewGridTests",
                    dependencies: [
                        "FacetViewGrid",
                        "FacetView",          // overviewDropAckTimeout (t-88qt)
                        .product(name: "Palette", package: "sill"),
                        .product(name: "PaletteKit", package: "sill"),
                    ]),
        .testTarget(name: "FacetViewRailTests",
                    dependencies: [
                        "FacetViewRail",
                        .product(name: "Palette", package: "sill"),
                        .product(name: "PaletteKit", package: "sill"),
                    ]),
        .testTarget(name: "FacetViewTreeTests",
                    dependencies: ["FacetViewTree"]),
    ]
)
