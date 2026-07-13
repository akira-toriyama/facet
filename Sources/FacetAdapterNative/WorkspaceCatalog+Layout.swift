// Layout maintenance / layout mode / stack ops / leave-focus snapshot / floating.
// Extracted unchanged from WorkspaceCatalog.swift (#182 phase 2) —
// same-module extension, no logic change. Stored state stays on the
// primary declaration (WorkspaceCatalog.swift).

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    // MARK: - Layout maintenance (internal)

    /// Remove `id` from any layout container (`layoutTrees` and
    /// `stackOrders`) that holds it. Memory: lessons file
    /// "stackOrders / layoutTrees 並列メンテ" — every mutator
    /// must touch both, this is the one place to forget.
    /// Idempotent.
    mutating func detachFromLayouts(_ id: WindowID) {
        for (ws, var tree) in layoutTrees where tree.contains(id) {
            tree.remove(id)
            layoutTrees[ws] = tree
        }
        for (ws, var order) in stackOrders where order.contains(id) {
            order.removeAll { $0 == id }
            stackOrders[ws] = order
        }
    }

    /// Insert `id` into the layout container appropriate to
    /// `n1Based`'s mode (bsp → tree; stack → per-WS order at index 0
    /// so the joining window is the one shown; stateless engine →
    /// append to the per-WS order so it joins the stack without
    /// seizing master; anything else → no-op). Skips when `id` is
    /// floating.
    /// `focused` / `rect` only matter for the bsp path (passed
    /// to `LayoutTree.insert` for orientation choice).
    mutating func attachToLayout(_ id: WindowID,
                                         workspace n1Based: Int,
                                         focused: WindowID?,
                                         in rect: CGRect) {
        guard !floatingWindows.contains(id) else { return }
        let m = mode(of: n1Based)
        if m == StatefulMode.bsp {
            var tree = layoutTrees[n1Based] ?? LayoutTree()
            tree.insert(id, focused: focused, in: rect)
            layoutTrees[n1Based] = tree
        } else if m == StatefulMode.stack {
            // Stack ("one at a time") shows order[0] and parks the rest
            // at the anchor sliver, so a joining window takes the TOP
            // (index 0) — you see what you just opened / moved in.
            var order = stackOrders[n1Based] ?? []
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
            stackOrders[n1Based] = order
        } else if LayoutRegistry.engine(named: m) != nil {
            // Stateless master-stack / tiling engines (master-* / grid
            // / spiral) share the same per-WS order. A
            // window joining — new adoption, un-float, or move-in —
            // APPENDS to the end so it joins the stack rather than
            // seizing the master slot (order[0]); opening or moving a
            // window must not displace the established master. Master is
            // taken only by the explicit `promoteToMaster`. Bonus: if a
            // window ever slips past the classify gate, the tail is the
            // least-disruptive slot — it shifts nothing.
            var order = stackOrders[n1Based] ?? []
            order.removeAll { $0 == id }
            order.append(id)
            stackOrders[n1Based] = order
        }
    }

    // MARK: - Layout mode

    // (`defaultMode` is a stored property, so it lives on the primary
    // declaration — extensions can't hold stored state.)

    /// 1-based WS index → mode string. Missing entries fall back to
    /// `defaultMode` (config `[layout] default`, else `"float"`).
    func mode(of n1Based: Int) -> String {
        layoutModes[n1Based] ?? defaultMode
    }

    /// Change the mode of a workspace. Side-effects on layout
    /// state:
    ///   - → `"bsp"`: build a fresh tree from the WS's current
    ///     non-floating windows (auto-balance order, sorted by
    ///     `WindowID.serverID` for deterministic insertion).
    ///     Discards any existing stack order.
    ///   - → `"stack"`: build a fresh stack-order list from the
    ///     WS's current non-floating windows (id-sorted; caller
    ///     can promote a different top via `cycleStack` if the
    ///     starting top matters). Discards any existing tree.
    ///   - → `"float"` / anything else: discard both tree and
    ///     stack-order entries. Adapter leaves the windows
    ///     wherever they were last placed.
    ///
    /// Caller drives the AX side-effects (re-tile / re-stack /
    /// no-op). Returns the normalised mode so the caller can
    /// branch.
    @discardableResult
    mutating func setMode(workspace n1Based: Int,
                                 to mode: String,
                                 in rect: CGRect = .zero) -> String {
        let normalised = mode.lowercased()
        layoutModes[n1Based] = normalised
        let members = nonFloatingMembers(of: n1Based)
        switch normalised {
        case StatefulMode.bsp:
            var tree = LayoutTree()
            for id in members {
                tree.insert(id, focused: nil, in: rect)
            }
            layoutTrees[n1Based] = tree
            stackOrders.removeValue(forKey: n1Based)
        case StatefulMode.stack:
            stackOrders[n1Based] = members
            layoutTrees.removeValue(forKey: n1Based)
        default:
            if LayoutRegistry.engine(named: normalised) != nil {
                // Stateless engine (master-*, grid, spiral): seed the
                // shared per-WS order; discard any tree.
                stackOrders[n1Based] = members
                layoutTrees.removeValue(forKey: n1Based)
            } else {
                // float / unknown → no managed layout state.
                layoutTrees.removeValue(forKey: n1Based)
                stackOrders.removeValue(forKey: n1Based)
            }
        }
        return normalised
    }

    // MARK: - Stack ops

    /// Ordered stack members of `n1Based` (top first), or empty
    /// when the WS isn't in `"stack"` mode.
    func stackOrder(of n1Based: Int) -> [WindowID] {
        stackOrders[n1Based] ?? []
    }

    enum CycleDirection: Sendable { case next, prev }

    /// Rotate the stack array of `n1Based` so a different member
    /// becomes the top. `next` rotates left (current top goes to
    /// the end); `prev` rotates right (last member jumps to top).
    /// Returns the new top, or nil when the WS has fewer than 2
    /// stack members (cycle is a no-op).
    @discardableResult
    mutating func cycleStack(workspace n1Based: Int,
                                    direction: CycleDirection)
        -> WindowID?
    {
        guard var order = stackOrders[n1Based],
              order.count >= 2 else { return nil }
        switch direction {
        case .next:
            order.append(order.removeFirst())
        case .prev:
            order.insert(order.removeLast(), at: 0)
        }
        stackOrders[n1Based] = order
        return order.first
    }

    /// Move `id` to the front (master slot / index 0) of the WS's
    /// shared order. No-op — returns `false` — when the WS has no
    /// maintained order, doesn't contain `id`, or `id` is already the
    /// master. Used by `promoteToMaster` for the master-stack engines.
    @discardableResult
    mutating func promoteToMaster(_ id: WindowID,
                                         workspace n1Based: Int) -> Bool {
        guard var order = stackOrders[n1Based],
              let idx = order.firstIndex(of: id), idx != 0
        else { return false }
        order.remove(at: idx)
        order.insert(id, at: 0)
        stackOrders[n1Based] = order
        return true
    }

    /// Absolute master setter for the section-model apply DnD (PR8 — the
    /// `setMaster` `ApplyOp`). `want` → `promoteToMaster` (id to order[0]).
    /// `!want` (demote) → move `id` off the master slot (order[0] → slot 1)
    /// so the next member becomes master. No-op when the WS has no maintained
    /// order (non-`hasMaster` engine / bsp / float) or `id` isn't the master.
    /// Returns whether the order changed.
    @discardableResult
    mutating func setMaster(_ id: WindowID, _ want: Bool,
                            workspace n1Based: Int) -> Bool {
        if want { return promoteToMaster(id, workspace: n1Based) }
        guard var order = stackOrders[n1Based],
              order.first == id, order.count > 1 else { return false }
        order.removeFirst()
        order.insert(id, at: 1)
        stackOrders[n1Based] = order
        return true
    }

    // MARK: - Leave-focus snapshot (auto-focus on re-entry)

    /// Remember which window was focused on `ws` at leave time.
    /// Called unconditionally on every `switchWorkspace` so the
    /// snapshot is fresh regardless of whether the next entry to
    /// `ws` will auto-focus or not. `id` is whatever
    /// `frontmostFocusedCGID` reported at leave time — even if it
    /// turns out to belong to a different WS (rare race), the
    /// stale entry self-cleans on the next reconcile / drop /
    /// move that touches `id`.
    mutating func recordLeaveFocus(_ id: WindowID, in ws: Int) {
        lastFocusedOnLeave[ws] = id
    }

    /// Drop `id` from every WS's leave-focus snapshot. Called
    /// from `reconcile` / `drop` / `moveWindow` so a closed or
    /// relocated window can't keep pinning auto-focus on a
    /// no-longer-valid target.
    mutating func clearLeaveFocus(of id: WindowID) {
        for (ws, recorded) in lastFocusedOnLeave where recorded == id {
            lastFocusedOnLeave.removeValue(forKey: ws)
        }
    }

    /// Pick the window an auto-focus switch into `ws` should
    /// settle on. `windows` is the live window list of that WS
    /// (caller passes the filtered subset so this method stays
    /// pure on the snapshot). Returns:
    ///   1. `lastFocusedOnLeave[ws]` if still present in `windows`
    ///   2. else `Sequence<Window>.predictedFocus()` — the same
    ///      chain the sidebar's optimistic header highlight uses,
    ///      so the two never drift.
    /// `nil` only when `windows` is empty (= the 2-b empty-WS
    /// branch the caller handles with a defocus instead).
    func autoFocusTarget(in ws: Int, windows: [Window]) -> Window? {
        if let recorded = lastFocusedOnLeave[ws],
           let hit = windows.first(where: { $0.id == recorded }) {
            return hit
        }
        return windows.predictedFocus()
    }

    // MARK: - Floating

    func isFloating(_ id: WindowID) -> Bool {
        floatingWindows.contains(id)
    }

    /// Flip the floating flag on `id` and adjust the tree of the
    /// owning WS (if it's in `"bsp"` mode): a window flipping to
    /// floating is removed from the tree; flipping back inserts
    /// it (auto-balance against the focused leaf).
    ///
    /// `rect` is the active display's `visibleFrame` — only used
    /// for the *orientation choice* when re-inserting; tile
    /// frames are recomputed every time `tiledFrames` runs.
    mutating func toggleFloat(_ id: WindowID,
                                     focused: WindowID? = nil,
                                     in rect: CGRect = .zero) {
        guard let slot = windowMap[id] else { return }
        // Float-exit = sticky-exit (Q13): a sticky window is always
        // floating, so the only thing "toggle float" can mean for it is
        // "stop". Clearing sticky already un-floats + re-homes it as a
        // tiled window of the active WS — the same landing as
        // `--toggle-sticky` off — so defer to that one path.
        if everywhereWindows.contains(id) {
            clearSticky(id, focused: focused, in: rect)
            return
        }
        // Float-exit = scratchpad-exit (Q13), same shape as sticky: a
        // settled scratchpad window is force-floating, so "toggle float"
        // means "let it go" — release drops the shelf entry and re-homes
        // it as a tiled window of the active WS. (A stashed window is
        // off-screen / unfocusable, so it never reaches here.)
        if let name = scratchpad(forWindow: id) {
            releaseScratchpad(name, focused: focused, in: rect)
            return
        }
        let wasFloating = floatingWindows.contains(id)
        if wasFloating {
            floatingWindows.remove(id)
            // Re-enter the WS's layout (no-op if mode is float). orphan: no
            // home workspace layout to re-enter — stays detached (un-floated
            // but in no tree, parked; invisible unless an isolate desktop's `match` shows it).
            if let ws = slot.workspace {
                attachToLayout(id, workspace: ws,
                               focused: focused, in: rect)
            }
        } else {
            floatingWindows.insert(id)
            detachFromLayouts(id)
        }
    }

    /// Absolute, idempotent float setter (focus-free) for the section-model
    /// apply DnD (PR8 — the `setFloating` `ApplyOp`). Defers to `toggleFloat`'s
    /// sticky / scratchpad short-circuits; no auto-center (a declarative apply,
    /// not the user's toggle-float gesture, which centers). Returns whether
    /// state changed.
    @discardableResult
    mutating func setFloating(_ id: WindowID, _ want: Bool,
                              focused: WindowID? = nil, in rect: CGRect = .zero)
        -> Bool
    {
        guard windowMap[id] != nil else { return false }
        // Sticky / scratchpad windows are force-floating: only "stop floating"
        // is meaningful, and `toggleFloat` already routes that to
        // `clearSticky` / `releaseScratchpad`. Asking to float one already
        // (force-)floating is a no-op.
        if everywhereWindows.contains(id) || scratchpad(forWindow: id) != nil {
            guard !want else { return false }
            toggleFloat(id, focused: focused, in: rect)
            return true
        }
        guard isFloating(id) != want else { return false }
        toggleFloat(id, focused: focused, in: rect)
        return true
    }

}
