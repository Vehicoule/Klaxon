# M3E TextField v1 spec (2d.2 PR C2) — consolidated from Compose androidx-main

Sources: `TextField.kt`, `OutlinedTextField.kt`, `internal/TextFieldImpl.kt`,
`TextFieldDefaults.kt`, `tokens/FilledTextFieldTokens.kt`,
`tokens/OutlinedTextFieldTokens.kt`, `tokens/ShapeTokens.kt` (all in /tmp/m3compose2).

## Geometry (single-line)
- Container height 56 (with or without label). OutlinedTextFieldTokens.ContainerHeight = 56.
- Horizontal padding 16 (TextFieldPadding). With-label vertical padding 8
  (TextFieldWithLabelVerticalPadding); without label 16 all around.
- Label expanded (unfocused + empty): body_large (16/24), vertically centered
  in the 56dp container (y=16), x = text_x.
- Label minimized (focused OR has text): body_small (12/16):
  - filled: y = 8 (top padding), x = text_x (inside the field)
  - outlined: line box centered ON the top edge (y = -8), x = 16 (cutout,
    start padding — NOT the icon offset); AboveLabelHorizontalPadding = 4
- Text position: filled → y = 24 when (label && minimized), else 16 (centered);
  outlined → always 16 (the cutout label does not push the text:
  max(centered, labelH/2) = max(16, 8)).
- Icons 24dp (LeadingIconSize/TrailingIconSize), at the edges (x=0 / w-24),
  vertically centered (y=16). Text/label offset: 16 without icon; 24+4=28 with
  (horizontalIconPadding = (48-24)/2 = 12 → startPadding = 16-12 = 4 after a
  24dp icon).
- Supporting text: below the container, x=16, y=56+4 (SupportingTopPadding),
  body_small (12/16). Total height 56 (+20 with supporting text).
- Shapes: filled = CornerExtraSmallTop (top 4, bottom 0); outlined =
  CornerExtraSmall (4 all corners).
- Filled active indicator: bottom line, full width, 1dp (2dp focused).
- Outlined stroke: 1dp (2dp focused), centered on the edge.

## Colors (priority: disabled > error > focused > hover > base)
- filled container: SurfaceContainerHighest; disabled OnSurface@0.04
- filled indicator: OnSurfaceVariant; hover OnSurface; focused Primary (2dp);
  error Error; disabled OnSurface@0.38
- outlined stroke: Outline; hover OnSurface; focused Primary (2dp); error Error;
  disabled OnSurface@0.12
- input text: OnSurface; disabled OnSurface@0.38
- label expanded: OnSurfaceVariant; hover OnSurface; error Error; disabled @0.38
- label minimized: focused Primary; unfocused OnSurfaceVariant; error Error;
  disabled @0.38
- placeholder: OnSurfaceVariant; disabled @0.38
- icons: OnSurfaceVariant; disabled @0.38
- supporting: OnSurfaceVariant; error Error; disabled @0.38
- caret: Primary; error+focused Error

## Interaction
- pointer down → requestFocus + markLayoutDirty; up inside claimed; enter/leave
  → hover + markDirty; drag past slop → not claimed (scroll)
- text_input appends; backspace deletes the last UTF-8 codepoint; enter →
  on_submitted; escape → blur. Edits → markDirty (+ markLayoutDirty when the
  emptiness changes — the label float) + semantics value + on_changed +
  signal mirror.
- disabled: swallows everything; semantics disabled, focusable=false.
- semantics: role .text_field, label = label, hint = placeholder, value = text.

## v1 deviations (documented, fixed later)
- Single-line only. Instant label float (the Compose labelProgress lerp lands
  with the motion phase). Static caret at the text end (no blink, no
  selection, no click-to-position). Outlined cutout = a surface-colored patch
  over the stroke (assumes a surface-toned background; a true path gap lands
  with Phase 3). No prefix/suffix, no character counter. RTL mirrors the chrome;
  the text run stays LTR (no bidi — same as text.zig). Caret 1dp wide.

## Registry
Entry "text_field" (category input). A non-null "value" option → a live
Signal(TextBuf) mirror (TextBuf = [256]u8, null-terminated invariant), field
"value" round-trips the current text. Schema = schemaOf(TextFieldOptions) +
"value" (text).
