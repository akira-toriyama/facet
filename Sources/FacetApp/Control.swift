// Shared constants for the CLI↔GUI IPC bridge. The server side
// (Controller, in this same module) observes
// ``ctrlNotificationName``; the client side (Main.swift's argv
// dispatch) posts to it before exiting.
//
// Name is intentionally **shared between dev and release** so one
// running instance handles the CLI regardless of which build is
// active. This is a DNC channel name, NOT a bundle id, so it stays
// put even if the bundle id changes between dev/release.

import Foundation

let ctrlNotificationName = "com.facet.app.control"
