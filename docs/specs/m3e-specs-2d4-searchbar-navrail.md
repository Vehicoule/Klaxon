# M3E specs — 2d.3 PR D4: search bar + navigation rail

Sources (androidx-main, `/tmp/m3compose2/`): `d3-SearchBar.kt`, `d3-NavigationRail.kt`, `d3-WideNavigationRail.kt`, `d3-NavigationItem.kt`, `TextFieldImpl.kt` (the decorator layout), `TextFieldDefaults.kt`, tokens: `d3-tokens-SearchBarTokens.kt`, `d3-tokens-NavigationRail{Collapsed,Expanded,VerticalItem,HorizontalItem,BaselineItem,Color}Tokens.kt`, `FilledTextFieldTokens.kt`.

## Search bar (collapsed pill — v1 scope)

| Token | Value | Used for |
|---|---|---|
| `ContainerHeight` | 56dp | pill height |
| `ContainerShape` | CornerFull | pill shape |
| `ContainerColor` | SurfaceContainerHigh | pill fill (focused too — the inner text field's container is Transparent) |
| `InputTextFont` | BodyLarge (16/24) | input text |
| `InputTextColor` | OnSurface | input text |
| `LeadingIconColor` | OnSurface | search icon |
| `TrailingIconColor` | OnSurfaceVariant | clear button |
| `SupportingTextColor` | OnSurfaceVariant | placeholder |
| `FocusIndicatorColor` | Secondary | (unused in v1 — no focus ring, caret only) |
| `SearchBarMinWidth` / `SearchBarMaxWidth` | 360 / 720dp | width clamp (`sizeIn`) |
| `SearchBarIconOffsetX` | 4dp | icon visual offset inside its 48dp min-interactive box |
| `FilledTextFieldTokens.CaretColor` | Primary | caret |
| `TextFieldPadding` | 16dp | content padding (contentPaddingWithoutLabel) |
| `textFieldHorizontalIconPadding` | (48-24)/2 = 12dp | text gap after the icon box (16-12 = 4) |

- **Layout** (the TextFieldImpl decorator row + the search bar's icon offsets): the leading icon box is 48dp wide at x=0 with the 24dp icon visual at **16..40** (centered 12 + 4 offset — "16dp padding between icons and start/end"); the text starts at **48 + 4 = 52**; the trailing icon box is 48dp at x=W-48 with the icon visual at **W-40..W-16**; the text ends 4dp before the trailing box, or 16dp from the edge when there is no trailing icon. Text body_large, vertically centered (y = 16). Single line, clipped between the icons.
- **Trailing**: a clear button (close icon, OnSurfaceVariant) shown **iff the text is non-empty**; clicking it clears the text (keeps focus) and fires `on_changed`.
- **Colors**: pill SurfaceContainerHigh (all states); text OnSurface; placeholder OnSurfaceVariant; leading icon OnSurface; caret Primary; disabled: content OnSurface @ 0.38, no focus/edits, container unchanged.
- **State layers**: hover 0.08 / pressed 0.12 of OnSurface over the pill; focus shows the caret only (v1 deviation — the inset focus ring is a follow-up).
- **Interaction**: click focuses; typing appends (TextBuf null-terminated buffer); backspace deletes the last UTF-8 codepoint; Enter fires `on_submitted` (imeAction = Search); Escape blurs. The clear-button zone is the trailing 48x56 box (only when the text is non-empty): down claims, up inside clears.
- **Measure**: w = clamp(52 + text_w + (trailing ? 52 : 16), 360, 720); h = 56.
- **Semantics**: role `.text_field`, focusable, value = the text, label/hint = the placeholder. The text mirrors a `Signal(TextBuf)` both ways (registry round-trip).
- **RTL**: the chrome mirrors (search icon to the end side, clear button to the start); the text run stays LTR (same as text_field).
- **v1 deviations / follow-ups**: the expanded full-screen view + suggestions dropdown (SearchView), the avatar leading icon (30dp CornerFull), the inset focus ring (FocusIndicatorColor), predictive back, prefix/suffix.

## Navigation rail (collapsed + expanded — v1 scope)

| Token | Value | Used for |
|---|---|---|
| Collapsed `ContainerWidth` | 96dp | collapsed rail width |
| Collapsed `TopSpace` | 44dp | content top padding (both states) |
| Collapsed `ItemVerticalSpace` | 4dp | gap between items |
| Collapsed `ContainerColor` / `ContainerShape` | Surface / CornerNone | rail background |
| Expanded `ContainerWidth{Minimum,Maximum}` | 220 / 360dp | expanded rail width clamp |
| VerticalItem `ActiveIndicator{Width,Height}` | 56 / 32dp | top-icon (collapsed-with-label) pill |
| VerticalItem `IconLabelSpace` / `LabelTextFont` | 4dp / LabelMedium | top-icon item |
| HorizontalItem `ActiveIndicatorHeight` | 56dp | start-icon (expanded) pill height |
| HorizontalItem `LeadingSpace` / `FullWidthLeadingSpace` | 16dp | icon padding inside the pill |
| HorizontalItem `IconLabelSpace` / `LabelTextFont` | 8dp / LabelLarge (14/20/500) | expanded item |
| `WNRItemHorizontalPadding` | 20dp | expanded item leading space (pill x = 20) |
| `WNRItemNoLabelIndicatorPadding` | (56-24)/2 = 16dp | collapsed icon-only indicator = 56x56 circle |
| `ItemTopIconIndicator{Horizontal,Vertical}Padding` | 16 / 4dp | top-icon pill = 56x32 |
| Color `ItemActiveIndicator` | SecondaryContainer | active indicator |
| Color `ItemActiveIcon` | OnSecondaryContainer | active icon (both positions) |
| Color `ItemActiveLabelText` | Secondary | active label (top-icon position) |
| (start-icon label) | OnSecondaryContainer | active label (expanded/start-icon — `selectedTextColorStartIconPosition = ItemActiveIcon`) |
| Color `ItemInactive{Icon,LabelText}` | OnSurfaceVariant | inactive icon + label |
| State layers | OnSecondaryContainer @ hover 0.08 / focus 0.10 / pressed 0.12 | over the indicator only |
| Disabled | OnSurfaceVariant @ 0.38 (DisabledAlpha) | icon + label |

- **Collapsed** (`expanded = false`): width 96, Surface background; items stacked from y = 44, 4dp apart, each **56dp tall** x full width, icon 24 centered. Selected → **56x56 CornerFull (circle)** SecondaryContainer indicator centered; icon OnSecondaryContainer. State layer over the circle.
- **Expanded** (`expanded = true`): width clamp(max_item_w, 220, 360); items **56dp tall**, start-aligned; selected → **pill 56 tall x (label_w + 64)** at x = 20 (CornerFull, SecondaryContainer); icon 24 at x = 36 (20 + 16); label LabelLarge at x = 68 (36 + 24 + 8), vertically centered; active label OnSecondaryContainer. State layer over the pill.
- **Selection**: external `Signal(usize)` (two-way round-trip) + `on_change`; a click selects; the rail is a focusable group — up/down arrows move AND select (skip disabled, wrap; RTL flips left/right). Semantics: role `.group`, focusable, value = the selected item's label.
- **Measure**: collapsed w = 96; expanded w = clamp(max(label_w + 84), 220, 360); h = the assigned height when finite (fillMaxHeight), else 44 + count*56 + (count-1)*4.
- **v1 deviations / follow-ups**: the header (FAB) slot + footer slot, the modal variant (SurfaceContainer, CornerLarge, Level2 + scrim), the collapsed<->expanded width/icon-position animation, `alwaysShowLabel` in the collapsed state (top-icon pill 56x32 + label_medium below, item 56 tall), item badges.

## Registry

- `search_bar` (input): `placeholder` (text), `initial` (text), `enabled` (toggle); the live text is a `Signal(TextBuf)` mirrored both ways (field `value`, like text_field); skip_children (the pill is chrome).
- `navigation_rail` (navigation): `items` = manually parsed array (`[{label, icon?, enabled?}]`), `expanded` (toggle), `selected` = ALWAYS-live usize signal (round-trips, like segmented_button); skip_children (the items are chrome).

## Follow-ups

- Search bar: expanded full-screen view + suggestions, avatar leading icon, focus ring, prefix/suffix.
- Navigation rail: header/footer slots, modal variant + scrim, collapse/expand animation, collapsed-with-label (top-icon), badges.
