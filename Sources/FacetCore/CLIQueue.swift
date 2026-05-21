// Off-main queue for blocking `WindowBackend` calls.
//
// rift-cli spawns block the calling thread for ~10ms; AX queries
// (future native adapter) similarly. View-side code wraps every
// backend call in `cliQueue.async { ... }` so refresh ticks don't
// hitch the panel.
//
// Name carried from ws-tabs on purpose: every lifted view file
// references `cliQueue` verbatim, and a rename now would touch
// hundreds of call sites for no behavior change. The dispatch
// label embeds "backend.queue" so Instruments / log traces stay
// accurate even before the symbol catches up (M5+).

import Foundation

public let cliQueue = DispatchQueue(
    label: "com.facet.backend.queue",
    qos: .userInitiated)
