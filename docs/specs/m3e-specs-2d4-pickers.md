# M3E specs — 2d.4 PR #33: date picker + time picker

Sources: `m3.material.io/components/date-pickers` + `m3.material.io/components/time-pickers`
+ androidx `compose/material3/DatePicker.kt` (`/tmp/m3compose2/d3-DatePicker.kt`, 2640 lines)
+ `DatePickerModalTokens.kt` (`/tmp/m3compose2/d3-DatePickerModalTokens.kt`)
+ `TimePicker.kt` (`/tmp/m3compose2/d3-TimePicker.kt`, 4145 lines)
+ `TimePickerTokens.kt` + `TimeInputTokens.kt` (`/tmp/m3compose2/d3-TimePickerTokens.kt`,
`d3-TimeInputTokens.kt`) + the m3e-canvas ports
(`/tmp/pickers.tsx` — Pickers.tsx, `/tmp/m3e-dpe.ts` — matraic DatepickerElement).

## Tokens (DatePickerModalTokens)

| Token | Value | Used for |
|---|---|---|
| `ContainerColor` | `SurfaceContainerHigh` | the panel |
| `ContainerShape` | CornerExtraLarge (28dp) | the panel corners |
| panel width | 360dp | measured width |
| header height | 120dp | title + headline block |
| `ModalHeaderTitleText` / color | LabelLarge / `OnSurfaceVariant` | "Select date" title |
| `ModalHeaderHeadlineText` / color | HeadlineLarge / `OnSurfaceVariant` | the selected date "EEE, MMM d" |
| `ModalHeaderDividerColor` | `OutlineVariant` | the 1dp header divider |
| nav row height | 56dp | month-year label + chevrons |
| `MonthNavigationLabelText` / color | LabelLarge / `OnSurfaceVariant` | "MMMM yyyy" |
| chevron icon buttons | 40dp hit, 24dp icons, `OnSurfaceVariant` | prev/next month |
| weekday row height | 48dp | 7 single letters, BodyLarge + `OnSurface` |
| day grid | 6 rows x 48dp (288dp), 40dp cells, 7dp gaps (SpaceEvenly) | the calendar |
| `DayContainerShape` | CornerFull | day cells |
| selected day | `Primary` fill + `OnPrimary` label | the selected day cell |
| today | 1dp `Primary` outline + `Primary` label | today's cell |
| unselected day | `OnSurface` | plain day cells |
| footer buttons | LabelLarge + `Primary`, CornerFull state layer | Cancel / OK |

## Tokens (TimePickerTokens)

| Token | Value | Used for |
|---|---|---|
| `ContainerColor` | `SurfaceContainerHigh` | the panel |
| `ContainerShape` | CornerExtraLarge (28dp) | the panel corners |
| panel size | 360 x 464dp | measured size |
| header height | 80dp (centered row, top pad 16) | plates + separator + toggle |
| plate size | 96 x 80dp | hour / minute plates |
| `TimeSelectorContainerShape` | CornerSmall (8dp) | the plates |
| active plate | `PrimaryContainer` + `OnPrimaryContainer` + 2dp `Primary` border | the plate matching the dial mode |
| inactive plate | `SurfaceContainerHighest` + `OnSurface` | the other plate |
| plate labels | DisplayLarge, zero-padded 2 digits | hour / minute |
| separator | 24dp wide, DisplayLarge, `OnSurface` | the ":" between the plates |
| period toggle | 52 x 80dp, CornerSmall, 1dp `Outline` border + 1dp divider | AM/PM (12h only) |
| selected half | `TertiaryContainer` + `OnTertiaryContainer` | the active period |
| unselected half | transparent + `OnSurfaceVariant` | the inactive period |
| period labels | TitleMedium | "AM" / "PM" |
| dial size | 256dp circle, `SurfaceContainerHighest` | the dial face |
| label ring | 101dp (`OuterCircleToSizeRatio` = 101/256), 48dp cells, BodyLarge | the dial labels |
| hour screen | 12, 1..11 at 30° steps from the top | the 12h hour dial |
| minute screen | 00, 05..55 at 30° steps | the minute dial |
| 24h hour screen | DUAL RING: 00..11 on the outer ring (101dp) + 12..23 on the inner circle (69dp, `InnerCircleToSizeRatio` = 69/256) | the 24h hour dial |
| ring threshold | `MaxDistance` = 74dp: a tap at radius >= 74 picks the outer ring (0..11), closer the inner (12..23) | the 24h ring selection |
| selector knob | 48dp `Primary` CornerFull circle on the selected hour's ring + the selected label `OnPrimary` (drawn ON TOP of the knob) | the selected value |
| track | 2dp `Primary` line, center → the knob's near edge (ring - 24) | the hand |
| center dot | 8dp `Primary` | the dial center |
| footer | Cancel / OK (same as the date picker) | footer buttons |

## Widgets

