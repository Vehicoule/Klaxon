# M3E specs — 2d.4 PR #32: loading indicator

Sources: `m3.material.io/components/progress-indicators` (loading indicator) +
material-components-android `lib/java/com/google/android/material/loadingindicator/`
(`LoadingIndicator.java`, `LoadingIndicatorDrawable.java`, `LoadingIndicatorSpec.java`)
+ androidx `compose/material3/LoadingIndicator.kt` (`/tmp/m3compose2/d3-LoadingIndicator.kt`,
684 lines) + `LoadingIndicatorTokens.kt` (`/tmp/m3compose2/d3-LoadingIndicatorTokens.kt`).
The m3e-canvas port (github.com/lnkiai/m3e-canvas) confirms the Compose port carries
the same tokens.

## Tokens (LoadingIndicatorTokens / LoadingIndicatorDefaults)

| Token | Value | Used for |
|---|---|---|
| `ContainerWidth` / `ContainerHeight` | 48dp | the widget's measured size |
| `ContainerShape` | CornerFull | the contained variant's container |
| `ActiveSize` | 38dp | the indicator shape's diameter (scale 38/48) |
| `ActiveIndicatorColor` | `colorPrimary` | plain indicator color |
| `ContainedActiveIndicatorColor` | `colorOnPrimaryContainer` | contained indicator color |
| `ContainedContainerColor` | `colorPrimaryContainer` | contained container fill |
| `GlobalRotationDurationMillis` | 4666 | the indeterminate global rotation period |
| `MorphIntervalMillis` | 650 | one indeterminate morph step |
| `IndicatorPolygons` | [SoftBurst(12), Cookie9Sided(9), Pentagon(5), Pill, Sunny(8), Cookie4Sided(4), Oval(circle)] | the indeterminate shape sequence |
| `DeterminateIndicatorPolygons` | [Circle, SoftBurst(12)] | the determinate shape pair |
| `ActiveIndicatorScale` | 38/48 | the shape radius inside the 48dp box |

## Widget

- A LEAF (no children): it measures 48x48 and paints the container + the
  current shape itself.
- **Plain** (`contained = false`): transparent container, the indicator in
  `Primary`, shape radius = `min(w,h) / 2 × 38/48`.
- **Contained** (`contained = true`): a `PrimaryContainer` CornerFull circle
  (radius = `min(w,h) / 2`), the indicator in `OnPrimaryContainer`.
- **Indeterminate** (`progress = null`): the morph loop. Every 650ms the
  shape morphs 0→1 (spring) to the NEXT polygon and the shape rotation gains
  +90°; continuously the global rotation advances 360° per 4666ms (linear).
  v1 paints each shape as a hard switch at the morph boundaries (no
  cross-fade between polygons — the polygons are painted directly, rotated
  around the center; even N-gons start flat-top, odd N-gons vertex-up).
  The loop is timeline-driven (two chained tweens on the widget's channels,
  restarted at completion); without a timeline the indicator is STATIC at
  shape 0 (golden tests).
- **Determinate** (`progress` = a `Signal(f32)`, two-way app-owned): the
  shape is `Circle` while `p < 0.5`, `SoftBurst(12)` while `p ≥ 0.5`; the
  rotation is `-clamp(p, 0, 1) × 180°` (counterclockwise). No loop.
- **v1 deviations / follow-ups**: no cross-fade morph interpolation (hard
  polygon switches), no morph progress curve (the +90° step is linear in
  time), the arc/polygon fill uses the new `kx_fill_polygon` C ABI primitive
  (ABI 0.9.0 — SkPathBuilder moveTo/lineTo/close + fill; vertices computed in
  Zig, no tessellation), no spin for the determinate variant.

## Registry

- `loading_indicator` (feedback): `contained` (toggle) automatic; `progress`
  (number) = ALWAYS-live f32 signal when present (round-trips); absent → the
  indeterminate loop (no live field). No skip_children (a leaf).

## Follow-ups

- Cross-fade morph interpolation between polygons, the morph progress curve,
  the shared `ContainedLoadingIndicator` spin variant (2d.5), date/time
  pickers + color picker (PR #33, the rest of 2d.4).
