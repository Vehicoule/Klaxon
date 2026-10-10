# M3E specs — 2d.3 PR D5: side sheet + pull-to-refresh

Sources: the M3 side sheet spec (m2.material.io/components/sheets-side — the M3E
side sheet has no Compose port and no m3.material.io page) + material-components-android
`lib/java/com/google/android/material/sidesheet/` (`SideSheetBehavior.java`, `styles.xml`,
`tokens.xml`, `m3_side_sheet_dialog.xml`) + androidx `pulltorefresh/PullToRefresh.kt`
(`/tmp/m3compose2/d3-pulltorefresh-PullToRefresh.kt`). Framework patterns mirrored:
`src/widgets/drawer.zig` (side-anchored panel + scrim + horizontal slide + RTL) and
`src/widgets/bottom_sheet.zig` (scrim + panel + open signal + back stack).

## Side sheet

| Token (MDA `m3_comp_sheet_side_*`) | Value | Used for |
|---|---|---|
| `docked_standard_container_color` | `colorSurface` | standard panel fill |
| `docked_standard_container_elevation` | level0 | standard (coplanar; flat in v1) |
| (docked standard shape) | CornerNone | standard panel corners (flush to the edge) |
| `docked_modal_container_color` | `colorSurfaceContainerLow` | modal panel fill |
| `docked_modal_container_elevation` | level1 | modal (flat in v1) |
| `docked_modal_container_shape` | CornerLarge (16dp) | modal panel corners |
| `docked_container_width` | 256dp | panel width (modal; the standard width is app-set) |
| (m2 spec) scrim | #000000 @ 32% | modal scrim |
| (m2 spec) standard width | multiples of the top-app-bar height (64dp) | 256/320/384… |

- **Standard side sheet** (`modal = false`): a panel docked to the `side` edge
  (default `end` — the side opposite the nav drawer), full height, width
  `opts.width` (default 256), `Surface` fill, **CornerNone** (flush to the
  edge), coplanar (no scrim). Toggled by the open signal (slide in/out).
