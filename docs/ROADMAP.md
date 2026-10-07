# Roadmap — Klaxon Framework

> v1 means everything. All platforms, 50 widgets, full testing, DevTools, packaging, CLI. No V1/V2 split for features. V2 items are explicitly listed below.

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

## Phase 2 — Navigation + i18n + A11y (2 weeks)

### 2a. Navigation (week 1)

| # | Task | Deliverable |
|---|---|---|
| 2a.1 | `ui/navigator.zig` — page stack (declarative + imperative) | push/pop/replace |
| 2a.2 | Transitions: slide, fade, scale | Per-route transition |
| 2a.3 | Hero transitions (shared element) | Cross-route animation |
| 2a.4 | Deep links (URL → route) | `vehicoule://anime/42` |
| 2a.5 | Back stack management | Android back button |

### 2b. i18n (week 1)

| # | Task | Deliverable |
|---|---|---|
| 2b.1 | `ui/i18n.zig` — `tr(key)` + ARB locale files | Load locales at runtime |
| 2b.2 | RTL auto (layout mirror for Arabic/Hebrew) | Row → reversed, padding start/end |
| 2b.3 | Pluralization (`{n, plural, ...}`) | ARB plural rules |
| 2b.4 | Date/number formatting (ICU) | Locale-aware formats |
| 2b.5 | Locale switching at runtime | No restart needed |

### 2c. Accessibility (week 2)

| # | Task | Deliverable |
|---|---|---|
| 2c.1 | `ui/semantics.zig` — semantic tree (finalize) | Role, label, hint, actions, focus |
| 2c.2 | Linux: AT-SPI bridge (D-Bus) | TalkBack equivalent on Linux |
| 2c.3 | Focus keyboard (Tab, arrows, focus ring) | Full keyboard navigation |
| 2c.4 | Live regions (dynamic announcements) | Screen reader announces changes |
| 2c.5 | `excludeSemantics` (hide decorative elements) | Clean a11y tree |

### 2d. Widgets P1 — Navigation + Feedback (week 2)

| Widget | File |
|---|---|
| AppBar | `widgets/app_bar.zig` |
| NavBar | `widgets/nav_bar.zig` |
| Drawer | `widgets/drawer.zig` |
| Tabs | `widgets/tabs.zig` |
| BottomSheet | `widgets/bottom_sheet.zig` |
| Dialog | `widgets/dialog.zig` |
| ProgressIndicator (linear/circular) | `widgets/progress.zig` |
| Badge | `widgets/badge.zig` |
| Tooltip | `widgets/tooltip.zig` |
| SnackBar | `widgets/snackbar.zig` |

**Exit criteria Phase 2**: Navigation works (push/pop/transitions/deep links). i18n works (FR/EN/JA/AR). A11y on Linux (AT-SPI). 40 widgets total.

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
| 4b.2 | Widget: all 50 widgets have widget tests |
| 4b.3 | Golden: all 50 widgets × 3 backends (Linux) = 150 goldens |
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

### 4d. Widgets P2 — Advanced (10 widgets)

Table, Tree, Calendar, DatePicker, ColorPicker, Avatar, Card, ExpansionPanel, Stepper, SegmentedControl, SearchBar, Menu → **50 widgets total**

**Exit criteria Phase 4**: DevTools work on Linux. 150 goldens green. Benchmarks published (Klaxon vs Flutter vs Qt vs Compose). 50 widgets done.

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
| `WIDGETS.md` | Widget API reference (50 widgets) |
| `STATUS.md` | Current state (updated every session) |

API reference: generated from Zig doc comments (English).

**Exit criteria Phase 5**: `klaxon` CLI works. All packages build. Docs complete. **v1 is done.**

---

## v1 = everything (checklist)

- [ ] 6 platforms: Linux x64/arm64, Windows x64, macOS arm64, Android arm64/x64, iOS arm64, Web WASM
- [ ] 50 widgets (P0 + P1 + P2)
- [x] State management (Signal, Memo, Effect, Store) — Phase 1a
- [x] Gestures (tap, double-tap, long-press, pan, swipe, pinch, rotate) — Phase 1d
- [x] Animations (Spring M3E closed-form, Tween, staggered, SIMD, dirty-rect) — Phase 1e; hero/opacity land with the layer ABI
- [x] Scroll (ListView/GridView virtualized, ScrollView, Scrollbar, wheel + drag) — Phase 1f
- [ ] Navigation (declarative + imperative, transitions, deep links)
- [ ] i18n (tr, ARB, RTL, pluralization, ICU)
- [ ] A11y (6 bridges: AT-SPI, NSAccessibility, UIAccessibility, UIA, TalkBack, ARIA)
- [ ] DevTools (overlay, inspector, memory ledger, frame timeline)
- [ ] Testing (unit, widget, golden ×150, integration)
- [ ] Benchmarks (9 scenes, cross-framework comparison, published)
- [ ] Conformance suite (behavioral spec + scores for Klaxon/Flutter/Qt/Compose, published)
- [ ] CLI (create, run, build, test, bench, package, doctor, gallery)
- [ ] Packaging (AppImage, deb, rpm, Flatpak, exe, msi, app, dmg, apk, aab, ipa, wasm)
- [ ] Documentation (16 docs + API reference)
- [ ] CI (build + test + golden on all platforms)

## V2 (explicitly NOT v1)

- Hot reload
- Themes v2 (full design system, more presets)
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
| Phase 2 — Nav + i18n + A11y | 2 weeks | 6-7 weeks |
| Phase 3 — Multi-platform | 2-3 weeks | 8-10 weeks |
| Phase 4 — DevTools + Testing + Bench | 2 weeks | 10-12 weeks |
| Phase 5 — Packaging + CLI + Docs | 2 weeks | 12-14 weeks |

**Total: 12-14 weeks for a v1 that competes with Flutter/Qt.**
