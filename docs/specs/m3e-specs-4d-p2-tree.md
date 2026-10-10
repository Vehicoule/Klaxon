# M3E specs — 4d P2: Tree (expandable tree view)

Sources: no official M3 tree. Cross-referenced with Flutter `ExpansionTile`
+ tree views, Material Web (no tree), VS Code explorer, M3E tokens.

## Design

A tree view: nodes with optional children, expandable/collapsible.
Each node row: chevron (if has children) + label. Indentation per level.

## Tokens

| Token | Value | Used for |
|---|---|---|
| Container | `Surface` | tree background |
| Row height | 48dp | node row |
| Indent | 24dp | per level |
| Chevron | 24dp icon, `OnSurfaceVariant` | expand/collapse |
| Label | BodyMedium / `OnSurface` | node label |
| Hover | `OnSurface` @ 0.08 | row hover (tappable) |
| Selected | `SecondaryContainer` fill | selected node |

## Layout

```
▼ Documents          ← level 0, expanded
   ▶ Projects       ← level 1, collapsed
   ▼ Music          ← level 1, expanded
      ▶ Rock        ← level 2
      ▶ Jazz        ← level 2
▶ Downloads          ← level 0, collapsed
```

## State

- Tree data: recursive nodes (label + optional children).
- Expanded state: per-node bool (internal, not a signal in v1).
- Selected node: optional Signal(usize) — flat index of the selected node.

## Interaction

- Tap chevron: toggle expanded.
- Tap label: select (if tappable) + toggle expanded (if has children).
- Keyboard: Enter/Space toggles, arrows navigate (follow-up).

## Semantics (a11y)

- role: `.group`, label "Tree"
- Per node: role `.list_item`, label = node label, value = "expanded"/"collapsed"

## Registry

- `tree` (category `navigation`): `nodes` (nested array of {label, children?}).
  skip_children.

## v1 deviations

- No keyboard navigation.
- No lazy loading (all nodes in memory).
- No drag-and-drop reordering.
- No icons per node (chevron only).

## Follow-ups

- Keyboard navigation (arrows, enter).
- Lazy loading (async children).
- Custom icons per node.
- Drag-and-drop.