### date_picker (`src/widgets/date_picker.zig`)

- A LEAF panel (skip_children): measures 360 x 564, paints all its chrome
  from `bounds` at paint/hit time (segmented_button pattern).
- **Header (120dp)**: title "Select date" (LabelLarge OnSurfaceVariant, pad
  24/16, top); headline = `formatDay` "EEE, MMM d" (HeadlineLarge
  **OnSurfaceVariant** — Compose token + matraic agree; the m3e-canvas oracle
  paints OnSurface: documented deviation); a 1dp OutlineVariant divider at
  y=119.
- **Nav row (56dp)**: month-year "MMMM yyyy" (LabelLarge OnSurfaceVariant) +
  chevron icon buttons (40dp hit, 24dp icons, OnSurfaceVariant, disabled at
  the 1900-01 / 2100-12 edges).
- **Weekday row (48dp)**: letters S M T W T F S (BodyLarge OnSurface).
- **Grid**: 6 rows x 48dp = 288dp; 40dp CornerFull cells, 7dp gaps
  (SpaceEvenly: cell x = 12+7+col*47, y = 224+row*48+4); selected = Primary
  circle + OnPrimary; today = 1dp Primary outline + Primary label; empty
  cells for the days outside the month (the modal grid shows NO
  adjacent-month days).
- **Footer**: Cancel / OK text buttons (LabelLarge Primary, CornerFull state
  layer, right-aligned, 8dp gap, 12dp pad, y=512).
- **State**: `selected: *Signal(?i64)` — a UTC epoch day (ALWAYS live in the
  registry; null round-trips); `displayed: *Signal(i64)` — the displayed
  month's first day (NOT live — initial only); `today: ?i64` option (null =
  `std.c.clock_gettime(REALTIME)` / 86400). Day tap selects (the signal
  round-trips); the chevrons page the displayed month; OK/Cancel fire
  `on_select` / `on_cancel`.
- **Civil calendar**: Hinnant algorithms with @divTrunc; weekday =
  `@mod(z+4, 7)` (1970-01-01 = Thursday = 4). Every helper is TOTAL: the input
  is clamped to the supported range (pub `min_epoch_day` = -25567 =
  1900-01-01, `max_epoch_day` = 47846 = 2100-12-31, `clampDay`) — no i64
  overflow for any input.
- **A11y**: role .group, label "Date picker", value = the headline,
  notifyControlChanged on change.
- **Pub helpers**: `selectedDay`, `displayedMonth`, `todayDay`,
  `firstOfMonthOf`, `dayCellRect`, `formatDay`.
- **v1 deviations**: no date-input mode, no range selection, no year picker
  (the month-year label is static), no docked variant, no swipe paging
  (chevron paging — the desktop idiom); en strings only; UTC dates (epoch
  days); headline OnSurfaceVariant (vs m3e-canvas OnSurface); no keyboard
  navigation within the grid yet.

### time_picker (`src/widgets/time_picker.zig`)

- A LEAF panel (skip_children): measures 360 x 464, paints all its chrome.
- **Header row (centered, y=16, 80dp tall)**: hour plate 96x80 CornerSmall 8
  + ":" separator 24dp (DisplayLarge OnSurface) + minute plate 96x80 +
  AM/PM vertical toggle 52x80 (1dp Outline border + 1dp divider; the selected
  half TertiaryContainer/OnTertiaryContainer, the unselected OnSurfaceVariant;
  TitleMedium; the half fills use `fillRRectCorners` — NO clipRRect in the
  ABI). The plates show DisplayLarge zero-padded 2 digits; the ACTIVE plate
  = PrimaryContainer + OnPrimaryContainer + 2dp Primary border; inactive =
  SurfaceContainerHighest + OnSurface.
