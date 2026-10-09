# Roadmap — Klaxon Framework

> v1 means everything. All platforms, the full Material 3 Expressive widget catalog (~65 widgets), full testing, DevTools + the no-code designer, packaging, CLI. No V1/V2 split for features. V2 items are explicitly listed below.

## Phase 0 — Foundations (1 week)

**Goal**: `zig build` works on a clean machine. Hello-world renders.

**Dev host**: macOS arm64 (the dev machine). Linux x64 is verified in CI (GitHub runner); the Linux GPU shim lands in Phase 3a. The raster backend doubles as a headless backend for golden tests (no GPU needed in CI).

| # | Task | Deliverable |
|---|---|---|
| 0.1 | `scripts/fetch-deps.sh` — clone + build Skia (pin 8643b1d6), SDL3 (pin 3.2.16), WAMR (pin 2.4.4) into `deps/` | Reproducible deps |
| 0.2 | `build.zig` — compile hello-world (raster backend, simplest) | `zig build run` opens a window with text |
| 0.3 | `kx_skia_common.cpp` + `kx_skia_platform.h` — factorized shim | Shared C++ code, platform interface |
| 0.4 | `kx_skia_macos.mm` — macOS impl (Metal + raster) | GPU + raster on the dev host |
| 0.5 | `ui/node.zig` + `ui/paint.zig` + `ui/layout.zig` | Core UI: retained tree, two-pass layout, paint |
| 0.6 | `host.zig` — window, event loop (dirty-flag, 0-frame idle), stats | Lifecycle works |
| 0.7 | CI: GitHub Actions (build + test on macOS + Linux runners) | Green CI |

**Exit criteria**: `zig build run` on macOS shows a window with rendered text. `zig build test` passes. CI green on macOS + Linux.

---

## Phase 1 — Widgets + Core Systems (3-4 weeks)

**Goal**: 50 widgets, state management, gestures, animations, scroll. Gallery is a full showcase.

### 1a. State management (week 1)

| # | Task | Deliverable |
|---|---|---|
| 1a.1 | `ui/state.zig` — `Signal(T)`, `Memo(T)`, `Effect` | Fine-grained reactivity |
| 1a.2 | Dependency tracking (current_builder context) | Widget auto-subscribes on read |
| 1a.3 | `Store(T)` — global signal registry | Cross-widget shared state |
| 1a.4 | Unit tests: signal set/get, memo recompute, effect run | `zig build test` green |

### 1b. Widgets P0 — Layout + Basics (week 1-2)

| Widget | File | Tests |
|---|---|---|
| Row, Column, Stack, Grid | `widgets/layout.zig` | unit + golden |
| Padding, Center, Align, ConstrainedBox | `widgets/layout.zig` | unit + golden |
| Text, RichText | `widgets/text.zig` | unit + golden (CJK/RTL/emoji land with i18n, Phase 2b) |
| Icon | `widgets/icon.zig` | unit + golden |
| Image | `widgets/image.zig` | unit + golden |
| Container (bg + border + radius + padding) | `widgets/container.zig` | unit + golden |
| Divider | `widgets/divider.zig` | unit + golden |

### 1c. Widgets P0 — Input (week 2)

| Widget | File | Tests |
|---|---|---|
| Button, Toggle, Checkbox, Radio, Slider, Dropdown, Chip | `widgets/input.zig` | unit + golden + state |
| TextField | `widgets/input.zig` | unit + golden + focus/editing (IME lands with i18n, Phase 2b) |

### 1d. Gestures (week 2-3)

| # | Task | Deliverable |
|---|---|---|
| 1d.1 | `ui/gestures.zig` — GestureArena | Conflict arbitration |
| 1d.2 | Recognizers: tap, double-tap, long-press | Unit tests |
| 1d.3 | Recognizers: pan, swipe/fling (velocity threshold) | Unit tests |
| 1d.4 | Recognizers: pinch (scale), rotate | Multi-touch via SDL3 FINGER_* |
| 1d.5 | `GestureDetector` widget wrapper | Widgets use gestures declaratively |
| 1d.6 | Slop (12dp), velocity (500dp/s) thresholds | Tuned constants |

### 1e. Animations (week 3)

