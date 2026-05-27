// Off-main queue for blocking `WindowBackend` calls.
//
// AX queries can take ~10ms each (cross-process). View-side code
// wraps every backend call in `cliQueue.async { ... }` so refresh
// ticks don't hitch the panel. The dispatch label embeds
// "backend.queue" so Instruments / log traces are accurate.

import Foundation

public let cliQueue = DispatchQueue(
    label: "com.facet.backend.queue",
    qos: .userInitiated)
