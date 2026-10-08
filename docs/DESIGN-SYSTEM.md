# Design System — Material 3 Expressive

Decision record: [ADR-0010](adr/ADR-0010-design-system-m3e.md).
Spec source: [m3.material.io](https://m3.material.io) (M3E where published, M3 where M3E is silent).
Reference implementations: Jetpack Compose Material3 (primary), Flutter (partial M3E).

## The three layers

```
app overrides (branding)   ← the app's Theme value, token by token
        ↓
platform adaptation (ours) ← desktop density/hover/focus, mobile safe areas, hit targets
        ↓
M3E baseline (theme.zig)   ← Google's tokens: colors, type, shape, elevation, motion
```

- **M3E baseline** — `src/theme.zig`. Never edit per-widget; edit here.
- **Platform adaptation** — behavior only (never visuals): density scale, hover/focus/pressed state layers, keyboard focus rings, safe-area insets, 44/48px hit targets. Lives in the widget layer, keyed off platform.
- **App overrides** — an app builds its own `Theme` (copy `theme.light`/`theme.dark`, override fields) and passes it to widgets. This is where the Vehicoule app's own look lands.

## Token architecture (`src/theme.zig`)

```zig
Theme
├── name: []const u8
├── colors: ColorScheme        // 39 M3 roles, light + dark baseline schemes
├── type_scale: TypeScale      // 15 styles: display/headline/title/body/label × large/medium/small
├── shape: Shape               // corner radii: 4 / 8 / 12 / 16 / 28 (pill = height/2)
├── elevation: Elevation       // levels 0–5 as raster shadow approximations (dy, blur, alpha)
├── motion: Motion
│   ├── durations: Durations   // M3 scale: short1..long4 (50..600 ms)
│   ├── easings: Easings       // standard / emphasized families (cubic-bezier control points)
│   └── springs: Springs       // M3E presets: default (1400, ζ0.8), spatial (700, ζ0.8), effects (3800, ζ0.9)
├── state: StateLayers         // hover 0.08 / focus 0.10 / pressed 0.12 / drag 0.16
└── spacing: Spacing           // 4 / 8 / 12 / 16 / 24 / 32
```

Helpers: `theme.stateLayer(base, on, alpha)` (M3 state layer), `theme.relativeLuminance(c)` and `theme.contrastRatio(a, b)` (WCAG — used by tests and a11y tooling).

### Color roles (M3)

`primary`/`on_primary`/`primary_container`/`on_primary_container` — same for `secondary`, `tertiary`, `error`. Surfaces: `surface`, `surface_variant` + their `on_*`. Containers: `surface_container_lowest/low/(default)/high/highest`. Plus `outline`/`outline_variant`, `inverse_*`, `surface_tint`/`surface_bright`/`surface_dim`, `scrim`, `shadow`, and deprecated `background`/`on_background` (kept for completeness).

### Consumption rules for widgets

1. Every widget options struct has `theme: Theme = kx.theme.light` (apps pass their override).
2. No hardcoded colors, font sizes, radii, durations or springs — read them from `theme`.
3. Interaction states are M3 state layers: `theme.stateLayer(base, on_color, theme.state.hover)` etc. — never a second hardcoded "hover color".
4. Motion: springs from `theme.motion.springs.*` (via `anim.springAnim`), tweens from `theme.motion.durations.*` + `theme.motion.easings.*`.
5. Text styles come from `theme.type_scale.*` (size/line_height/weight/letter_spacing).
6. Semantic roles for a11y are attached in the factory (Phase 2c system), per the M3 a11y guidance of the component spec.

## Widget → spec mapping (Phase 2d P1 widgets)

| Widget | M3/M3E spec | Reference impl | Notes |
|---|---|---|---|
| AppBar | Top app bar (M3) | Compose `TopAppBar` | M3E has no separate app bar spec; M3E motion for scroll behavior |
| NavBar | Navigation bar (M3E, 2025) | Compose `NavigationBar` | Active indicator pill slides between items |
| Drawer | Navigation drawer (M3) | Compose `ModalNavigationDrawer` | Modal + scrim; side is start (RTL-aware); edge-swipe is app-level |
| Tabs | Tabs (M3) | Compose `TabRow` | Sliding underline indicator; optional pager swipe |
| BottomSheet | Bottom sheet (M3E) | Compose `ModalBottomSheet` | Drag handle, peek/half/full states, scrim |
| Dialog | Dialogs (M3) | Compose `AlertDialog` | Focus trap, scrim, Escape |
| ProgressIndicator | Progress indicators (M3E) | Compose `CircularProgressIndicator`/`LinearProgressIndicator` | Determinate = external signal; indeterminate needs a ticker |
| Badge | Badges (M3) | Compose `Badge` | Dot + large (with count) variants, top-end anchor |
| Tooltip | Tooltips (M3) | Compose `Tooltip` | Hover (desktop) / long-press (mobile), delayed |
| SnackBar | Snackbars (M3E, 2025) | Compose `Snackbar` | Host + `showSnackBar`, auto-dismiss, one visible |

## Gallery migration map (old placeholder → M3 role)

| Old token | M3 role |
|---|---|
| `bg` | `colors.surface` (window background) |
| `surface` (cards, header) | `colors.surface_container` |
| `surface_2` (wells, list items) | `colors.surface_container_high` |
| `text` | `colors.on_surface` |
| `text_dim` | `colors.on_surface_variant` |
| `accent` | `colors.primary` |
| `accent_hover` | `stateLayer(primary, on_primary, state.hover)` |
| `border` | `colors.outline_variant` |
| `danger` | `colors.error` |

## References

Pixel-perfect policy: **spec-identical, never bit-identical** — fonts, anti-aliasing and shadow rasterization differ cross-platform (Skia vs Canvas2D/WebGL); goldens assert structure + spec values (geometry, colors, motion curves, timings), never glyph bitmaps or exact frames.

| Need | Reference |
|---|---|
| Tokens / values | m3.material.io (spec) — encoded in `src/theme.zig` |
| Catalog + a11y + choreography | github.com/matraic/m3e (M3E Web Components, MIT — per-component source: layout math, state layers, motion, a11y) + Jetpack Compose Material3 (canonical behavior) |
| M3E motion (springs, loading indicator) + visual oracle | github.com/lnkiai/m3e-canvas (drawing code, live-demo screenshots, loading indicator ported from material-components-android, standard/expressive spring schemes to cross-check our presets) + Flutter |

Per widget: read the reference source **before** implementing; encode the extracted spec values in the widget's golden assertions. Both repos are MIT; we port behavior (TS/JS → Zig), never code, and re-tokenize every hardcoded value into `Theme`.

## No-code designer (Phase 2e)

Enabler landed in 2d-0.6: a serializable data model + widget registry (see `src/registry.zig`, `ui/value.zig`). The designer is a native desktop app built **with Klaxon** (dogfooding + showcase):

```
canvas (renders the designed tree with the REAL widgets → WYSIWYG by construction)
· palette (registry categories) · layers panel
· inspector — auto-generated from options structs via comptime introspection
  (@typeInfo field_names, the ADR-0001 argument in action)
· M3E theme panel — the 4 axes: color / shape / type / motion (all tokenized)
· preview — tap-through transitions via the navigator, motion via Timeline
· export — runtime JSON (no codegen) + Zig source; the generated code is
  golden-tested (render both trees, diff pixels)
```

OEM/alternative looks (Samsung, Oppo, the product's own taste) are **configurations of the data model** (options + theme overrides), never forks. IA inspired by m3e-canvas (palette / inspector / layers / theme panel / preview).

## Roadmap notes

- **Dynamic color** (HCT tonal palettes from a seed/wallpaper) is a later addition; `ColorScheme` isolates it.
- **P0 widget migration**: the 34 P0 widgets keep hardcoded fixture colors until migrated to tokens — tracked in ROADMAP (batches 2d.2-2d.4 replace them). P1 widgets are the first token-consuming components.
- **Desktop adaptation layer** (2d-0.5): `Theme.platform` tokens — control heights (48 mobile / 32-40 desktop), spacing scale, hit targets, scrollbar style (overlay / classic / auto-hide), focus ring, cursors. Behavior borrowed from HIG/Fluent/GTK — never their visuals.
