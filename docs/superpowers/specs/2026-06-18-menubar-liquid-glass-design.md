# Menu bar dropdown — Liquid Glass redesign

## Goal

Restyle the `MenuBarView` dropdown so it feels native to macOS's Liquid Glass design language. Behaviour is unchanged; this is a pure visual pass.

## Problem

Today's dropdown uses flat sections divided by 0.5pt hairline rules. The system MenuBarExtra window provides a rounded, blurred outer chrome, but the content has no top/bottom padding to harmonize with it — so the system's rounded corner and the inner content collide and the top/bottom gap looks unintentional.

## Constraints

- Deployment target is macOS 13. The real `.glassEffect()` / `GlassEffectContainer` APIs are macOS 26+ and unavailable here. We emulate the look using `Material` + continuous rounded rects + edge highlights.
- Single file in scope: [Sources/WaikApp/MenuBarView.swift](../../Sources/WaikApp/MenuBarView.swift).
- All current functionality, bindings, and keyboard shortcuts are preserved.

## Layout

The dropdown becomes a stack of floating "glass cards" on the system blurred backdrop, with intentional outer padding that frames the cards instead of letting them touch the window edge.

Stack order, top to bottom:

1. **Status header card** — `StatusDot` + status text + (when engaged) tool subtitle. When keep-awake is engaged, the card uses an accent-tinted material for a "live" feel. Full width.
2. **Daemon warning card** (conditional) — only when `coordinator.daemonStatusText` is set. Same card treatment, orange-tinted edge.
3. **Controls card** — four toggle rows (Force keep awake, Pause monitoring, Launch at login, Sleep on low battery) plus the battery threshold sub-row when enabled. Toggle rows have no individual backgrounds inside the card; hover state is a translucent capsule fill, not a rectangle.
4. **Agent hooks card** — collapsed: single row with count badge and chevron. Expanded: per-tool rows inside the same card.
5. **Footer card** — "Check for updates…" row + "Quit waik" row in one card. Both keep their full-width labels (Apple's preference for explicit menubar labels). No hairline between them — separation is by row hover state alone.

## Geometry & spacing

| Property | Value |
|---|---|
| Frame width | 320pt (unchanged) |
| Outer container padding | 10pt all sides |
| Card corner radius | 14pt, continuous |
| Card inner padding | 12pt horizontal, 10pt vertical |
| Gap between cards | 8pt |
| Row height (toggle/action) | min 32pt |
| Hover capsule corner radius | 8pt continuous |

## Glass card recipe

A reusable `GlassCard` container view:

- Background: `.regularMaterial` clipped to a 14pt continuous `RoundedRectangle`.
- Edge highlight: 1pt stroke with a top-to-bottom linear gradient (`Color.white.opacity(0.18)` → `Color.white.opacity(0.04)`), inset by 0.5pt so it sits just inside the corner.
- Drop shadow: `radius: 8, y: 2, color: .black.opacity(0.08)`.
- Optional `tint: Color?` parameter — when set, overlays the tint at 0.10 opacity on top of the material to colour the card (engaged → accent; daemon warning → orange).

## Row treatments

- **`HoverRowStyle`** changes from a `RoundedRectangle(cornerRadius: 6)` fill to a capsule fill with `Color.primary.opacity(0.06)` on hover and `0.10` when pressed. Inset 4pt from card edges so the hover highlight visually nests inside the card.
- **`ToggleRow`**: icon → label → trailing `Toggle` with `.switch` style at `.mini`. Icon tint colour stays as today (per-toggle: orange, secondary, accent, green).
- **Agent hook rows**: no change in content. The chevron and count-badge keep their current treatment; the badge gets `.regularMaterial` backing instead of `.quaternary` to read as a small chip.
- **Status badges** (installed / not installed / partial / n/a): keep capsule shape and tint, but back with `.regularMaterial.opacity(0.6)` so they read consistently with the card aesthetic.

## Typography

| Element | Style |
|---|---|
| Status headline | `.system(.headline, design: .rounded)` (unchanged) |
| Row label | `.body` |
| Secondary text / subtitle | `.caption`, `.secondary` |
| Status badge | `.caption2.weight(.medium)` |
| Count badge | `.caption.monospacedDigit()` |
| Keyboard hint (⌘Q) | `.caption.monospacedDigit()`, `.tertiary` |

## Behaviour preserved

- All bindings (`forceAwakeBinding`, `pauseBinding`, `launchAtLogin`, `batteryGuardEnabled`, `batteryGuardThreshold`) unchanged.
- Agent hooks expand/collapse animation unchanged (`easeInOut(0.18)`).
- Battery threshold row's opacity transition unchanged.
- "Check for updates…" disabled state unchanged.
- ⌘Q keyboard shortcut unchanged.
- `StatusDot` pulsing animation unchanged.

## Out of scope

- The menu bar icon itself (`MenuBarIconImage`) — no change.
- Onboarding view — no change.
- Bumping the macOS deployment target. If we ever bump to macOS 26+, `GlassCard` can be replaced with `.glassEffect()` in one place.

## Acceptance

- The dropdown opens with visible breathing room on all four sides — no edge collision with the system window corner.
- No hairline separators are visible anywhere in the dropdown.
- Each section reads as a distinct floating card; controls within a card feel grouped.
- Hovering a row produces a soft, capsule-shaped highlight (not a rectangle).
- When keep-awake is engaged, the status card visibly tints toward the accent colour.
- All toggles, expansions, install/uninstall actions, update check, and quit shortcut behave exactly as before.
