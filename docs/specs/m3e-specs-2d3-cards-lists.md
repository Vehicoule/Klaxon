# M3E Cards + ListItem v1 spec (2d.3 PR D1) — consolidated from Compose androidx-main

Sources: `Card.kt`, `tokens/{Elevated,Filled,Outlined}CardTokens.kt`,
`ListItem.kt`, `ListItemDefaults.kt`, `tokens/ListTokens.kt` (in /tmp/m3compose2,
prefixed `d3-`).

## Cards (filled / elevated / outlined)
- Shape: CornerMedium = 12dp all corners (all 3 variants).
- Containers: filled = SurfaceContainerHighest (Level0, hover L1, dragged L3);
  elevated = SurfaceContainerLow (Level1, hover L2, dragged L4); outlined =
  Surface + OutlineVariant 1dp stroke (hover/pressed OutlineVariant, focus
  outline OnSurface, dragged OutlineVariant).
- Disabled: filled = SurfaceVariant@0.38; elevated = Surface@0.38; outlined =
  Surface + OnSurface@0.12 stroke.
- Content color: OnSurface. Clickable card: state layer = on_surface @
  hover 0.08 / pressed 0.12 over the container (theme_mod.stateLayer).
- Layout: a Surface wrapping a Column — NO intrinsic padding (apps add their
  own); the widget exposes a `padding` option (default 16) + `gap` (default 0);
  children stretch to the inner width (column cross_align stretch).
- Elevation: FLAT in v1 (no shadows — Phase 3), documented.
- Semantics: clickable → role .button + activate; else role .group.

## ListItem (one / two / three lines)
- Heights: one-line 56, two-line 72, three-line 88 (min heights; content
  vertically centered). Vertical padding 8 (12 for three-line — effective,
  the content is centered in the min height).
- Horizontal: start/end padding 16; leading icon 24dp at x=16, gap to the
  text 16 (LeadingContentEndPadding); trailing icon 24dp / trailing text
  (LabelSmall) at the end, 16 from the edge (ItemTrailingSpace),
  TrailingContentStartPadding 16.
- Text column (stacked, no extra gaps — the line heights carry the spacing):
  overline (LabelSmall, OnSurfaceVariant), headline (BodyLarge, OnSurface),
  supporting (BodyMedium, OnSurfaceVariant).
- Icons: OnSurfaceVariant 24dp. Trailing text: LabelSmall OnSurfaceVariant.
- Container: Surface (Level0); selected → SecondaryContainer (content colors
  → OnSecondaryContainer: label, supporting, overline, leading/trailing
  icons). Disabled: content @0.38 (container unchanged; selected+disabled →
  OnSurface@0.38 container).
- State layer (clickable): on_surface @ hover 0.08 / pressed 0.12 over the
  container; disabled state layer @0.1.
- Shape: CornerNone classic (v1 flat — the M3E hover/press morph to
  CornerLarge lands with Phase 3 motion), documented.
- Semantics: role .list_item, label = headline, focusable when clickable,
  checked = selected (synced), disabled.
- Selected is EXTERNAL state (a sig, read-only visual — the click fires
  on_click, it does not flip). Registry: "selected" option → live binding.

## v1 deviations (documented, fixed later)
- Cards: no elevation shadows (Phase 3); no intrinsic padding in the spec
  (the widget's `padding` option is the content inset).
- ListItem: no M3E shape morph (CornerNone flat); no avatar/image/video
  leading content (icon only); no segmented/reveal list variants.
