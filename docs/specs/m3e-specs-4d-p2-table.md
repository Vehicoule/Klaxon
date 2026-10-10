# M3E specs — 4d P2: Table (data table)

Sources: M3 data table (m3.material.io), Compose Material3 (no table),
Material Web (MWC data-table), Flutter DataTable, M3E tokens.

## Design

A data table: a header row (column titles) + data rows (cells).
Each cell contains text. Row separators between rows.

## Tokens

| Token | Value | Used for |
|---|---|---|
| Container | `Surface` | table background |
| Header fill | `SurfaceContainerHighest` | header row background |
| Header text | TitleSmall / `OnSurface` | column titles |
| Cell text | BodyMedium / `OnSurface` | data cells |
| Row separator | 1dp `OutlineVariant` | between rows |
| Cell padding | 16dp horizontal, 12dp vertical | cell content inset |
| Row height | 52dp | data row height |
| Header height | 56dp | header row height |
| Column min width | 80dp | minimum column width |
| Hover state | `OnSurface` @ 0.08 | row hover (when tappable) |

## Layout

```
┌──────────┬──────────┬──────────┐  ← header (56dp, SurfaceContainerHighest)
│  Name    │  Age     │  City    │
├──────────┼──────────┼──────────┤  ← 1dp OutlineVariant
│  Alice   │  30      │  Paris   │  ← row (52dp)
├──────────┼──────────┼──────────┤
│  Bob     │  25      │  Lyon    │
└──────────┴──────────┴──────────┘
```

- Columns: equal width by default, or weighted by content.
- Total width: sum of column widths (min 80dp each).
- Total height: header_h + rows * row_h.

## State

- Data is passed at construction (columns + rows).
- No live signal (v1: static data). Sorting/selection = follow-ups.

## Interaction

- Non-interactive by default.
- Optional: tapping a row fires `on_row_tap(row_index)`.
- Hover state on rows (when tappable).

## Semantics (a11y)

- role: `.group`, label "Data table"
- Per row: role `.list_item`, label = concatenation of cell values

## Registry

- `table` (category `display`): `columns` (array of strings),
  `rows` (array of arrays of strings). skip_children.

## v1 deviations

- No sorting, no column resizing, no row selection.
- No scroll (table must fit; virtualization = Phase 3).
- No sticky header.
- Text only (no widgets in cells).

## Follow-ups

- Sortable columns (click header to sort).
- Row selection (checkbox column).
- Scrollable with sticky header.
- Widget cells (not just text).
- Column resizing.
