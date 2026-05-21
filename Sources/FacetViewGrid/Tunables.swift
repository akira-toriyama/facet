// Layout / animation constants for the overview grid. Same values
// as ws-tabs v1.6 — tuned to match the TS3 screenshots the user
// supplied: solid near-black backdrop, thin cell strokes, one
// compact label per cell, no extra index badge.

import CoreGraphics
import Foundation

let gridOuterPad: CGFloat = 48          // overlay edge → outermost cell row
let gridCellGap: CGFloat = 24           // gap between cell rows / cols
let gridCellCornerRadius: CGFloat = 10  // rounded cell shape
let gridLabelGap: CGFloat = 4           // breathing room: label → cell

let gridBackdropAlpha: CGFloat = 0.98   // overlay opacity (TS3 ≈ pure black)
let gridFadeIn: TimeInterval = 0.12     // overlay fade-in
let gridFadeOut: TimeInterval = 0.10    // overlay fade-out

// dnd-kit-style "lift" feedback when a drag starts: ghost grows
// slightly + soft shadow drops in so the user *feels* the thumb
// being picked up. Cursor-follow path is paused for the duration so
// the animation isn't yanked mid-frame.
let gridLiftScale: CGFloat = 1.06
let gridLiftDuration: TimeInterval = 0.14
let gridLiftShadowRadius: CGFloat = 14
let gridLiftShadowOpacity: Float = 0.45

// dnd-kit-style "animated reorder" after a successful drop: every
// window thumb whose rect changed slides from its old rect to its
// new rect over this duration with an ease-out curve (FLIP).
let gridReorderDuration: TimeInterval = 0.15

// Pointer distance (px) before a mouseDown becomes a drag. Same
// value as FacetViewTree's tunable — kept module-local in both
// places to avoid a cross-module import for one constant.
let dragThreshold: CGFloat = 5