- **Modal side sheet** (`modal = true`): a scrim (`scrim` @ 32%) over the body
  + a panel docked to the `side` edge, full height, width
  `min(opts.width, parent)`, `SurfaceContainerLow` fill, **content-side
  corners CornerLarge (16dp), edge-side corners square** (the M3 spec image;
  MDA applies CornerLarge uniformly — v1 follows the spec image, consistent
  with the bottom sheet's content-side-only corners). A scrim click, Escape
  or back closes it (the router's modal back stack while open).
- **Slide**: the panel translates horizontally by `±width × (1 - progress)`
  (closed = off the anchored edge). `side` is LOGICAL: `start`/`end` flip with
  the layout direction (RTL), like the drawer's `hideSign`.
- **Structure** (mirrors the drawer/bottom sheet): the sheet node holds the
  `body` slot (behind), an internal scrim (modal only), and an internal panel
  (a transparent transform node: an internal background child + the `content`
  slot). The open state is a `Signal(bool)` owned by the app; the sheet
  subscribes (slide + scrim animation, the theme's spatial spring; snaps
  without a timeline) and unsubscribes at deinit.
- **Sizing**: the sheet fills FINITE constraints (a sheet is screen-height —
  wrap it in a bounded box inside an unbounded parent, like the bottom sheet).
- **Semantics**: scrim = button "Close sheet" (activate); panel = group with
  the label.
- **v1 deviations / follow-ups**: detached variant (16dp margin, CornerLarge
  all corners), drag-to-dismiss swipe, elevation shadows (Phase 3 raster
  pass), body resize on open (the app's responsive layout), the M3E
  loading-indicator variant of the modal sheet.

## Pull-to-refresh

| Token (Compose `PullToRefreshDefaults` / private vals) | Value | Used for |
|---|---|---|
| `PositionalThreshold` | 80dp | raw pull distance that triggers a refresh |
| `IndicatorMaxDistance` | 80dp | max pull distance |
| `DragMultiplier` | 0.5 | the adjusted (indicator) distance = pull × 0.5 |
| `SpinnerContainerSize` | 40dp | indicator container (a circle) |
| `indicatorContainerColor` | SurfaceContainerHigh | container fill |
| `indicatorColor` | OnSurfaceVariant | arc stroke |
| `SpinnerSize` | 16dp | spinner (arc radius 5.5 + stroke 2.5) |
| `StrokeWidth` | 2.5dp | arc stroke |
| `MaxProgressArc` | 0.8 | max sweep fraction (288°) |
| MinAlpha / MaxAlpha | 0.3 / 1.0 | indicator alpha by progress |
| `Elevation` | level2 | IndicatorBox (flat in v1) |

- **Widget**: a container wrapping ONE content child (typically a
  `scroll_view`). `refreshing` is an app-owned `Signal(bool)` (two-way); the
  PTR sets it on trigger; the app clears it when the refresh completes.
  `on_refresh` fires at the trigger.
- **Gesture** (capture-based, Flutter's overscroll model): a drag DOWN while
  the content is at scroll top pulls: `adjusted = pull × 0.5`, the content
  translates down by `adjusted` (paint/hit-time, like the drawer's panel),
  and the indicator rides the content's top edge (`y = bounds.y + adjusted -
  40`, clipped to the PTR's bounds). "At scroll top" = the content child is
  not a scroll view, or its offset is 0 (a new `scroll_view.isScrollView`
  export identifies it). While the content is scrolled, the scroll view
  scrolls normally and the PTR ignores the drag. The first downward move the
  PTR sees at scroll top anchors the pull origin (the scroll-to-top
  transition is invisible to the wrapper — the scroll view claims the moves
  that scroll) and the PTR steals the pointer capture (a new
  `input.captureNode` router API; the previous owner is canceled with
  `.outside_down`): every later move and the release belong to the PTR, so a
  clickable child cannot strand the indicator, and an upward drag shrinks the
  pull, then scrolls the content. A fresh down cancels any in-flight
  snap-back spring. Residual imprecision (sub-frame): the overscroll within
  the final scroll-consuming move is not counted.
- **Indicator**: a 40dp circle (SurfaceContainerHigh) at the top-center
  holding the M3E arc: a 16dp spinner (radius 5.5, stroke 2.5,
  OnSurfaceVariant) with sweep = `min(1, adjusted / 40) × 0.8 × 360°` and
  alpha = `0.3 + 0.7 × progress`, painted as a round-capped polyline (no arc
  primitive in the paint API — the arc is sampled).
- **Release**: `pull ≥ 80` → `on_refresh` + `refreshing.set(true)`, animate
  `adjusted → 40` (the resting offset: the indicator fully visible at the
  top, content offset 40); below the threshold → animate `adjusted → 0`.
  While refreshing, the indicator holds at rest (progress 1). When the app
  clears `refreshing`, animate `adjusted → 0`.
- **Animation**: the theme's spatial spring on the adjusted value (snaps
  without a timeline) — the same pattern as the drawer/bottom sheet.
- **v1 deviations / follow-ups**: no arrowhead on the arc (needs a
  triangle-fill primitive — v1 paints the arc only), no spin while refreshing
  (a static full arc — the spin lands with the animation phase), no
  nested-scroll coordination beyond the direct scroll-view child, the M3E
  `LoadingIndicator` variant (lands with 2d.4's loading indicator).

## Registry

- `side_sheet` (navigation): `body` + `content` slots, `side` (select),
  `modal` (toggle), `width` (number), `open` = ALWAYS-live bool signal
  (round-trips, like bottom_sheet); skip_children.
- `pull_to_refresh` (input): ONE document child (the content — not a slot);
  `refreshing` = ALWAYS-live bool signal; no skip_children.

## Follow-ups

- Side sheet: detached variant, drag-to-dismiss, shadows, body resize, the
  M3E loading-indicator modal variant.
- PTR: arrowhead, spin animation, nested scrollables, the M3E
  LoadingIndicator variant.
