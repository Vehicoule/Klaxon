# M3E specs — 2d.2 PR A: Buttons x5 (FULLY validated, implemented in src/widgets/button.zig)

Sources: androidx/androidx compose/material3 (androidx-main): Button.kt,
BaselineButtonTokens, Button{XSmall,Small,Medium,Large,XLarge}Tokens,
{Filled,FilledTonal,Elevated,Outlined,Text}ButtonTokens + m3.material.io/components/buttons(/specs).

## Sizes
| | XS | S | M | L | XL |
|---|---|---|---|---|---|
| container height | 32 | 40 | 56 | 96 | 136 |
| icon | 20 | 20 | 24 | 32 | 40 |
| icon-label gap | 8 | 8 | 8 | 12 | 16 |
| h padding | 12 | 16 | 24 | 48 | 64 |
| v padding | 6 | 8 | 16 | 32 | 48 |
| square corner | 12 | 12 | 16 | 28 | 28 |
| pressed corner | 8 | 8 | 12 | 16 | 16 |
| outline width | 1 | 1 | 1 | 2 | 3 |
| label style | label_large | label_large | title_medium | headline_small | headline_large |

- round (default) = CornerFull = pill (h/2); pressed morph applies to round AND square ("Both round and square buttons should have the same pressed shape" — m3.material.io)
- text variant: h padding 12 start / 12 end (16 end with icon), v padding = size's
- min width 58dp (small only — Compose ButtonDefaults.MinWidth; other sizes hug content), min height = container height (all sizes)
- tonal small icon = 18dp (FilledTonalButtonTokens.IconSize)
- Compose desktop nuance NOT adopted (spec wins): small v padding 10 (touch) / 8 (precision pointer), MinHeight 36 desktop — we render the published spec values everywhere

## Variants (enabled)
| variant | container | label/icon | outline |
|---|---|---|---|
| filled | Primary | OnPrimary | — |
| filled_tonal | SecondaryContainer | OnSecondaryContainer | — |
| elevated | SurfaceContainerLow | Primary | — |
| outlined | transparent | OnSurfaceVariant | OutlineVariant |
| text | transparent | Primary (SPEC m3.material.io; Compose token OnSurfaceVariant — spec wins) | — |

## Disabled
- container: OnSurface@0.10 (filled/elevated/text — text DOES paint a faint container), 0.12 (tonal), transparent (outlined)
- label/icon: OnSurfaceVariant@0.38 (tonal: OnSurface@0.38)
- outlined border: OutlineVariant@0.10 (Compose: OutlineColor.copy(alpha = DisabledContainerOpacity))

## State layers
on-color @ hover 0.08 / focus 0.10 / pressed 0.12 / drag 0.16, blended over the container (theme.stateLayer); over a transparent container = on-color at that alpha. Disabled: no layers.

## v1 deviations (documented in button.zig header)
- No elevation shadows (Phase 3 raster shadow pass); elevated = flat SurfaceContainerLow
- Instant pressed shape morph (animated morph = Phase 3)
- Label weight via the Text bold flag (weight >= 500 → bold); no weight axis yet