| # | Task | Deliverable |
|---|---|---|
| 1e.1 | `ui/anim.zig` — Spring (stiffness, damping, mass) | M3E physics |
| 1e.2 | `ui/anim.zig` — Tween (linear, ease-in-out, custom curve) | Driven interpolation |
| 1e.3 | SIMD `@Vector` interpolation (4 properties at once) | Perf |
| 1e.4 | Timeline scheduler (240 Hz tick, staggered) | Multiple concurrent anims |
| 1e.5 | `Animated<T>` widget wrapper (implicit animations) | `AnimatedContainer`, `AnimatedOpacity`, etc. |
| 1e.6 | Dirty-rect (redraw only moving regions) | Anti-jank |
| 1e.7 | Frame budget (skip lowest-priority anim if > 8.3ms) | Anti-jank |

### 1f. Widgets P0 — Scroll (week 3-4)

| Widget | File | Tests |
|---|---|---|
| ListView (virtualized) | `widgets/list_view.zig` | unit + golden + perf (10k items) |
| GridView (virtualized) | `widgets/grid_view.zig` | unit + golden |
| ScrollView | `widgets/scroll_view.zig` | unit + golden |
| Scrollbar | `widgets/scrollbar.zig` | unit + golden |

### 1g. Gallery (week 4) — DONE (PR #9)

Full showcase: all 31 widgets, themes (dark/light, live toggle), animations, gestures, scroll 10k, TextField. (IME lands with i18n, Phase 2b.)

**Exit criteria Phase 1: MET.** Gallery runs on Linux (CI headless smoke, 600 frames) and on the dev Mac (`zig build gallery`). 31 widgets functional. State, gestures, animations work. `zig build test` (170) + `zig build test-golden` (29) green. Scroll 10k virtualized (~7 live nodes); on-device 120fps p99 gates land with the Phase 4 device matrix.

---

## Phase 2 — Design system + Nav + i18n + A11y + M3E Widget Catalog + Designer (6-8 weeks)

**Goal**: the full Material 3 Expressive catalog as the v1 widget bar (~65 widgets), the platform-adaptation token layer, and the no-code designer enabler. One visual language (M3E), platform behavior borrowed from HIG/Fluent/GTK, app branding via token overrides.

### 2a. Navigation (week 1) — DONE (PR #11)

Page stack (declarative routes `anime/{id}` + params, imperative
push/pop/replace/popToRoot), transitions (slide, slide_up, fade, scale,
none — 300 ms M3 standard tween, parallax, interrupted-transition snap),
hero shared-element flights, deep links (`klaxon://anime/42?tab=2`, cold
start), back (Android hardware button / desktop Escape via the router's back
handler). `ui/navigator.zig` + `widgets/navigator.zig` (NavigatorView +
Hero) + `docs/NAVIGATION.md` + kx ABI 0.4.0 (`kx_layer_alpha` for fades).
Demo: `zig build navigator` (CI headless smoke, 600 scripted frames).
Widgets 33/50.

### 2b. i18n (week 1) — DONE (PR #12)

`ui/i18n.zig` — `I18n` registry (ARB locales, `tr` fallback chain, `{name}`
interpolation from a comptime args struct), ARB plural blocks with CLDR
rules (en/fr/ja/ar), number/date formatting (per-locale tables), and the
process-global direction. RTL mirrors automatically: `TextAlign.start/end`,
`Alignment.mirrored`, `EdgeInsetsDirectional`, horizontal flex main-axis
reversal. Runtime switching via the locale signal (`setLocale` → widgets
re-resolve + re-measure; a direction flip fires `on_direction_changed`).
Widgets: `l10nText`, `L10nText(Args)`, `l10nPlural`, `l10nPluralSig`
(`widgets/i18n.zig`) + `paddingDir` (`widgets/layout.zig`). Demo:
`zig build i18n` (4 locales @embedFile, scripted switches, CI headless
smoke). `docs/I18N.md`. Widgets 34/50.

### 2c. Accessibility (week 2) — DONE (PR #13)

