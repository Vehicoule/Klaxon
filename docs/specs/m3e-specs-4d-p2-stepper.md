# M3E specs — 4d P2: Stepper

Sources: M3 `m3.material.io` (no official stepper), Compose Material3
(no stepper), Material Web (MWC stepper), iOS (no native), Flutter
(stepper package), M3E token system.

## Design

A horizontal step indicator: numbered circles connected by lines,
with labels below each circle. Three states per step: completed
(check icon, Primary), active (number, Primary), upcoming (number,
SurfaceContainerHighest + OnSurfaceVariant).

## Tokens

| Token | Value | Used for |
|---|---|---|
| Step circle | 24dp | circle diameter |
| Active/completed fill | `Primary` | active + completed circles |
| Upcoming fill | `SurfaceContainerHighest` | upcoming circles |
| Active/completed content | `OnPrimary` | number/check color |
| Upcoming content | `OnSurfaceVariant` | upcoming number |
| Connector | 1dp `Primary` (completed) / `OutlineVariant` (upcoming) | lines between steps |
| Label | BodySmall / `OnSurface` (active) / `OnSurfaceVariant` (upcoming) | step labels |
| Spacing | 8dp between circle and label | vertical gap |
| Step min width | 80dp | each step's column |

## Layout

```
  ┌────┐      ┌────┐      ┌────┐
  │ ①  │──────│ ②  │──────│ ③  │
  └────┘      └────┘      └────┘
  Label A     Label B     Label C
```

- Each step: a column (circle + 8dp gap + label).
- Connectors: horizontal 1dp lines between adjacent circles, vertically
  centered on the circles.
- Total width: steps * min_width (or intrinsic if wider).

## State

- `current: *Signal(usize)` — the active step index (0-based). ALWAYS live.
- Steps with index < current: completed (check).
- Step at index == current: active (number, Primary).
- Steps with index > current: upcoming (number, muted).

## Interaction

- Non-interactive by default (a display element).
- Optional: tapping a step sets `current` to that index.

## Semantics (a11y)

- role: `.group`, label "Stepper"
- Per step: role `.list_item`, label = step label, value = "completed"/"active"/"upcoming"

## Registry

- `stepper` (category `navigation`): `current` (number, live signal),
  `steps` (array of {label} objects). skip_children.

## v1 deviations

- Horizontal only (vertical = follow-up).
- No connector animation (instant color change).
- No error state (a step can show an error icon).
- No optional steps (skippable).

## Follow-ups

- Vertical orientation.
- Error state per step.
- Optional/skippable steps.
- Animated connector fill.
