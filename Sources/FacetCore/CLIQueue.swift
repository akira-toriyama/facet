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

/// Dedicated high-priority queue for the focus fast-path (④ shake + ⑤
/// active-window border). The directly-felt focus reaction must NOT
/// queue behind the heavy reconcile work on `cliQueue` (enumerate +
/// classify + engine + preview + titles), which measured a ~100ms
/// median focus→react. This carries only one cheap AX focused-window
/// query, off-main so it can't hitch the panel either.
public let focusFastQueue = DispatchQueue(
    label: "com.facet.focus.fast",
    qos: .userInteractive)