- **Dial**: a 256dp SurfaceContainerHighest circle at y=132 (center 180,260);
  labels in 48dp cells (BodyLarge; 12h hour: 12,1..11 at 30° steps from the
  top; minute: 00,05..55; 24h hour: 00..11 on the outer 101dp ring + 12..23 on
  the inner 69dp circle); the knob: a 48dp Primary circle at the selected
  position (on the selected hour's ring); the track: a 2dp Primary line
  center → ring-24; the center dot: 8dp Primary. The selected label is drawn
  ON TOP of the knob (OnPrimary) — the unselected labels under the knob are
  covered (M3's BlendMode.Clear look).
- **Footer** at y=412 (total 464).
- **State**: `time: *Signal(i32)` — minutes since midnight, clamped 0..1439
  (ALWAYS live). The mode (hour/minute) is internal: tapping the plates
  switches it; tapping/dragging the dial selects by angle (hour: the nearest
  hour; minute: the nearest minute; 24h: the tap's radius picks the ring —
  >= MaxDistance 74dp → outer 0..11, closer → inner 12..23); tapping AM/PM
  flips the period (`@mod(h12,12)+12` for PM). `is_24h` option: no toggle, the
  hour plate shows 00..23, the dial is the dual ring.
- **A11y**: role .group, label "Time picker", value "10:30 PM" / "22:30".
- **Pub**: `dialMode`, `timeMinutes`, `dialRectOf`, `formatTime` (12h + AM/PM
  or 24h — the a11y value AND the gallery label).
- **v1 deviations**: no text-input variant, no auto-switch hour→minute after
  a selection; en strings only; no per-label hover; no keyboard navigation
  yet.

## Registry

- `date_picker` (input): `title` (string), `width` (number), `today`
  (number, optional) automatic; `selected` (number, ALWAYS-live, default
  .null — null round-trips); `displayed` (number, NOT live). skip_children.
  `selected` / `today` / `displayed` are clamped to the supported civil-date
  range; `displayed` is normalized to the month's 1st (`firstOfMonthOf`).
- `time_picker` (input): `is_24h` (toggle), `width` (number) automatic;
  `time` (number, ALWAYS-live, default 630, clamped 0..1439 at build AND on
  save). skip_children.
- New helpers in `src/registry.zig`: `buildOptI64Signal` /
  `readOptI64Signal` / `deinitOptI64Signal`, `deinitI64Signal`,
  `readI32Signal` / `deinitI32Signal`, `floatToInt` (the checked float→int
  conversion). 39 registry widgets.

## Gallery

- Sections "Date picker (M3E)" + "Time picker (M3E)"; signals
  `dp_selected` (?i64, init = today via `todayDay(null)`),
  `dp_displayed` (i64, the month of today), `dp_ok` (u32), `tp_time`
  (i32, 630), `tp_ok` (u32); helpers `fmtOptDay` / `fmtTime` / `dpOkCb` /
  `tpOkCb`; refs `dp_m3e` / `tp_m3e`; 2 gallery tests (a day tap and a dial
  tap round-trip through the signals).

## Zig 0.17 gotcha hit by this PR

`std.Io.Writer.printInt` (0.17) prints an explicit `+` for a positive SIGNED
int whenever a width spec is present (`{d:0>2}` on a runtime i32 → "+10");
the sign is omitted only without a width. comptime_int and unsigned args are
unaffected. Fix (repo convention, cf. `ui/i18n.zig`): cast the euclidean clock
fields to `u32` before formatting. Affected sites: the header plate labels,
the dial labels, `formatTime` (24h + 12h branches) — 6 sites, all fixed. The
a11y value tests ("10:30 PM") caught it.

## Review fixes (Devin, PR #33)

- **date_picker — a11y value buffer overflow + dangling title read**: the
  unselected a11y value now points at the OWNED `title_z` directly (a long
  title would not fit the 32-byte `value_buf`, and the options string is
  borrowed — never read it after construction). `value_len` is gone; the
  state holds `a11y_value: []const u8` (into `value_buf` or `title_z`).
- **date_picker — extreme epoch days overflow**: `civilFromDays` /
  `weekdayFromDays` clamp their input to the supported range first
  (`clampDay`, pub `min_epoch_day` = -25567 = 1900-01-01, `max_epoch_day` =
  47846 = 2100-12-31) — the helpers are total for ANY i64. The factory clamps
  `today`; the registry clamps `selected` / `today` / `displayed`.
- **registry — mid-month `displayed` shifted the weekday grid**: an explicit
  `displayed` is normalized with `firstOfMonthOf` (the grid's weekday column
  comes from the month's 1st) + clamped.
- **registry — huge floats trapped `@intFromFloat`**: a shared `floatToInt`
  helper checks the f64 bounds before converting (a finite float beyond i128
  would trap); all three float branches (selected, displayed, time) use it →
  `error.ValueOutOfRange` instead of a crash.
- **time_picker — 24h dial could not change periods**: the 24h hour dial is
  now the M3 dual ring (outer 00..11 at 101dp, inner 12..23 at 69dp); the
  tap's radius picks the ring (MaxDistance 74dp); `applyDialValue` uses the
  selected 0..23 directly.
- **time_picker — the knob hid the selected label**: the paint order is now
  unselected labels → track → knob → center dot → the selected label (OnPrimary
  on top of the knob).
- **registry — saved time ≠ visible time**: the time is clamped to 0..1439
  at build AND on save (`readI32Signal`) — the round-trip echoes what the
  picker displays.
- **gallery — the time label changed format**: the label uses the pub
  `formatTime` (12h + AM/PM — the same string the picker displays and
  announces); `formatTime12` is removed.

## Follow-ups

- Color picker (PR #34, the rest of 2d.4 — no official M3/M3E color picker
  exists; an M3E-styled framework-original is planned and documented as such).
- Date picker: input mode, range selection, year picker, swipe paging,
  keyboard grid navigation. Time picker: text-input variant, auto-switch,
  24h inner circle, keyboard dial navigation.