`ui/semantics.zig` — `Semantics` per-node descriptor (role, label, hint,
value, checked, actions) attached by the widget factories; semantic tree
flatten (transparent containers lifted, label fallback, `exclude_semantics`
hides decorative subtrees); `FocusManager` (Tab/Shift+Tab focus order,
Enter/Space activation, `focused_sig`); focus ring painted by the host;
live regions (`announce`); `SemanticsBridge` (C ABI, ADR-0009) with a
`LogBridge` default. Keyboard: `Key.up/down/space` + `KeyEvent.shift`;
the host routes Tab to the focus manager and falls back to semantic
activation. Widgets carry roles (Text/Button/Toggle/Checkbox/Radio/Slider/
TextField/Chip/Icon/Image); signal-driven widgets keep `checked`/`value`
in sync. Demo: `zig build a11y` (CI headless smoke, scripted keyboard).
`docs/A11Y.md`. Widgets 34/50.
**Note**: the AT-SPI/D-Bus bridge (Linux) lands with the Linux target
(Phase 3a) — the bridge interface is ready; it needs a session bus + the
AT-SPI registry daemon (absent on the dev Mac).

### 2d-0. Design tokens — Material 3 Expressive (prerequisite) — DONE (PR #14)

- `src/theme.zig` rewritten: full M3E token set (ColorScheme light/dark M3 baselines, TypeScale, Shape, Elevation, Motion with M3E spring presets, StateLayers, Spacing). Decision: ADR-0010; reference + widget → spec mapping: `docs/DESIGN-SYSTEM.md`.
- `ui/anim.zig`: `Spring.fromDampingRatio` (M3E stiffness + damping-ratio spec parameterization → engine k/c).
- Gallery migrated to M3 roles; state layers replace hardcoded hover colors.
- P1 widgets consume tokens (`theme: Theme` in the options struct, default `theme.light`); P0 widgets migrate progressively.

### 2d-0.5. Platform adaptation tokens (desktop density) — DONE (PR #18 tokens, #19 scrollbar styles, #20 cursors, #21 focus ring + gallery density switch)

M3E is mobile-first; the desktop gap is filled by a token layer, never by per-widget
decisions: `Theme.platform` — control heights (48 mobile / 32-40 desktop), spacing scale,
hit targets, scrollbar style (overlay macOS-style / classic / auto-hide), focus ring,
cursors. Behavior borrowed from Apple HIG / Fluent / GTK (libadwaita) — never their
visuals. Refines the P0 Scrollbar (overlay + auto-hide).

### 2d-0.6. Widget registry + serialization (no-code enabler) — DONE (PR #15)

- `ui/value.zig`: serializable `Value` model (null/bool/int/float/string/array/object) +
  JSON (std.json) + comptime adapters `optionsFromValue` / `valueFromOptions` (typed
  options ↔ data, defaults applied, unknown fields ignored) + `schemaOf` (options type →
  inspector schema: field → editor kind).
- `src/registry.zig`: `WidgetEntry` registry (name, category, build), `BuildCtx` (owns
  designer-created signals + per-node option snapshots), `treeFromValue` / `treeToValue` /
  `treeFromJson` / `treeToJson`. Snapshot-based describe: zero changes to existing widgets.
- Registry v1: layout (column/row/padding/center/constrained_box) + display
  (divider/text/icon) + input (button/toggle/checkbox/slider). Batch 1+ widgets
  self-register.
- Purpose: the no-code designer (Phase 2e) manipulates this data model; the framework
  renders it with the real widgets (WYSIWYG by construction).

### 2d.1. Widgets P1 — Navigation + Feedback (batch 1) — DONE (PR #16 + PR #17, 10/10)

