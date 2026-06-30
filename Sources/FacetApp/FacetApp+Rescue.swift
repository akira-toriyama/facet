// `facet --rescue` — one-shot crash recovery. facet parks hidden
// windows at a display's bottom-right anchor sliver `(maxX-1, maxY-1)`
// (position only, no resize). A graceful quit restores them itself
// (mechanism ①); but if facet CRASHES, those windows are stranded in
// the corner. `facet --rescue` is the documented recovery command:
// it scans the ACTIVE desktop for corner-parked windows and moves
// them back on-screen, then exits — WITHOUT starting the server
// (facet is presumed dead).
//
// Stateless (detects purely from live geometry — facet never persists,
// memory: config-default-behavior) and approximate ("画面内であれば OK":
// the goal is just to make them visible, not to restore the exact
// pre-park position). Active-desktop scope only — public AX can move
// windows on the current Space only (memory: facet-per-native-space-ws);
// re-run after switching desktops to rescue another one.
//
// Same one-shot shape as `--resign` / `--emit-schema`: a maintenance
// subcommand that runs before the server and `exit`s.

import AppKit
import CoreGraphics
import FacetAccessibility
import FacetCore

extension FacetApp {

    // MARK: - --rescue

    /// Scan the active desktop for anchor-sliver-parked windows and
    /// move each back on-screen. Reuses facet's own `com.facet.app`
    /// AX grant (AX trust is keyed on code signature, so a one-shot
    /// invocation of the signed binary is trusted just like the
    /// server). Always exits:
    ///   0 — done (N moved, including N=0 — nothing to rescue is success)
    ///   3 — Accessibility not granted (can't move anything)
    static func runRescue() -> Never {
        if let msg = AXPermission.errorMessageIfMissing() {
            FileHandle.standardError.write(Data("facet: \(msg)\n".utf8))
            exit(3)
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let candidates = AXRescue.liveCandidates(excludingPID: selfPID)

        // Per-display on-screen destination. `visibleFrame` is
        // @MainActor; this one-shot runs on the main thread with no
        // run loop yet, so `assumeIsolated` is safe (memory: R1 in the
        // window-rescue plan).
        let moved = AXRescue.rescueCornerParked(candidates) { bounds in
            let anchor = CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1)
            let visible = MainActor.assumeIsolated {
                Displays.visibleFrame(containing: anchor)
            }
            return RescueGeometry.rescueTarget(visibleFrame: visible)
        }

        if FacetApp.isServerRunning() {
            FileHandle.standardError.write(Data((
                "facet: server is running; rescued \(moved) window(s) on "
                + "the active desktop — they may be re-hidden on the next "
                + "workspace switch\n").utf8))
        }
        print("facet: rescued \(moved) window(s) on the active desktop")
        exit(0)
    }
}
