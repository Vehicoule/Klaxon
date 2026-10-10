# M3E specs — 4d P2: Calendar (inline)

Sources: M3 date picker (m3.material.io/components/date-pickers),
reuses the date_picker's civil calendar helpers. The Calendar is the
inline (non-modal) variant: always visible, no OK/Cancel footer.

## Design

A calendar month view: header (month-year + prev/next chevrons),
weekday row, day grid (6 rows × 7 columns). Inline = always visible.

## Tokens (same as date_picker)

| Token | Value |
|---|---|
| Container | `SurfaceContainer` (inline, lower than modal's SurfaceContainerHigh) |
| Shape | CornerMedium (12dp) |
| Width | 280dp (narrower than modal's 360dp) |
| Header height | 56dp (month-year + chevrons) |
| Weekday row | 40dp |
| Day cells | 36dp, 4dp gaps |
| Selected day | Primary circle + OnPrimary |
| Today | 1dp Primary outline + Primary label |
| Unselected | OnSurface |

## State

- `selected: *Signal(?i64)` — UTC epoch day (null = no selection).
- `displayed: *Signal(i64)` — the displayed month's first day.

## Interaction

- Tap a day → selects it (signal round-trips).
- Chevrons page the month.
- Keyboard: arrows move the selection (follow-up v1).

## Registry

- `calendar` (category `input`): `selected` (number, live), `displayed`
  (number, not live). skip_children.

## v1 deviations

- No keyboard navigation in the grid.
- No range selection.
- en month/weekday names only.
- UTC dates.

## Follow-ups

- Keyboard grid navigation.
- Range selection.
- Year picker.
