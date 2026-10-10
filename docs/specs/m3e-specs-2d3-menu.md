# M3E specs — 2d.3 PR D2: dropdown menu

Sources: `m3.material.io/components/menus` + Compose `compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Menu.kt`, `MenuDefaults.kt`, `tokens/MenuTokens.kt` (androidx-main; fetched into `/tmp/m3compose2/d3-Menu.kt`, `d3-MenuDefaults.kt`, `tokens/MenuTokens.kt`).

## Tokens implemented (v1)

| Token | Value | Used for |
|---|---|---|
| `MenuListItemContainerHeight` | 48dp | item row height |
| `DropdownMenuItemHorizontalPadding` | 12dp | item row horizontal padding |
| `LeadingContentEndPadding` | 16dp | leading icon → label gap |
| `DropdownMenuVerticalPadding` | 8dp | panel vertical padding (inside the panel) |
| `MenuContainerColor` | `SurfaceContainer` | panel fill (flat in v1 — Level2 is Phase 3) |
| `MenuItemLabelTextColor` | `OnSurface` | item label (body_large) |
| `MenuListItemLeadingIconColor` | `OnSecondaryContainer` | leading icon (the menu quirk) |
| `MenuItemTrailingTextColor` | `OnSurfaceVariant` | trailing text (label_small) |
| state layer | `on_surface` @ hover 0.08 / focus 0.10 / pressed 0.12 | over the panel per row |
| disabled | `OnSurface` @ 0.38 | label / icon / trailing text |
| `MenuCornerRadius` (shape) | 4dp (`CornerExtraSmall`) | panel corners |

## Layout

- The **anchor** is a document child; it sizes the menu and keeps its own interaction (the app opens the menu via the signal or `setOpen`).
- The **panel** opens below the anchor, start-aligned (end-aligned in RTL), intrinsic width = the widest item (icon + label + trailing text + paddings), clamped to the parent width.
- Item rows stack vertically, 48dp each; the panel height = `8 + items*48 + 8`.
- Leading icon: 24dp box at x = row.x + 12. Label at x = row.x + 12 (+ 24 + 16 when an icon is present). Trailing text: right-aligned at row.x + row.w - 12 (8dp gap before the end padding).

## Interaction

- Open state is **signal-driven** (round-trips through serialization); `setOpen(n, bool)` is the pub API (with a signal it sets the signal; without one it applies directly). `applyOpen` is the single transition path.
- Item rows are internal chrome (`visible = false` until open, `internal = true`, `exclude_semantics`); the damage region covers the anchor AND the item rows (the panel paints outside the menu's bounds).
- The router's **open-popup barrier** closes the menu on outside clicks (`outside_down`).
- On open the menu takes the **keyboard focus** and restores the previous focus on close. Keys while open: up/down move the highlight (skipping disabled items, wrapping), Enter selects, Escape closes.
- Item click: down records the pressed row, up inside the row's bounds selects it → `selected` index set, semantics value synced (+ `notifyControlChanged`), menu closed, `on_select` fires.
- Hover/press state layers per row (pressed > focus-when-focused > hover).

## Semantics

- role `menu`, focusable, `value` = the last selected item's label.

## Registry

- `menu` (category `display`): the **anchor** is a factory slot (a subtree document, like badged_box's `content`); `items` is an option array parsed manually (`[{label, leading_icon?, trailing_text?, enabled?}]` — `optionsFromValue` cannot map `[]MenuItem`); a non-null `open` drives a ctx-owned bool signal (live round-trip); `skip_children`.
- The anchor child is marked `internal` (slot-owned, not document-children data — protects against double serialization; no effect on hit-testing/paint/semantics).
- Schema: `anchor` (slot), `items` (unsupported for now), `open` (toggle).

## v1 deviations (documented, fixed later)

- Flat panel (no Level2 shadow — Phase 3); no submenus, no checkable items, no group labels/dividers; no scroll for long menus; no M3E shape morph.
- RTL mirrors the panel and the item rows; the text runs stay LTR (no bidi, same as `text.zig`).

## Follow-ups (2d.3 PR D3+)

- Segmented button + split button (D3), search bar + navigation rail (D4), side sheets + pull-to-refresh (D5).
- Menu: submenus, checkable items, group labels/dividers, scroll for long menus, Level2 shadow, M3E shape morph (Phase 3).