| Widget | File | Status |
|---|---|---|
| AppBar | `widgets/app_bar.zig` | DONE (PR #16) |
| NavBar | `widgets/nav_bar.zig` | DONE (PR #16) |
| Drawer | `widgets/drawer.zig` | DONE (PR #16) |
| Tabs | `widgets/tabs.zig` | DONE (PR #16) |
| BottomSheet | `widgets/bottom_sheet.zig` | DONE (PR #17) |
| Dialog | `widgets/dialog.zig` | DONE (PR #17) |
| ProgressIndicator (linear/circular) | `widgets/progress.zig` | DONE (PR #17) |
| Badge | `widgets/badge.zig` | DONE (PR #17) |
| Tooltip | `widgets/tooltip.zig` | DONE (PR #17) |
| SnackBar | `widgets/snackbar.zig` | DONE (PR #17) |

Design validated with the product owner (`docs/DESIGN-SYSTEM.md`). OEM ideas (Samsung /
Oppo navbars etc.) are absorbed as options/variants — never as a second visual language
(e.g. NavBar `indicator_style: .pill | .underline | .dot`, free item count, configurable
height); a strong enough pattern is promoted to a framework variant.

### 2d.2. Widgets — Inputs M3E (batch 2) — IN PROGRESS (PR A / B1 / B2 / C1 DONE — PR #22 / #23 / #24 / #25, 55 widgets today; PR C2: text fields next)

Buttons ×5 (elevated / filled / filled-tonal / outlined / text) — DONE (PR #22, M3E:
5 variants x 5 sizes XS-XL, state layers, shape morph, RTL, clipped label ink), icon
buttons ×4 — DONE (PR #23, M3E: 4 variants x 5 sizes x 3 widths, plain + toggle),
checkbox / radio / switch / slider M3E — DONE (PR #24: checkbox 18dp box + checkmark
polyline + error variant, radio group = shared signal, switch 52x32 pill + handle
16/24/28, slider M3E 16dp track + 4x44 bar thumb + gesture arbitration), chips ×5
(assist / elevated / filter / input / suggestion) — DONE (PR #25, M3E: h=32, radius 8,
outline 1dp, selected = SecondaryContainer, the filter check follows the selected
state, 48dp per-axis hit target, RTL mirror, clipped ink), text fields (outlined /
filled) — replacing the P0 fixtures. Self-register.

### 2d.3. Widgets — Surfaces & display (batch 3) — PLANNED

Cards ×3 (elevated / filled / outlined), lists, menus M3E, search bar, navigation rail,
side sheets, pull-to-refresh, segmented + split buttons.

### 2d.4. Widgets — Pickers + M3E extras (batch 4) — PLANNED

Date/time pickers, the M3E shape-morphing loading indicator (reference: m3e-canvas ports
it from material-components-android), color picker.

### 2e. Designer — no-code UI builder — PLANNED (v1 after 2d.2)

Native desktop app built WITH Klaxon (dogfooding + showcase): canvas (WYSIWYG — the tool
renders the designed tree with the real widgets), widget palette, layers panel,
auto-generated inspector (comptime introspection of options structs), M3E theme panel
(color / shape / type / motion), preview with transitions. Export: runtime JSON (no
codegen) + Zig source (`pub fn build(allocator) !*Node`) — the generated code is
golden-tested (render both trees, diff pixels). IA inspired by m3e-canvas. Architecture +
references: `docs/DESIGN-SYSTEM.md`.

**References** — pixel-perfect policy: **spec-identical, never bit-identical** (fonts, AA
and shadow rasterization differ cross-platform; goldens assert structure + spec values).

| Need | Reference |
|---|---|
| Tokens / values | m3.material.io (spec) — encoded in `src/theme.zig` |
| Catalog + a11y + choreography | github.com/matraic/m3e (M3E Web Components, MIT) + Jetpack Compose Material3 (canonical) |
| M3E motion (springs, loading indicator) + visual oracle | github.com/lnkiai/m3e-canvas (drawing code + live-demo screenshots; loading indicator ported from material-components-android) + Flutter |

**Exit criteria Phase 2**: Navigation works — DONE (2a). i18n works — DONE (2b). A11y core (semantic tree, keyboard focus, live regions) — DONE (2c); the AT-SPI bridge lands with Linux (Phase 3a). M3E design tokens — DONE (2d-0, PR #14). Platform adaptation tokens (2d-0.5). Widget registry + serialization (2d-0.6, PR #15). Full M3E catalog ~65 widgets (batches 2d.1-2d.4; 55 today — the v1 bar reached: 2d.1 DONE (PR #16 + #17), 2d.2 PR A/B1/B2/C1 DONE (buttons, icon buttons, selection controls, chips — PR #22/#23/#24/#25); the catalog continues: 2d.2 PR C2 text fields, then 2d.3-2d.4). No-code designer v1 (2e).

---

## Phase 3 — Multi-platform (2-3 weeks)

### 3a. Linux (x64 + arm64)

| # | Task |
|---|---|
| 3a.1 | `kx_skia_linux.cpp` — EGL + Vulkan (fallback ganesh-gl). Raster path already works from Phase 0. |
| 3a.2 | Packaging: AppImage, .deb, .rpm, Flatpak |
| 3a.3 | CI: Linux runner builds + tests (native) |
| 3a.4 | Device test: remote Linux machine via `gates/device.sh ssh-linux` |

### 3b. macOS packaging + a11y (arm64 only — no x64)

Rendering shim done in Phase 0. Remaining:

| # | Task |
|---|---|
| 3b.1 | `kx_a11y.mm` — NSAccessibility bridge |
| 3b.2 | `kx_metal.mm` — ObjC bridge polish (device, queue, layer, drawable) |
| 3b.3 | Packaging: .app bundle, .dmg |
| 3b.4 | CI: build + test on macOS runner (green since Phase 0) |

### 3c. Windows (x64)

| # | Task |
|---|---|
| 3c.1 | `kx_skia_win.cpp` — Dawn D3D12 primary, Vulkan fallback, GL last |
| 3c.2 | `kx_a11y_win.cpp` — UIA bridge |
| 3c.3 | `host.zig` — Windows window (SDL + Dawn) |
| 3c.4 | Packaging: .exe portable, .msi (WiX) |
| 3c.5 | CI: build + test on Windows runner |
| 3c.6 | Device test: remote Windows machine via `gates/device.sh ssh-windows` |

### 3d. Android (arm64 + x64, split ABI)

| # | Task |
|---|---|
| 3d.1 | `kx_skia_android.cpp` — GLES + Vulkan (API ≥ 33) |
| 3d.2 | `kx_a11y_android.cpp` — TalkBack bridge (JNI) |
| 3d.3 | `host.zig` — Android lifecycle (pause/resume/low-memory) |
| 3d.4 | CMake + Gradle integration |
| 3d.5 | Packaging: .apk (arm64), .apk (x64), .aab |
| 3d.6 | CI: build APK on Linux runner (NDK cross-compile) |
| 3d.7 | Device test: local emulator + retail phone via `gates/device.sh android-emu` / `android-device` |

### 3e. iOS (arm64)

| # | Task |
|---|---|
| 3e.1 | `kx_skia_ios.mm` — Metal backend |
| 3e.2 | `kx_a11y_ios.mm` — UIAccessibility bridge |
| 3e.3 | `host.zig` — iOS lifecycle |
| 3e.4 | Packaging: .ipa (TestFlight) |
| 3e.5 | CI: build on macOS runner (xcodebuild) |
| 3e.6 | Device test: local iOS Simulator via `gates/device.sh ios-sim` |

### 3f. Web (WASM)

| # | Task |
|---|---|
| 3f.1 | `kx_skia_wasm.cpp` — WebGL2/WebGPU via emscripten |
| 3f.2 | `kx_a11y_wasm.cpp` — ARIA (hidden DOM) |
| 3f.3 | `host.zig` — WASM event loop (canvas, rAF) |
| 3f.4 | Packaging: .wasm + .html + .js |
| 3f.5 | CI: build WASM on Linux runner |

**Exit criteria Phase 3**: Gallery runs on all 6 platforms. CI green on all. Packaging works for each.

---

## Phase 4 — DevTools + Testing + Benchmarks (2 weeks)

### 4a. DevTools

| # | Task |
|---|---|
| 4a.1 | Overlay: FPS graph, frame time, draw calls, RSS, allocs/frame, backend info |
| 4a.2 | Inspector: interactive widget tree, property view, bounds highlight |
| 4a.3 | Memory ledger: RSS per subsystem graph |
| 4a.4 | Frame timeline: layout / record / submit / present breakdown |
| 4a.5 | Activation: F12 (desktop), 3-finger tap (mobile), `--devtools` flag |

### 4b. Testing — complete the 4 levels

| # | Task |
|---|---|
| 4b.1 | Unit: all modules covered |
| 4b.2 | Widget: every catalog widget has widget tests |
| 4b.3 | Golden: every catalog widget × 3 backends (Linux) |
| 4b.4 | Integration: `gates/device.sh` — full device matrix (below) | On-device metrics |

**Device matrix** (integration tests + device-tier perf gates):

| Target | Location | Access | Used for |
|---|---|---|---|
| macOS arm64 (dev host) | local | `zig build run` | Dev loop, goldens (raster), perf gates (Metal) |
| iOS Simulator | local (dev Mac) | `xcrun simctl` + `gates/device.sh ios-sim` | iOS integration + gates (proxy) |
| Android Emulator | local (dev Mac) | `emulator` + `adb` + `gates/device.sh android-emu` | Android integration |
| Android phone (retail, Adreno 750) | USB, when available | `adb` + `gates/device.sh android-device` | Reference device gates (fps p99 ≥ 120, RSS < 40 Mo) |
| Linux x64 machine | remote (ssh) | `gates/device.sh ssh-linux` | Linux GPU gates + packaging |
| Windows x64 machine | remote (ssh) | `gates/device.sh ssh-windows` | Windows gates + packaging |
| CI runners (GitHub Actions) | cloud | push | Linux/Windows/macOS build+test, Android emulator, headless goldens (raster) |
| 4b.5 | CI: all 4 levels run on every commit |

### 4c. Benchmarks

| # | Task |
|---|---|
| 4c.1 | 9 canonical scenes (hello, scroll_10k, text_cjk, glass_blur, anim_100, gallery, resize, input_ime, video_playback) |
| 4c.2 | Metrics collector (fps, frame time, draw calls, RSS, TTFF, binary size) |
| 4c.3 | `klaxon bench` command — runs all scenes, outputs JSON |
| 4c.4 | Runners for Flutter, Qt, Compose (same scenes, same metrics) |
| 4c.5 | Report generator (HTML comparison table) |
| 4c.6 | Published results (JSON in repo + HTML report) |
| 4c.7 | **Klaxon Conformance Suite** — behavioral conformance spec (layout rules, gesture semantics, text shaping, a11y roles, i18n/RTL rules) + runner that scores ANY UI framework against it. Research 2026-10: no cross-framework UI conformance suite exists (WPT is web-only; Appium/Espresso/XCUITest are per-platform E2E). Klaxon publishes the spec + scores for Klaxon, Flutter, Qt, Compose — the WPT ambition for UI frameworks. | Public conformance report |

### 4d. Widgets — advanced extras

The advanced widgets (Table, Tree, Calendar, DatePicker, ColorPicker, Avatar, Card, ExpansionPanel, Stepper, SegmentedControl, SearchBar, Menu) are folded into the M3E catalog batches (2d.2-2d.4). Anything not in the M3E families lands here.

**Exit criteria Phase 4**: DevTools work on Linux. Golden suite green for the full catalog. Benchmarks published (Klaxon vs Flutter vs Qt vs Compose). Catalog complete (2d.1-2d.4). Designer v1 (2e).

---

## Phase 5 — Packaging + CLI + Docs (2 weeks)

### 5a. CLI

| Command | Description |
|---|---|
| `klaxon create <name>` | Scaffold a new project from template |
| `klaxon run` | Build + run (debug) |
| `klaxon build` | Build release (ReleaseSmall) |
| `klaxon test` | Run all tests |
| `klaxon test-golden` | Run golden tests |
| `klaxon bench` | Run benchmarks |
| `klaxon package` | Package for current platform |
| `klaxon doctor` | Check environment (zig, deps, SDKs) |
| `klaxon gallery` | Run the demo gallery |

### 5b. Packaging — full matrix

| Platform | Format | Arch | Tool |
|---|---|---|---|
| Linux | AppImage | x64, arm64 | appimagetool |
| Linux | .deb | x64, arm64 | dpkg-deb |
| Linux | .rpm | x64, arm64 | rpmbuild |
| Linux | Flatpak | x64 | flatpak-builder |
| Windows | .exe (portable) | x64 | zip |
| Windows | .msi | x64 | WiX |
| macOS | .app | arm64 | hdiutil |
| macOS | .dmg | arm64 | hdiutil |
| Android | .apk | arm64, x64 (split) | gradle + apksigner |
| Android | .aab | arm64, x64 | gradle bundle |
| iOS | .ipa | arm64 | xcodebuild |
| Web | .wasm + .html | wasm32 | emscripten |

### 5c. Documentation

| Doc | Content |
|---|---|
| `ARCHITECTURE.md` | This document (already written) |
| `ROADMAP.md` | This document |
| `PERF-BUDGETS.md` | Metrics, gates, methodology |
| `adr/` | 9 ADRs (decisions with rationale) |
| `STATE.md` | State management deep-dive |
| `ANIMATION.md` | Animation system deep-dive |
| `GESTURES.md` | Gesture system deep-dive |
| `NAVIGATION.md` | Navigation deep-dive |
| `A11Y.md` | Accessibility deep-dive |
| `I18N.md` | Internationalization deep-dive |
| `TESTING.md` | Testing strategy deep-dive |
| `DEVTOOLS.md` | DevTools deep-dive |
| `BUILD.md` | Build system + CLI + packaging |
| `PLATFORM.md` | Platform integration (14 services) |
| `WIDGETS.md` | Widget API reference (full M3E catalog) |
| `STATUS.md` | Current state (updated every session) |

API reference: generated from Zig doc comments (English).

**Exit criteria Phase 5**: `klaxon` CLI works. All packages build. Docs complete. **v1 is done.**

---

## v1 = everything (checklist)

- [ ] 6 platforms: Linux x64/arm64, Windows x64, macOS arm64, Android arm64/x64, iOS arm64, Web WASM
- [ ] Full M3E widget catalog (~65 widgets) — batches 2d.1-2d.4; registry self-registration — 2d-0.6 DONE (PR #15)
- [x] State management (Signal, Memo, Effect, Store) — Phase 1a
- [x] Gestures (tap, double-tap, long-press, pan, swipe, pinch, rotate) — Phase 1d
- [x] Animations (Spring M3E closed-form, Tween, staggered, SIMD, dirty-rect) — Phase 1e; hero/opacity land with the layer ABI
- [x] Scroll (ListView/GridView virtualized, ScrollView, Scrollbar, wheel + drag) — Phase 1f
- [x] Navigation (page stack, transitions, hero, deep links, back) — Phase 2a
- [x] i18n (tr, ARB, RTL, pluralization, number/date formatting) — Phase 2b
- [x] A11y core (semantic tree, keyboard focus, live regions, bridge C ABI) — Phase 2c; the 6 OS bridges land per-platform (Phase 3)
- [x] Design system: Material 3 Expressive tokens (ADR-0010, `docs/DESIGN-SYSTEM.md`) — Phase 2d-0
- [ ] DevTools (overlay, inspector, memory ledger, frame timeline)
- [ ] No-code designer (Phase 2e: canvas, auto-generated inspector, M3E theme panel, JSON/Zig export)
- [ ] Testing (unit, widget, golden ×150, integration)
- [ ] Benchmarks (9 scenes, cross-framework comparison, published)
- [ ] Conformance suite (behavioral spec + scores for Klaxon/Flutter/Qt/Compose, published)
- [ ] CLI (create, run, build, test, bench, package, doctor, gallery)
- [ ] Packaging (AppImage, deb, rpm, Flatpak, exe, msi, app, dmg, apk, aab, ipa, wasm)
- [ ] Documentation (16 docs + API reference)
- [ ] CI (build + test + golden on all platforms)

## V2 (explicitly NOT v1)

- Hot reload
- Dynamic color (HCT tonal palettes from a seed/wallpaper) + extra theme presets
- FreeBSD packaging
- Snap packaging
- HarmonyOS
- Sensors, Camera, Bluetooth platform services
- macOS x64 (dropped permanently)
- Community / ecosystem growth

## Estimated timeline

| Phase | Duration | Cumulative |
|---|---|---|
| Phase 0 — Foundations | 1 week | 1 week |
| Phase 1 — Widgets + Core | 3-4 weeks | 4-5 weeks |
| Phase 2 — Design system + catalog + designer | 6-8 weeks | 10-13 weeks |
| Phase 3 — Multi-platform | 2-3 weeks | 12-16 weeks |
| Phase 4 — DevTools + Testing + Bench | 2 weeks | 14-18 weeks |
| Phase 5 — Packaging + CLI + Docs | 2 weeks | 16-20 weeks |

**Total: 16-20 weeks for a v1 that competes with Flutter/Qt.**
