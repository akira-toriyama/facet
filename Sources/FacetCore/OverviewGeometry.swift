// Pure geometry / index helpers shared by the grid + rail overviews
// (the two "overview" surfaces that paint workspace cells + window
// thumbnails). Backend-neutral, AppKit-free — unit-testable in FacetCore.

/// Cycle a keyboard selection cursor across one workspace's slots: the
/// whole-workspace slot (encoded as `-1`) plus its `windowCount` window
/// slots (`0…windowCount-1`), wrapping at both ends.
///
/// `current` is clamped into range first, so a stale cursor (e.g. the
/// window set shrank) lands somewhere valid. Returns the next index in
/// `-1…windowCount-1`. Shared by `GridView` / `RailView` `kbCycleWindow`,
/// which previously held an identical copy of this modular arithmetic.
public func cycleSlotIndex(current: Int, windowCount: Int, forward: Bool) -> Int {
    let slots = windowCount + 1                                   // whole-WS(-1) + windows
    let cur = max(-1, min(windowCount - 1, current)) + 1          // → 0…windowCount
    let next = forward ? (cur + 1) % slots : (cur - 1 + slots) % slots
    return next - 1                                              // back to -1…windowCount-1
}
