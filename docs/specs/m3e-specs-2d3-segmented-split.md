# M3E specs — 2d.3 PR D3: segmented button + split button

Sources (androidx-main, `/tmp/m3compose2/`): `d3-SegmentedButton.kt`, `d3-SplitButton.kt`, tokens: `d3-tokens-OutlinedSegmentedButtonTokens.kt`, `d3-tokens-SplitButton{XSmall,Small,Medium,Large,XLarge}Tokens.kt`, `d3-tokens-ConnectedButtonGroupSmallTokens.kt`, `d3-tokens-SegmentedMenuTokens.kt`.

## Segmented button (SingleChoiceSegmentedButtonRow + SegmentedButton)

| Token | Value | Used for |
|---|---|---|
| `ContainerHeight` | 40dp | segment height (row min height) |
| `LabelTextFont` | LabelLarge (14/20/500) | segment label |
| `IconSize` | 18dp | segment icon |
| IconSpacing | 8dp | icon → label gap |
| ContentPadding | 12dp start / 12dp end | segment content padding |
| `OutlineColor` / `OutlineWidth` | Outline / 1dp | segment border |
| `SelectedContainerColor` | SecondaryContainer | selected segment fill |
| Selected content | OnSecondaryContainer | selected label + icon |
| Unselected content | OnSurface | unselected label + icon |
| Disabled content | OnSurface @ 0.38 | disabled label + icon |
| Disabled outline | OnSurface @ 0.12 | disabled border |
| `Shape` | CornerFull | base shape (itemShape derives per-position) |
| ButtonDefaults.MinWidth | 58dp | segment min width |
| BorderWidth (= OutlineWidth) | 1dp | row overlap (`spacedBy(-space)`) |

- **Row**: segments are EQUAL width (weight 1f), intrinsic row width; segments OVERLAP by 1dp so borders coincide (no double border).
- **itemShape(index, count)** with baseShape CornerFull: count==1 → full; index 0 → start side full (tl=bl=h/2, tr=br=0); last → end side full; middle → square (0).
- **State layer**: content color @ hover 0.08 / focus 0.10 / pressed 0.12 over the container (selected: on_secondary_container; unselected: on_surface).
- **Interaction**: selection is EXTERNAL (`Signal(usize)`); a click sets the signal + fires `on_change`. Keyboard: the row is focusable; left/right (up/down) arrows move the selection (radio-group semantics — arrows select).
- **Semantics**: role group (radio group), focusable, value = the selected item's label.
- **v1 deviations**: single-choice only (MultiChoiceSegmentedButtonRow is a follow-up); no M3E shape morph on the selected segment (the checked icon crossfade is static); no icon-less-to-icon transition animation.

## Split button (SplitButtonLayout + LeadingButton/TrailingButton, filled style)

| Size | Height | Lead pad L | Lead pad R | Trail icon | Trail pad L=R |
|---|---|---|---|---|---|
| xsmall | 32 | 12 | 10 | 22 | 13 |
| small | 40 | 16 | 12 | 22 | 13 |
| medium | 56 | 24 | 24 | 26 | 15 |
| large | 96 | 48 | 48 | 38 | 29 |
| xlarge | 136 | 64 | 64 | 50 | 43 |

- `BetweenSpace` = 2dp (the gap between the two buttons); `LeadingButtonMinWidth` = `TrailingButtonMinWidth` = 48dp.
- **Leading button**: filled (Primary container / OnPrimary content), label **LabelLarge** + optional leading icon (20dp, ButtonSmallTokens.IconSize); shape: start corners CornerFull (h/2), end corners ExtraSmall (4dp).
- **Trailing button**: filled, trailing icon (per-size), shape: start corners ExtraSmall, end corners CornerFull.
- **v1 deviations**: filled style only (tonal/elevated/outlined variants are follow-ups); static inner corners (the M3E hover/press morph ExtraSmall → Medium 12dp is a follow-up); the trailing button fires a callback — the app opens a menu (no embedded menu); both buttons share the enabled state.

## Framework addition (this PR)

`kx_stroke_rrect_corners` (ABI **0.8.0**) — stroke a rounded rect with PER-CORNER radii (the segmented/split buttons stroke 1dp borders on start/end/middle shapes). Mirrors `kx_fill_rrect_corners` (0.7.0) with a stroke paint; `kx_abi_version()` bumped + pinned.

## Registry

- `segmented_button` (input): `items` = manually parsed array (`[{label, icon?}]`), `selected` = live usize signal (round-trips); skip_children (segments are chrome).
- `split_button` (input): label (text), leading_icon (select), trailing_icon (select), size (select), enabled (toggle); no live fields (clicks are app callbacks); skip_children.

## Follow-ups

- Multi-choice segmented button row; segmented/split shape morph (Phase 3); split button tonal/elevated/outlined variants; split button embedded menu.
