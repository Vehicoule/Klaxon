# M3E specs — 4d P2: ExpansionPanel

Sources: Jetpack Compose Material3 `ExpansionPanel` / `ExpansionPanelList`
(experimental), Material Web (MWC) `expansion-panel`, M3E token system.

## Design

A collapsible panel: a tappable header (title + chevron) that expands
to reveal its child content. Driven by an external `Signal(bool)`.

## Tokens

| Token | Value | Used for |
|---|---|---|
| Container | `SurfaceContainer` | panel background |
| Shape | CornerMedium (12dp) | panel corners |
| Header height | 48dp | the tappable header row |
| Header padding | 16dp start/end | title + chevron padding |
| Title | TitleMedium / `OnSurface` | header title |
| Chevron | 24dp icon, `OnSurfaceVariant` | expand/collapse indicator |
| Divider | 1dp `OutlineVariant` | between header and content (expanded) |
| Content padding | 16dp | inner padding around the child |
| State layer | hover 0.08 / pressed 0.12 over `OnSurface` | header tap feedback |

## Layout

```
┌────────────────────────────┐  ← panel (SurfaceContainer, CornerMedium 12)
│  Title               ▼    │  ← header (48dp, tappable)
├────────────────────────────┤  ← 1dp OutlineVariant divider (expanded only)
│                            │
│  [child content]           │  ← content (16dp padding, visible when expanded)
│                            │
└────────────────────────────┘
```

- Collapsed: total height = header_h (48dp).
- Expanded: total height = header_h + 1 (divider) + 16 + content_h + 16.

## State

- `expanded: *Signal(bool)` — ALWAYS live, round-trips.
- Chevron rotation: 0° (collapsed) → 180° (expanded). v1: instant.

## Interaction

- Click on the header toggles `expanded`.
- Keyboard: Enter/Space on the focused header toggles.
- State layers on the header (hover/pressed).

## Semantics (a11y)

- The header: role `.button`, label = title, value = "expanded"/"collapsed".
- `expanded` attribute synced with the signal.
- `notifyControlChanged` on toggle.

## Registry

- `expansion_panel` (category `layout`): `title` (text), `expanded`
  (toggle, live signal). The child is a document child (the content).

## v1 deviations

- Instant expand/collapse (animated height = Phase 3).
- No disabled state.
- Single panel (no ExpansionPanelList accordion behavior).

## Follow-ups

- Animated height (spring).
- Disabled state.
- Accordion mode (ExpansionPanelList: only one expanded at a time).
