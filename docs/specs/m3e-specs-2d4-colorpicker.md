# M3E specs — 2d.4 PR #35: color picker

Sources: **no official M3/M3E color picker exists** (checked 2026-10-10 — no
m3.material.io component page, no compose-material3 / material-components-android
/ m3e-canvas / matraic-m3e port; the Android 14+ system color picker lives in
SystemUI/Settings, not a library). This is a **framework-original design**,
tokenized from `src/theme.zig` (ADR-0010), cross-referenced with the researched
pickers below. PR #34 landed the paint primitive it renders with:
`kx_fill_rrect_gradient` (ABI 0.10.0 — a 2..8-stop linear gradient clipped to a
rounded rect, premul interpolation; no shader type crosses the ABI).

This document supersedes the earlier draft of this file (320x344, no alpha
slider, no research section); the draft's SV saturation-overlay stops were also
reversed (see Research, VS Code note).

## Research — what existing color pickers do

| Reference | Layout | Dimensions | Tokens | Interactions | States |
|---|---|---|---|---|---|
| material-components-android / Compose M3 / M3E | none — no picker ships | — | only the composed tokens: Slider, TextField, Dialog, text buttons | — | — |
| iOS `UIColorPickerViewController` (iOS 14+) | popover: hue spectrum slider, brightness slider, opacity slider, eyedropper | no published pixel spec (HIG: 44pt hit targets, fill-to-thumb track) | system colors | live two-way via `selectedColor` + delegate; `supportsAlpha`, `supportsEyedropper` (iOS 15+) | system sliders |
| iOS 14 system picker (Settings/Photos) | color well + swatches; Grid / Spectrum / Sliders modes; opacity slider; eyedropper | not published | system | well shows the color over a black/white split; swatches swipeable, + to add, long-press to delete; tap the opacity % to type; Sliders mode = RGB sliders + hex (P3/sRGB toggle) | system |
| Flutter `flutter_colorpicker` 1.1.0 | portrait Column: SV area, Row [current-color indicator + Column [hue slider, alpha slider]], history row, RGB/HSV/HSL label, hex input bar; landscape = Row | `colorPickerWidth` 300, area 300x300 (`pickerAreaHeightPercent` 1.0), sliders 40 high, history 50 (30x30 swatches), hex bar optional | Flutter theme | HSV internal; hex accepts 3/6/8 digits + optional `#`, respects `enableAlpha`; `colorHistory` + `onHistoryChanged`; also BlockPicker / MaterialPicker / HueRingPicker / SlidePicker | Flutter defaults |
| VS Code (`src/vs/editor/contrib/colorPicker/`) | header (picked color + original color + close) over body: SV box + vertical hue strip + vertical opacity strip; standalone adds a hex input | header 24, body pad 8, SV box 150 high / min-width 220, strips 25x150 (122 standalone), 8px gaps, hex input 20x58 | editor hover widget tokens | HSVA single source of truth; picked-color click = copy, original-color click = revert; hue = (1-value)x360 on the vertical strips | CSS hover |
| Figma (help.figma.com) | SV square, vertical hue slider at the right edge, vertical opacity slider below it, eyedropper button, color-model dropdown + model fields, contrast-check action | not published | Figma UI | live; Hex = `#RRGGBBAA` (8 chars); models: Hex/HSB/HSL/CSS/RGB; CSS accepts rgba()/color()/oklch()/oklab(); "Check color contrast" (WCAG) | Figma UI |
| Web native `<input type="color">` (Chrome) | OS panel: eyedropper, SV shades square with a draggable circle, vertical hue slider right of the square, opacity slider below (checkerboard), hex input at the bottom; DevTools adds palettes + a color-space switcher + contrast readout | not published (no formal spec — de-facto Chrome; Safari = swatch grid, Firefox = square + hue; Open UI: research issue #1371 only) | OS | EyeDropper API (Chrome 95+); DevTools palettes: Material / custom / CSS variables / page colors; spaces: hex/rgb/hsl/hwb/lch/oklch | OS |

### material-components-android / Compose M3 / M3E

No color picker widget exists in MDC-Android, Compose Material3, m3e-canvas or
matraic-m3e (verified 2026-10-10; the ROADMAP note of 2026-10-09 says the same).
`material-components-android` ships only `com.google.android.material.color`
utilities + `material-color-utilities` (HCT tonal palettes). What M3 *does*
provide is the token set a picker composes — and what this widget composes:

- Slider: 16dp pill track (CornerFull), 4x44dp vertical-bar thumb (2dp
  focused/pressed), 40dp state-layer circle, active `Primary` / inactive
  `SecondaryContainer`, 48dp hit floor, arrows ±0.05, gesture arbitration
  (a vertical drag is a scroll).
- TextField: 56dp single-line filled/outlined, CornerExtraSmall (4dp), 1dp
  `Outline` stroke (2dp focused), floating label.
- Dialog: `SurfaceContainerHigh`, CornerExtraLarge (28dp), 280-560dp wide.
- The 2d.4 pickers batch (PR #33): the modal panel conventions —
  `SurfaceContainerHigh` + CornerExtraLarge 28dp container, 360dp wide.

### iOS `UIColorPickerViewController` + the iOS 14 system picker

The API controller (Apple docs): a standard interface presented as a popover —
a hue **spectrum** slider, a **brightness** slider (black to the current hue),
an **opacity** slider (checkerboard to the current color, only when
`supportsAlpha`), an **eyedropper** button (iOS 15+, `supportsEyedropper`), and
live `selectedColor` + delegate callbacks. Apple publishes no pixel spec for it.

The iOS 14 *system* picker (Settings/Photos) is richer: a **color well** (a
large square showing the current color over a black/white split — the preview
shows alpha), **swatches** (black + the four primaries + saved colors; swipeable
pages; + to add; long-press to delete), an **opacity slider** (tap the percentage
to type it), an **eyedropper** (a magnifier loupe), and three modes: **Grid**
(120 fixed colors), **Spectrum** (a continuous 2D gradient area), **Sliders**
(RGB sliders + a hex field, Display P3/sRGB toggle).

Takeaways: live two-way updates everywhere; the preview shows the color over a
split/checker background so alpha is visible; swatches/history are a system-level
pattern; an opacity slider is standard.

### Flutter `flutter_colorpicker` 1.1.0

`ColorPicker` (portrait): a Column — the **SV area** (`colorPickerWidth` 300dp
wide, `pickerAreaHeightPercent` 1.0 → a 300x300 square, `pickerAreaBorderRadius`),
then a Row with a **ColorIndicator** (the current-color swatch; tap = add to
`colorHistory`) beside a Column of two horizontal sliders (**hue**, then **alpha**
when `enableAlpha`, 40dp high each), then the **history row** (50dp, 30x30
swatches), the **label row** (RGB/HSV/HSL values), and the optional **hex input
bar** (`hexInputBar`; accepts 3/6/8 hex digits with an optional `#`, respects
`enableAlpha`). Landscape switches to a Row (area + slider column). Siblings:
`BlockPicker` (a swatch grid), `MaterialPicker`, `HueRingPicker` (a hue ring
around the SV square), `SlidePicker` (sliders only). `PaletteType` covers
hsv/hsl/rgb/hueWheel area variants. HSV is the internal model.

Takeaways: the vertical-stack idiom; the current-color indicator beside the
sliders; the hex 3/6/8 + optional-`#` rule.

### VS Code

`ColorPickerWidget` = header + body (`colorPickerWidget.ts`,
`colorPickerParts/`):

- **Header** (24px, checkerboard background, 9px tiles): the **picked-color**
  preview (flex 1 / 240px — the hex text centered, white text, black when the
  color is light; click = copy to clipboard), the **original-color** swatch
  (74px; click = revert), a close button (standalone).
- **Body** (flex row, 8px padding): the **SaturationBox** (150px high, min-width
  220, flex 1 — a canvas painting the hue base + a white-to-transparent
  horizontal gradient (stops 0 / 0.5 / 1 — opaque white at the LEFT, S=0) +
  a transparent-to-black vertical gradient; the selection cursor = a 9x9 circle,
  1px white border, radius 100%, drop shadow), the **HueStrip** (vertical 25x150,
  margin-left 8 — a 7-stop rainbow to bottom: `#f00` 0%, `#ff0` 17%, `#0f0` 33%,
  `#0ff` 50%, `#00f` 67%, `#f0f` 83%, `#f00` 100%), the **OpacityStrip**
  (vertical 25x150 — checkerboard + a transparent-to-opaque gradient of the
  current color; 122px tall in the standalone variant). The strip thumb = a 4px
  horizontal bar spanning the strip (left -2, width +4), 1px white-ish border,
  shadow. Standalone adds a hex input (20x58) + an insert button.
- HSVA is the single source of truth; on the vertical strips hue = (1-value)x360.

Takeaways: the right-strip idiom; the 7-stop rainbow at 0/17/33/50/67/83/100
(the ABI's evenly-spaced 7 stops match); the ring cursor; the original-color
revert; copy-on-click.

### Figma

The color picker: an **SV square** (top), a **vertical hue slider** at the right
edge, a **vertical opacity slider** below the hue (checkerboard), an
**eyedropper** tool button, a **color-model dropdown** (Hex/HSB/HSL/CSS/RGB)
below the sliders with the model's input fields (Hex = `#RRGGBBAA`, 8 chars;
RGB/HSB/HSL = 4 fields; CSS = one field accepting `rgba()`, `color()`,
`oklch()`, `oklab()`), and a **"Check color contrast"** WCAG action. It opens
from the fill/stroke swatch in the sidebar.

Takeaways: hue + opacity as a right-side strip pair; the model dropdown;
`#RRGGBBAA` hex; the contrast-check action (Klaxon already has
`theme.contrastRatio` — a natural follow-up).

### Web native `<input type="color">` (Chrome)

Chromium's panel (`ColorPickerPopupUI`): an **eyedropper** (EyeDropper API,
Chrome 95+), an **SV shades square** with a draggable color circle, a **vertical
hue slider** at the right of the square, an **opacity slider** below the square
(checkerboard), and a **hex input** at the bottom. The DevTools variant adds
**palette swatches** (Material / custom / CSS variables / page colors), a
**display-value switcher** (hex/rgb/hsl/hwb/lch/oklch), and a **contrast-ratio**
readout. There is no formal spec — Chrome's panel is the de-facto reference
(Safari = a swatch grid + custom; Firefox = square + hue; Open UI has only a
research issue, #1371).

Takeaways: the mixed idiom (square + right hue strip + alpha below + hex at the
bottom); the eyedropper is now standard across platforms; hex entry at the bottom.

### Cross-cutting synthesis (what the M3E picker takes)

1. The SV square = hue base + white-to-transparent (L→R) + transparent-to-black
   (top→bottom) — three rrect-clipped layers; `kx_fill_rrect_gradient` does
   exactly this (2-stop overlays, premul interpolation = correct alpha fades).
2. The hue slider = a 7-stop rainbow (red/yellow/green/cyan/blue/magenta/red);
   the ABI's evenly-spaced 7 stops match VS Code's 0/17/33/50/67/83/100.
3. The alpha slider = checkerboard + transparent-to-opaque of the current color.
4. HSV(A) is the universal internal model; every control syncs live, two-way.
5. Hex = 3/6/8 digits + optional `#`; `#RRGGBBAA` when alpha is on (Figma).
6. The cursor = a small ring (VS Code/Figma/Chrome), not a filled dot.
7. The thumb on gradient tracks = white/light (VS Code's bar; Chrome/Figma/iOS
   circles) — M3E-ified as a white pill with a 1dp `Outline` stroke.
8. The preview shows the color over a checkerboard so alpha is visible (iOS's
   black/white split, VS Code's header, Chrome's alpha track).
9. The eyedropper, swatches/history, and RGB/HSL fields are the common extras —
   all out of v1 scope (follow-ups below).
10. M3E is mobile-first: the vertical stack (flutter's portrait idiom) with a
    large square and big touch targets; the desktop right-strip idiom (VS
    Code/Figma) is a follow-up variant.

## Tokens (framework-original M3E — there is no official color picker spec)

All values are `src/theme.zig` tokens or 4dp-grid measurements; nothing is
hardcoded in the widget (ADR-0010 consumption rules).

| Token | Value | Used for |
|---|---|---|
| Panel container | `SurfaceContainerHigh` | the panel fill (the 2d.4 pickers' container) |
| Panel shape | CornerExtraLarge (28dp) | the panel corners |
| Panel width | 320dp (option `width`) | the measured width |
| Panel padding | 16dp (`spacing.l`) | inner padding, all around |
| Row gaps | 8dp (`spacing.s`) | SV square → hue → alpha → field rows |
| SV square side | width − 32dp (= 288dp) | the SV area (a square) |
| SV square shape | CornerMedium (12dp) | the SV square corners |
| SV square stroke | 1dp `OutlineVariant` | the square's edge (its black corner on dark panels) |
| SV cursor | 12dp ring, 2dp stroke, white or black (higher `contrastRatio` vs the color under it), transparent center | the saturation/brightness knob |
| Slider row height | 44dp (the M3E slider's HandleHeight) | the hue/alpha rows |
| Slider track | 16dp pill (CornerFull = 8dp), vertically centered in the row | the hue/alpha tracks |
| Slider thumb | 4x44dp pill (M3E HandleWidth x HandleHeight), white fill + 1dp `Outline` stroke | the hue/alpha knobs |
| Hue gradient | 7 evenly-spaced stops `#FF0000 #FFFF00 #00FF00 #00FFFF #0000FF #FF00FF #FF0000` (L→R) | the hue track (`fillRRectGradient`) |
| SV saturation overlay | 2 stops `0xFFFFFFFF → 0xFFFFFF00` (L→R, white opaque at S=0) | the SV square (`fillRRectGradient`) |
| SV value overlay | 2 stops `0x00000000 → 0x000000FF` (top→bottom, black opaque at V=0) | the SV square (`fillRRectGradient`) |
| Alpha gradient | 2 stops: the current RGB `0xRRGGBB00 → 0xRRGGBBFF` (L→R) over the checkerboard | the alpha track (`fillRRectGradient`) |
| Checkerboard | 8dp tiles, `SurfaceContainerLowest` / `SurfaceContainerHighest` | the alpha track + the swatch (transparency) |
| Alpha track stroke | 1dp `OutlineVariant` | the checkerboard's edge |
| Swatch | 56x56dp, CornerSmall (8dp), the color over the checkerboard + 1dp `OutlineVariant` stroke | the preview |
| Hex field | the M3E outlined TextField: 56dp, CornerExtraSmall (4dp), 1dp `Outline` (2dp focused), label "Hex" | the hex entry |
| State layers | hover 0.08 / focus 0.10 / pressed 0.12 (`theme.state.*`) | 40dp circles at the cursor/thumb |
| Hit targets | 48dp floor (the M3E slider's pattern) | every interactive child |
| Keyboard steps | SV ±5% per axis; hue ±5°; alpha ±5%; Home/End on the 1D sliders | `on_key` |
| Disabled | content at 0.38 (`kx_layer_alpha`) + the field's own disabled rendering; not focusable | `enabled = false` |

## Widget

### color_picker (`src/widgets/color_picker.zig`)

- A composite panel (no external children — `skip_children` in the registry;
  the children are internal chrome, like the dialog's internal panel). The
  panel node is role `.group` (label "Color picker", value = the canonical hex,
  `notifyControlChanged` on every color change) and holds, in layout order:
  the SV square node, the hue slider node, the alpha slider node (only when
  `enable_alpha`), the hex field node. The panel paints its own chrome: the
  `SurfaceContainerHigh` CornerExtraLarge (28dp) background + the preview
  swatch; the children paint themselves.
- **Layout** (all on the 4dp grid; `W` = `opts.width`, default 320):

```
+--------------------------------------+  <- panel W x (W+168)dp, SurfaceContainerHigh,
| +----------------------------------+ |     CornerExtraLarge 28dp
| |                                  | |
| |   SV square (W-32) x (W-32)      | |  <- CornerMedium 12dp: hue base + white + black
| |   (s ->, v up)             (o)   | |     overlays (fillRRectGradient), 12dp ring
| |                                  | |     cursor, 1dp OutlineVariant stroke
| +----------------------------------+ |
|                8dp                   |
|  [================================]  |  <- hue row 44dp: 16dp pill track (7-stop
|                  [=]                 |     rainbow), 4x44 white pill thumb
|                8dp                   |
|  [idisjadisjadisjadisjadisjadisja]   |  <- alpha row 44dp (option enable_alpha):
|                  [=]                 |     checkerboard + color gradient, same thumb
|                8dp                   |
| +--------+ +----------------------+  |  <- field row 56dp: 56x56 swatch (color over
| | swatch | | Hex   #6750A4        |  |     checkerboard) + the M3E outlined
| +--------+ +----------------------+  |     TextField (W-104) x 56dp
+--------------------------------------+
   total height = W + 168dp (W + 116dp without the alpha row); 488 / 436dp at W=320
```

  Rect math (W=320): SV square `(16, 16, 288, 288)`; hue row `(16, 312, 288, 44)`
  with the track `(16, 326, 288, 16)`; alpha row `(16, 364, 288, 44)` with the
  track `(16, 378, 288, 16)`; field row y=416: swatch `(16, 416, 56, 56)`,
  field `(88, 416, 216, 56)`.
- **SV square** (child 1, role `.slider`): paints three rrect-clipped layers
  with `kx_fill_rrect_gradient` — (1) the base: a solid `fillRRect` of the pure
  hue `hsvToColor(h, 1, 1, 1)`; (2) the saturation overlay: 2 stops
  `0xFFFFFFFF → 0xFFFFFF00` L→R (white opaque at S=0); (3) the value overlay:
  2 stops `0x00000000 → 0x000000FF` top→bottom (black opaque at V=0). The ABI
  interpolates in premul, so the alpha fades are correct. A hue change repaints
  all three layers; an S/V change moves only the cursor. The cursor is a 12dp
  ring (2dp stroke via `strokeRRect` at radius 6 — the radio's circle-stroke
  pattern) whose color is white or black, whichever has the higher
  `theme.contrastRatio` against the color under the cursor (computed from the
  current HSV — total, no hardcoded gray); the center is transparent so the
  color under it shows through. The cursor center is clamped to the square
  inset by its 6dp radius (the ABI has no rrect clip — `kx_clip_rect` is
  rect-only). The state layer is a 40dp circle at the cursor in the ring color
  @ hover 0.08 / focus 0.10 / pressed 0.12. A down/drag sets (s, v) from the
  pointer — **both axes edit** (no scroll arbitration: the panel is a
  standalone/modal control, never embedded in scroll content); pressed is held
  for the whole drag (the slider pattern). Keyboard: ←/→ saturation ∓/± 5%,
  ↑/↓ brightness ±/∓ 5%. Hit target = the square's bounds.
- **Hue slider** (child 2, role `.slider`): a 44dp row; the track is a 16dp pill
  (CornerFull = 8dp) filled with the 7-stop rainbow (evenly spaced — the ABI's
  stop layout matches VS Code's 0/17/33/50/67/83/100). No stroke (the rainbow is
  self-defining). The thumb is the M3E slider's 4x44dp pill: white fill + 1dp
  `Outline` stroke, centered on the value with the M3E inset mapping
  (`thumb_cx = x + 2 + v*(w-4)`, `v = (px - x - 2) / (w - 4)`); the state layer
  is a 40dp white circle @ the state alpha. A down/drag sets `h = v*360`
  (clamped to [0, 360)) with the slider's exact gesture arbitration (a vertical
  drag past the slop is a scroll). Keyboard: ←/↓ −5°, →/↑ +5°, Home = 0°,
  End = 359°. Hit target = 48dp high centered on the row.
- **Alpha slider** (child 3, role `.slider`, only when `enable_alpha`): the same
  row/thumb/state layer. The track is the checkerboard — a base pill fill of
  tile A (`SurfaceContainerLowest`) + tile B (`SurfaceContainerHighest`) 8dp
  squares (2 rows; the two 8dp end columns stay tile A = the pill caps — no
  rrect clip in the ABI) — plus a 2-stop gradient of the current RGB
  (`0xRRGGBB00 → 0xRRGGBBFF`, L→R, premul) clipped to the pill, plus a 1dp
  `OutlineVariant` stroke (the checkerboard needs an edge). A down/drag sets
  `a = v`; keyboard ←/↓ −5%, →/↑ +5%, Home = 0%, End = 100%. When
  `enable_alpha = false` the child is not built and the color's alpha is forced
  to `0xFF` on every set.
- **Hex field** (child 4): the M3E outlined TextField (`text_field.zig`), 56dp,
  label "Hex", bound to an internal `Signal(TextBuf)`. Typing parses live
  (3/6/8 hex digits, optional leading `#`, case-insensitive — flutter's rule;
  3 digits expand `#abc → #AABBCC`; 8 digits only with alpha, masked to `0xFF`
  otherwise): valid → the color signal, invalid → inert. Enter/blur reformats
  the text to the canonical form; Escape reverts it. While the field is
  focused, external color changes do not rewrite its text (the user is typing);
  the text is reformatted on blur. The field keeps its own semantics
  (role `.text_field`).
- **Preview swatch** (panel-painted, passive): 56x56dp CornerSmall (8dp), the
  checkerboard (8dp tiles, 7x7 cells — the 4 corner cells are tile A and never
  poke out of the 8dp corners) + the selected color (its alpha composites over
  the tiles) + a 1dp `OutlineVariant` stroke. Not interactive in v1.
- **Color model**: HSV(A) internal (h 0..360, s/v/a 0..1); `Color` = u32
  `0xRRGGBBAA` external. Pub total conversions: `hsvToColor(h, s, v, a)`,
  `colorToHsv(c)`, `parseHex(str) ?Color`, `formatHex(c, with_alpha, buf)`.
- **State**: `color: *Signal(Color)` two-way (the app owns it; the picker
  subscribes — external sets repaint, sync the field when it is not focused,
  and sync the semantic values); `on_changed: ?Callback` fires on **user edits
  only** (pointer / keyboard / hex — the slider pattern; external sets do not
  re-fire it). Each child owns its hover/pressed/drag state (the slider
  pattern); the panel owns the text signal + the children.
- **State layers**: 40dp circles at the cursor/thumb — hover 0.08 / focus 0.10 /
  pressed 0.12 (`theme.state.*`, painted with `withAlphaScaled` like the
  slider); pressed is held during drags.
- **Disabled** (`enabled = false`): not focusable, no input, semantic disabled;
  the panel chrome + the square/slider children paint at 0.38
  (`ui.paint.layerAlpha` around their paint), the field child gets
  `enabled = false` (its own disabled rendering). The panel itself is not
  tinted.
- **RTL** (`ui.i18n.direction()`): the chrome mirrors — the saturation axis
  flips (S=0 at the right), the slider value axis flips, the swatch moves to
  the right of the field.
- **A11y** (roles / labels / values, attached in the factories):

| Node | Role | Label | Value | Actions |
|---|---|---|---|---|
| panel | `.group` | "Color picker" (option `a11y_label`) | `#6750A4` (canonical hex) | — |
| SV square | `.slider` | "Saturation and brightness" | "Saturation 50%, brightness 80%" | increment, decrement |
| hue slider | `.slider` | "Hue" | "210°" | increment, decrement |
| alpha slider | `.slider` | "Opacity" | "80%" | increment, decrement |
| hex field | `.text_field` | "Hex" | the field's text | — |

  Focus order (semantic-tree order): SV square → hue → alpha → hex. The
  increment/decrement actions map to the brightness (↑/↓) axis on the SV
  square; saturation follows ←/→. Semantic values sync via signal subscriptions
  (the slider pattern: `notifyControlChanged` on every color change). The host
  paints the focus ring around the focused child's bounds (2px ring, 3px
  offset mobile; 3px/2px desktop).
- **Pub**: `colorPicker(allocator, color: *Signal(Color), on_changed, opts)`,
  `ColorPickerOptions`, the rect helpers `svSquareRect` / `hueTrackRect` /
  `alphaTrackRect` / `swatchRect` / `hexFieldRect` (bounds + opts → Rect, the
  pickers' rect-helper style), and the color conversions.
- **v1 deviations** (documented, fixed later):
  - Framework-original: no official M3/M3E color picker exists — this spec IS
    the design (tokenized M3E, not a port).
  - Hex-only entry: no RGB/HSL/HSB fields, no color-model dropdown (Figma, VS
    Code, Chrome DevTools have them).
  - No eyedropper (iOS 15+ / Chrome 95+ / Figma — needs screen capture, a
    platform-layer follow-up).
  - No swatch palettes / history / recents (iOS swatches, flutter
    `colorHistory`, Chrome DevTools palettes).
  - No title header / OK-Cancel footer: a LIVE control — the signal round-trips
    on every change (the mission's `onChanged`); modal presentation = wrap the
    panel in a Dialog (dialog.zig).
  - No visible slider labels (the a11y labels carry the names; the hex field
    has its floating "Hex" label).
  - Hex field: no input masking (over-long input is inert until Enter/blur
    reformats — text_field v1 has no max-length); the text is not rewritten
    while focused.
  - No motion on the cursor/thumb (instant; the external-set spring is a
    follow-up).
  - en strings only ("Color picker", "Saturation and brightness", "Hue",
    "Opacity", "Hex").
  - HSV(HSB) is the only color model (no HSL/OKLCH — Chrome DevTools supports
    six spaces).
  - The SV square claims all drags (no scroll arbitration — a standalone/modal
    panel, not embedded in scroll content).
  - Alpha is forced to `0xFF` when `enable_alpha = false` (8-digit hex is parsed
    but masked).
  - The SV square's focus ring is the host ring around the square's bounds, not
    around the cursor.
  - The alpha track's checkerboard caps: the two 8dp end columns are solid tile
    A (no rrect clip in the ABI).
  - Enter/Space on the sliders inherits the host's semantic activation (a
    synthesized center tap — the same as the M3E slider).
  - Disabled = content at 0.38 via `kx_layer_alpha`; the panel itself is not
    tinted.

## Registry

- `color_picker` (category `input`): automatic options — `enabled` (toggle),
  `width` (number), `enable_alpha` (toggle), `a11y_label` (text); `color`
  (number `0xRRGGBBAA` OR a `"#RRGGBB"` / `"#RRGGBBAA"` string, ALWAYS-live u32
  signal, default `0x6750A4FF` = the light `Primary`) round-trips as `.int`.
  The alpha byte is forced to `0xFF` at build AND on save when `enable_alpha`
  is false (the time-picker clamp pattern — the round-trip echoes what the
  picker displays). `skip_children` (a panel; its children are internal).
  `onChanged`: the factory takes `on_changed: ?Callback` (fired on user edits);
  in the registry the change channel IS the live `color` signal (it
  round-trips) — callbacks are not serializable (ADR-0009 shape).
- New helpers in `src/registry.zig`: `valueToColor` (int → checked u32, string
  → `parseHex`), `buildColorSignal` / `readColorSignal` / `deinitColorSignal`
  (`Signal(u32)`). 40 registry widgets (74 catalog widgets).

## Gallery

- Section "Color picker (M3E)": the panel + a `BoundText(u32)` hex label
  (`fmtColor` helper); signal `cp_color` (`Signal(u32)`, init `0x6750A4FF`);
  ref `cp_m3e`. 2 gallery tests (an SV-square drag and a hue-slider drag
  round-trip through the signal), matching the pickers' test pattern.

## Follow-ups

- Eyedropper (a platform screen-capture layer).
- Color-model fields (RGB/HSL/HSB + a model dropdown — Figma / VS Code).
- Swatch palettes / history / recents (iOS / flutter / Chrome DevTools).
- A `title` option + an OK/Cancel variant (a modal confirmation flow, like the
  date/time pickers).
- Cursor/thumb spring on external signal changes (the effects spring,
  3800 / zeta 0.9 — the AnimatedOffset machinery exists).
- Keyboard: swallow Enter/Space on the picker sliders; PageUp/PageDown.
- A hue-ring / wheel variant (flutter's `HueRingPicker`).
- Input masking (max-length) in the hex field (a text_field follow-up).
- A landscape / side-by-side variant (flutter_colorpicker's Row layout — the
  VS Code/Figma right-strip idiom).
- Dynamic color: the picked color as an HCT seed (the theme's future
  dynamic-color layer).
- A focus ring around the SV cursor (not the square's bounds).
- A "Check color contrast" action (Figma) — `theme.contrastRatio` already
  exists; wire it to the swatch.
