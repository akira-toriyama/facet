// SidebarView drawing — the loading skeleton plus every row variant
// (top handle, workspace header with layout badge, window row with its
// status pills / mark / tag chips), the grip affordance, and the
// drag-target band. Same-module extension split out of SidebarView.swift
// (P8-2); stored state + layout stay on the primary declaration.
import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension SidebarView {
    // MARK: - Draw

    /// Loading placeholder shown via `facet --view tree --loading`.
    /// Mirrors the real layout's rhythm (caption + two window rows
    /// per section) with muted, theme-aware rounded bars.
    private func drawSkeleton() {
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                 _ alpha: CGFloat, _ radius: CGFloat = 4.5) {
            pal.muted.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                         xRadius: radius, yRadius: radius).fill()
        }
        var y: CGFloat = 6
        let widths: [CGFloat] = [0.60, 0.44, 0.52]
        for s in 0..<3 {
            let hh = s == 0 ? headerFirstRowH : headerRowH
            let capY = s == 0 ? y + 8 : y + 20
            bar(rowPadX, capY, bounds.width * 0.34, 9, 0.80)
            y += hh
            for r in 0..<2 {
                bar(rowPadX + 2, y + (windowRowH - 14) / 2, 14, 14, 0.45, 4)
                let tw = max(bounds.width * widths[(s + r) % widths.count] - 40, 40)
                bar(rowPadX + 24, y + (windowRowH - 9) / 2, tw, 9, 0.45)
                y += windowRowH
            }
            y += 3
        }
    }

    /// A 2-column dot grid — the universal "drag handle" affordance
    /// drawn at the left of every workspace header (header drag =
    /// WS-swap). Height-aware: stretches to an 8-row vertical strip
    /// in a tall rect (the WS header's full 2-line caption) so the
    /// grip reads as a proper anchor for the whole header; falls
    /// back to the compact 3-row form in shorter rects (the top
    /// mac desktop name band). The tree stays at 2×8 (vs the grid's 3×10)
    /// because the sidebar is narrow — a wider strip would crowd the
    /// WS name column.
    private func drawGrip(in r: NSRect, hot: Bool) {
        // The sidebar is narrow, so the tree uses a shorter tall strip
        // (±14 vs the grid / rail's ±18) — see `drawGripDots`.
        drawGripDots(in: r, tallExtent: 14,
                     color: hot ? pal.primary : pal.muted,
                     alpha: hot ? 0.85 : 0.45)
    }

    public override func draw(_ dirty: NSRect) {
        if skeleton { drawSkeleton(); return }
        // Strong drop-target highlight: only a *different* workspace
        // band is a valid drop target — fill + outline it so "drop
        // here" is unmistakable. Source is a mouse window-drag
        // (`draggingWid`), a mouse header-swap (`draggingWS`), or a
        // keyboard lift (`kbLifted`). For a swap the source band is
        // also dashed-outlined so the trade reads as "these two".
        if let ctx = dragContext() {
            if let tgt = ctx.target, tgt != ctx.source,
               let band = wsBands[tgt] {
                let r = NSRect(x: 1, y: band.lowerBound,
                               width: bounds.width - 2,
                               height: band.upperBound - band.lowerBound)
                pal.primary.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                pal.primary.setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 2
                o.stroke()
            }
            if ctx.isSwap, let band = wsBands[ctx.source] {
                let r = NSRect(x: 1, y: band.lowerBound,
                               width: bounds.width - 2,
                               height: band.upperBound - band.lowerBound)
                    .insetBy(dx: 1, dy: 1)
                pal.primary.withAlphaComponent(0.7).setStroke()
                let o = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5
                o.setLineDash([4, 3], count: 2, phase: 0)
                o.stroke()
            }
        }
        // Section reorder (mode 4): a thin insertion LINE with end caps at the
        // drop boundary (dnd-kit style) — "the dragged section lands here".
        if let ly = reorderLineY {
            pal.primary.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rowPadX, y: ly))
            line.line(to: NSPoint(x: bounds.width - rowPadX, y: ly))
            line.lineWidth = 2.5
            line.stroke()
            pal.primary.setFill()
            for ex in [rowPadX, bounds.width - rowPadX] {
                NSBezierPath(ovalIn: NSRect(x: ex - 3, y: ly - 3,
                                            width: 6, height: 6)).fill()
            }
        }
        let para = NSMutableParagraphStyle()
        // No tail-truncation (no "…"): rows are laid out at the natural
        // content width (see update's pre-pass) and the panel scrolls
        // horizontally to read overflow (B). Clip rather than ellipsize so
        // a sub-pixel measurement gap never reintroduces "…".
        para.lineBreakMode = .byClipping

        let kbSelRow = kbNav ? kbSel.flatMap(kbIndex(of:)) : nil
        var winOrdinal = 0   // window-row counter for the zebra stripe
        for (i, c) in cells.enumerated() {
            let row = c.row
            switch c.kind {
            case 1:   // workspace section header — 2-line caption
                if !c.firstHeader {
                    pal.border.setStroke()
                    let sep = NSBezierPath()
                    let sy = row.minY + 9           // tighter gap above
                    sep.move(to: NSPoint(x: rowPadX, y: sy))
                    sep.line(to: NSPoint(x: bounds.width - rowPadX, y: sy))
                    sep.lineWidth = 1
                    sep.stroke()
                }
                let hp = NSMutableParagraphStyle()
                hp.lineBreakMode = .byClipping     // no "…" — see `para` (B)
                hp.maximumLineHeight = row.height
                // Header size is the CONSTANT `headerFontSize` in both
                // states — active vs inactive is colour (below) + a one-
                // notch weight bump, never a size change (that flip was the
                // old reflow / "scattered" feel). The WS name stays bold so
                // the section header reads heavier than the body rows.
                let nameWeight: NSFont.Weight = c.hot ? .bold : .semibold
                let capY = c.firstHeader ? row.minY + 6 : row.minY + 18
                let capH = row.maxY - capY - 6
                // Drag grip — affords "grab to swap this workspace".
                // Spans the full caption area so it visually anchors both
                // lines (WS name + layout-mode chip) as one unit.
                let gripSpace = headerGripW + 6
                drawGrip(in: NSRect(x: rowPadX, y: capY,
                                    width: headerGripW, height: capH),
                         hot: c.hot || hoverIdx == i)
                // Line 1: WS name / lens label (accent when active). Line 2
                // (layout) is `primary` too, so the two lines never collide on
                // the same accent.
                let nameH: CGFloat = 18
                let nameColor = c.hot ? pal.primary : pal.muted
                let nameX0 = rowPadX + gripSpace
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: uiFont(headerFontSize, nameWeight),
                    .foregroundColor: nameColor,
                    .kern: 0.6, .paragraphStyle: hp]
                // Kind prefix (トミー 2026-06-19): spell the section KIND out on
                // the header so it reads at a glance, not just from the glyph.
                // The three words all answer ONE question — "what IS this
                // section" — since t-mqqw retired `lens ·` (a DESKTOP type
                // leaking onto a section) and split the isolate desktop's
                // holding bucket out of `unassigned ·` (which was a lie: those
                // windows ARE assigned, they just failed the `match`), and
                // t-6rbc retired `unassigned ·` itself with the orphan concept.
                //
                // A glyph fronts every non-workspace kind, each distinct so the
                // chrome stops asserting a kinship the model does not have.
                // Workspace headers carry no glyph (they own the layout
                // sub-line instead). `c.text` is `sectionDisplayLabel`, which
                // never returns empty ("N" or "N (label)") — so there is no
                // bare-kind fallback to write; the two that used to sit here
                // were dead code (t-mqqw).
                let kindWord: String
                let kindGlyph: String?
                switch c.sectionType {
                case .workspace:  kindWord = "workspace";  kindGlyph = nil
                case .matched:    kindWord = "matched"
                                  kindGlyph = "SF:line.3.horizontal.decrease.circle"
                case .holding:    kindWord = "holding";    kindGlyph = "SF:tray"
                }
                var lx = nameX0
                if let slug = kindGlyph,
                   let icon = IconResolver.resolve(slug, pointSize: 13,
                                                   color: nameColor, scale: .medium) {
                    let ih = min(icon.size.height, 14)
                    let iw = icon.size.width * (ih / max(icon.size.height, 1))
                    icon.draw(in: NSRect(x: lx, y: capY + (nameH - ih) / 2,
                                         width: iw, height: ih))
                    lx += iw + 5
                }
                ((kindWord + " · " + c.text) as NSString).draw(
                    in: NSRect(x: lx, y: capY,
                               width: bounds.width - rowPadX - lx,
                               height: nameH),
                    withAttributes: nameAttrs)
                // Line 2: layout-mode text — the caption's "mini header".
                // `primary` on the active WS (item 10: layout = primary
                // accent), `pal.muted` when inactive so non-focused rows
                // recede. No pill background — the colour + weight step
                // alone separates it from body text.
                if !c.mode.isEmpty {
                    // Layout mode: a leading SF icon (item 7 — the tree is
                    // text-heavy, so the glyph lets the layout register at a
                    // glance) + the abbreviated label. One SIZE step and one
                    // WEIGHT step below the WS name above it (subhead 12 vs
                    // name 13; .semibold/.medium vs .bold/.semibold) so the
                    // two-line caption has real internal hierarchy — name
                    // dominant, layout subordinate — instead of two equal
                    // lines.
                    let modeColor = c.hot ? pal.primary : pal.muted
                    let modeWeight: NSFont.Weight = c.hot ? .semibold : .medium
                    let mx = rowPadX + gripSpace
                    let modeY = capY + nameH + 4
                    var modeTextX = mx
                    let modeIconSpec = layoutModeIcon(c.mode)
                    // Explicit ~14pt glyph (not the menu's `.large`): the
                    // header line is only 18pt tall, so the icon is sized to
                    // sit centred with ≥2pt clearance from the kbNav outline
                    // and the line above (fixes the reported icon↔border
                    // overlap). Height-clamped so a stray large render can't
                    // bleed past the line.
                    if !modeIconSpec.isEmpty,
                       let icon = IconResolver.resolve(
                        modeIconSpec, pointSize: 13, color: modeColor,
                        scale: .medium) {
                        let ih = min(icon.size.height, 14)
                        let iw = icon.size.width * (ih / max(icon.size.height, 1))
                        icon.draw(in: NSRect(
                            x: mx, y: modeY + (18 - ih) / 2,
                            width: iw, height: ih))
                        modeTextX = mx + iw + 5
                    }
                    (layoutBadgeLabel(c.mode) as NSString).draw(
                        in: NSRect(x: modeTextX, y: modeY,
                                   width: bounds.width - rowPadX - modeTextX,
                                   height: 18),
                        withAttributes: [
                            .font: uiFont(subheadFontSize, modeWeight),
                            .foregroundColor: modeColor,
                            .paragraphStyle: hp,
                        ])
                }

            default:  // window row
                let sel = c.hot
                let hov = (hoverIdx == i)
                let pill = row.insetBy(dx: 6, dy: 2)
                // Zebra stripe: nudge every other window row toward the
                // text color — slightly lighter on dark themes, darker
                // on light ones (theme-independent). A faint base layer
                // under any selection / hover fill.
                if winOrdinal % 2 == 1 {
                    pal.foreground.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                }
                winOrdinal += 1
                if sel {
                    pal.selection.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                    pal.primary.setFill()
                    NSBezierPath(roundedRect: NSRect(
                        x: pill.minX, y: pill.minY + 3,
                        width: 3, height: pill.height - 6),
                        xRadius: 1.5, yRadius: 1.5).fill()
                } else if hov {
                    pal.hover.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                }
                let iconX = rowPadX + 2
                // Sticky renders as its own "sticky" badge in the block
                // below, so suppress the plain `float` label here
                // (sticky ⇒ floating; a master window can't be sticky).
                // A settled scratchpad window is force-floating, but it
                // shows its own `scratchpad:NAME` badge below instead of
                // the plain `float` label (like the sticky pill).
                let labelText: String? =
                    c.isMaster ? "master" :
                    c.isSticky ? nil :
                    c.scratchpad != nil ? nil :
                    c.isFloating ? "float" : nil
                let hasLabel = labelText != nil
                let hasTitle = !c.title.isEmpty
                let hasMark = c.mark != nil
                let hasScratch = c.scratchpad != nil
                let hasTags = !c.tags.isEmpty
                let tx = iconX + iconSize + 8
                let tw = max(bounds.width - tx - rowPadX, 0)
                // Vertical rhythm (matches the row-height calc): top pad
                // 8, app, +4 gap, title, +6 gap, third (mark / status)
                // line. App centres only on a bare single-line row.
                let appY = (hasTitle || hasLabel || hasMark
                            || c.isSticky || hasScratch || hasTags)
                    ? row.minY + 8 : row.midY - 9
                let titleY = row.minY + 28        // tucked up under the app
                // Icon centres on the whole row so it stays vertically
                // centred even when a third line (mark / master / float)
                // grows the row — without it the icon rides up to the
                // identity block and reads as top-aligned.
                let iconY = (row.midY - iconSize / 2).rounded()
                if let img = AppIcons.icon(forPID: c.pid) {
                    img.draw(in: NSRect(x: iconX, y: iconY,
                                        width: iconSize, height: iconSize))
                }
                (c.app as NSString).draw(
                    in: NSRect(x: tx, y: appY, width: tw, height: 18),
                    withAttributes: [
                        // Body text: `.regular` unselected so it reads as
                        // plain content, not a header; selection bumps to
                        // `.semibold` + primary (colour carries focus, no
                        // size change).
                        .font: uiFont(windowFontSize,
                                      sel ? .semibold : .regular),
                        // Dim a hidden (Cmd+H/Cmd+M'd) row, but keep a selected
                        // row at full strength so the highlight stays legible.
                        // (Isolate-parked rows show at full strength — t-c6fm:
                        // the tree is an inventory, not a screen mirror.)
                        .foregroundColor: (sel ? pal.primary : pal.foreground)
                            .withAlphaComponent(
                                c.isHidden && !sel ? 0.45 : 1.0),
                        .paragraphStyle: para,
                    ])
                if hasTitle {
                    // Window title: the row's supporting detail — one size
                    // below the app name, `.regular`, and dimmed to `muted`
                    // so it reads as secondary (was .semibold/foreground,
                    // which made the title out-weigh its own app name).
                    (c.title as NSString).draw(
                        in: NSRect(x: tx, y: titleY,
                                   width: tw, height: 15),
                        withAttributes: [
                            .font: uiFont(windowTitleFontSize, .regular),
                            .foregroundColor: pal.muted.withAlphaComponent(
                                c.isHidden && !sel ? 0.45 : 1.0),
                            .paragraphStyle: para,
                        ])
                }
                // Third line: the mark pill (left), then the "sticky"
                // badge or the `scratchpad:NAME` shelf pill, then the
                // master / float / hidden label.
                if hasLabel || hasMark || c.isSticky || c.isHidden
                    || hasScratch || hasTags {
                    // Wider gap below the title before the mark / status.
                    let labelY = hasTitle ? row.minY + 51 : row.minY + 32
                    var lx = tx
                    if let mark = c.mark {
                        // Badges share the body size (12pt) but stay .medium +
                        // accent-coloured so they read as metadata, not body —
                        // colour carries the meaning. The mark keeps its
                        // primary stroke + rounded outline.
                        let markFont = uiFont(badgeFontSize, .medium)
                        let maxTextW: CGFloat = 60   // long → tail-truncate
                        let textW = min(maxTextW, ceil((mark as NSString)
                            .size(withAttributes: [.font: markFont]).width))
                        let padX: CGFloat = 8
                        let pillH: CGFloat = 22   // inner padding around text
                        let pillW = textW + padX * 2
                        let pillRect = NSRect(x: lx, y: labelY - 1,
                                              width: pillW, height: pillH)
                        let markStroke = NSBezierPath(
                            roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: 5, yRadius: 5)   // rounded rect, not capsule
                        markStroke.lineWidth = 1
                        // Mark = primary accent (green) so the user's own
                        // handle stands apart from the secondary master /
                        // float badge.
                        pal.primary.setStroke()
                        markStroke.stroke()
                        let pillPara = NSMutableParagraphStyle()
                        pillPara.alignment = .center
                        pillPara.lineBreakMode = .byTruncatingTail
                        let pillAttrs: [NSAttributedString.Key: Any] = [
                            .font: markFont,
                            .foregroundColor: pal.primary,
                            .paragraphStyle: pillPara,
                        ]
                        let textH = (mark as NSString).size(
                            withAttributes: pillAttrs).height
                        (mark as NSString).draw(
                            in: NSRect(x: lx,
                                       y: labelY - 1 + (pillH - textH) / 2 - 1.0,
                                       width: pillW, height: textH),
                            withAttributes: pillAttrs)
                        lx += pillW + 6
                    }
                    // Tags (#tag): EVERY tag this window carries (the tag-mode
                    // list is flat — there is no primary-tag header to hide
                    // one under). A `tag` glyph (replacing the old `#`) + the
                    // name in `secondary`, NO filled chip background (it read
                    // as an unwanted highlight); the glyph + accent colour
                    // already distinguish it from a mark / scratchpad. Stops
                    // before a tag would overrun the row's right edge.
                    let pillH: CGFloat = 22
                    for tag in c.tags {
                        // Same badge tier as master/float/sticky (12pt
                        // .medium) so tags read uniformly with the other
                        // metadata; glyph tracks the text (14pt).
                        let chipFont = uiFont(badgeFontSize, .medium)
                        let maxTextW: CGFloat = 90
                        let textW = min(maxTextW, ceil((tag as NSString)
                            .size(withAttributes: [.font: chipFont]).width))
                        let tagIcon = IconResolver.resolve(
                            "SF:tag", pointSize: 14,
                            color: pal.secondary, scale: .medium)
                        let icH = tagIcon.map { min($0.size.height, 15) } ?? 0
                        let icW = tagIcon.map {
                            $0.size.width * (icH / max($0.size.height, 1)) } ?? 0
                        let icGap: CGFloat = tagIcon == nil ? 0 : 3
                        let pillW = icW + icGap + textW
                        if lx + pillW > tx + tw { break }   // no room → stop
                        var cx = lx
                        if let tagIcon {
                            tagIcon.draw(in: NSRect(
                                x: cx, y: labelY - 1 + (pillH - icH) / 2,
                                width: icW, height: icH))
                            cx += icW + icGap
                        }
                        let chipPara = NSMutableParagraphStyle()
                        chipPara.lineBreakMode = .byTruncatingTail
                        let chipAttrs: [NSAttributedString.Key: Any] = [
                            .font: chipFont,
                            .foregroundColor: pal.secondary,
                            .paragraphStyle: chipPara,
                        ]
                        let chipH = (tag as NSString)
                            .size(withAttributes: chipAttrs).height
                        (tag as NSString).draw(
                            in: NSRect(x: cx,
                                       y: labelY - 1 + (pillH - chipH) / 2 - 1.0,
                                       width: textW, height: chipH),
                            withAttributes: chipAttrs)
                        lx += pillW + 6
                    }
                    if c.isSticky {
                        // Sticky: `pin` + horizontal text (no slant now — it
                        // aligns with the other badges; the pin glyph already
                        // sets it apart from float).
                        lx = drawStatusPill("sticky", icon: "SF:pin",
                                            color: pal.foreground,
                                            at: lx, labelY: labelY)
                    }
                    if let sp = c.scratchpad {
                        // Scratchpad shelf: `tray` + `scratchpad:NAME`, on the
                        // least-emphasis `tertiary` tier (it's a parked-away
                        // state) so it reads as the dimmest metadata; labelled
                        // in full so it can't be mistaken for a mark.
                        lx = drawStatusPill("scratchpad:\(sp)", icon: "SF:tray",
                                            color: pal.tertiary,
                                            at: lx, labelY: labelY)
                    }
                    if let labelText {
                        // master / float — icon + text, no border. master →
                        // `crown` + `primary`; float → `macwindow` +
                        // `foreground` (matches the "Desktop N" band label).
                        lx = drawStatusPill(
                            labelText,
                            icon: c.isMaster ? "SF:crown" : "SF:macwindow",
                            color: c.isMaster ? pal.primary : pal.foreground,
                            at: lx, labelY: labelY)
                    }
                    if c.isHidden {
                        // Hidden (Cmd+H / minimized): `eye.slash` + dim text —
                        // confirming the dimmed row is hidden, not gone. Click
                        // restores it. (Never master/float/sticky, so it's the
                        // only badge on its row.)
                        lx = drawStatusPill("hidden", icon: "SF:eye.slash",
                                            color: pal.muted,
                                            at: lx, labelY: labelY)
                    }
                }
            }

            // Keyboard cursor: an accent outline distinct from the
            // selected-window pill (fill) and hover (faint fill).
            if let kbSelRow, kbSelRow == i {
                let r = (c.kind == 2 ? row.insetBy(dx: 6, dy: 2)
                                     : row.insetBy(dx: 6, dy: 4))
                pal.primary.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                                     xRadius: 7, yRadius: 7)
                p.lineWidth = 2
                p.stroke()
            }
        }

        // DnD: dim the lifted/dragged source window row (mouse drag
        // or kb lift). The follow-pointer chip is a separate
        // layer-backed subview (repositioned, never redrawn) so it
        // keeps up with fast cursor motion. Header-swap dims nothing
        // here — its source WS is dashed-outlined above instead.
        let liftedWinID: WindowID? = draggingWid?.windowID ?? {
            if case .win(_, let id)? = kbLifted { return id }
            return nil
        }()
        // The SOURCE group ordinal of the lift (mouse: stored in draggingWid's
        // workspaceIndex — group ordinal in section mode, ws.index in degrade;
        // kb: carried by kbLifted). Dims the lifted ROW, so the dim follows the
        // section the lift started in.
        let liftedGroup: Int? = draggingWid?.workspaceIndex ?? {
            if case .win(let g, _)? = kbLifted { return g }
            return nil
        }()
        if let liftedWinID {
            for row in rows {
                if case .window(let g, _, _, let id, _) = row.kind,
                   id == liftedWinID, liftedGroup == g {
                    (pal.background ?? .windowBackgroundColor)
                        .withAlphaComponent(0.55).setFill()
                    NSBezierPath(roundedRect: row.rect.insetBy(dx: 4, dy: 1),
                                 xRadius: 5, yRadius: 5).fill()
                }
            }
        }

    }

    /// Draw a window-state badge — an optional leading SF icon then text — at
    /// `lx` on a window row's third line, returning the advanced x. Borderless
    /// + horizontal (no pill outline, no slant): the glyph + `color` carry the
    /// meaning, matching the tag chips' clean icon+text look. Shared by the
    /// master / float / sticky / hidden / scratchpad badges.
    private func drawStatusPill(_ text: String, icon: String, color: NSColor,
                                maxTextW: CGFloat = 130,
                                at lx: CGFloat, labelY: CGFloat) -> CGFloat {
        // Badge tier: 12pt .medium (body size, lighter weight + accent) —
        // colour carries the meaning. Glyph tracks the text (14pt).
        let font = uiFont(badgeFontSize, .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para]
        let textW = min(maxTextW, ceil((text as NSString)
            .size(withAttributes: [.font: font]).width))
        let pillH: CGFloat = 22
        let iconImg = icon.isEmpty ? nil
            : IconResolver.resolve(icon, pointSize: 14,
                                   color: color, scale: .medium)
        let iconH = iconImg.map { min($0.size.height, 15) } ?? 0
        let iconW = iconImg.map { $0.size.width * (iconH / max($0.size.height, 1)) } ?? 0
        let iconGap: CGFloat = iconImg == nil ? 0 : 4
        var cx = lx
        if let iconImg {
            iconImg.draw(in: NSRect(
                x: cx, y: labelY - 1 + (pillH - iconH) / 2,
                width: iconW, height: iconH))
            cx += iconW + iconGap
        }
        let textH = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(
            in: NSRect(x: cx, y: labelY - 1 + (pillH - textH) / 2 - 1.0,
                       width: textW, height: textH),
            withAttributes: attrs)
        return cx + textW + 10   // past the text + a gap to the next badge
    }

    /// Unified drag/lift context for `draw`: the source workspace,
    /// the current drop target (if any), and whether the gesture is a
    /// header swap (vs a window move).
    private func dragContext() -> (source: Int, target: Int?, isSwap: Bool)? {
        if let d = draggingWid { return (d.workspaceIndex, dropWS, false) }
        if let s = draggingWS { return (s, dropWS, true) }
        switch kbLifted {
        // Use the group ordinal stored in the lift (in the degrade path,
        // where keyboard lift is the only place this is set, group ==
        // ws.index == a valid `wsBands` key) rather than re-looking it up by
        // id — matching the `.hdr` case and avoiding a nil-WS fallback.
        case .win(let g, _): return (g, kbDropWS, false)
        case .hdr(let g):    return (g, kbDropWS, true)
        case .none:          return nil
        }
    }

}
