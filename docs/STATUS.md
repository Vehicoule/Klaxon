# Status — Klaxon Framework

> Updated at the end of every session. Photo of where we are right now.

**Last updated**: 2026-10-07 (Phase 1 — Widgets + Core Systems, COMPLETE: 1a–1g)

## Current phase

**Phase 0 — Foundations: DONE.** Repo live: `github.com/Vehicoule/klaxon` (greenfield). The old `Klaxon` repo is renamed `klaxon-spikes` (experiments archive: recipes, measurements, quirks). Docs live in `docs/`.

- **0.1 done** — `scripts/fetch-deps.sh` builds Skia (11 static libs: graphite + ganesh + raster + Metal), SDL3 (3.6 Mo, trimmed), WAMR (`libiwasm.a`) into `deps/` on macOS arm64. Idempotent, host-aware (macOS arm64 / Linux x64-arm64).
- **0.2 done** — `build.zig` + SDL3 hello: `zig build` links, headless smoke renders 600 frames and exits clean, `zig build test` green.
- **0.3/0.4 done** — `kx_skia/` shim: `kx_skia.h` (C ABI) + `kx_skia_common.cpp` (raster, draw, readback) + `kx_skia_platform.h` + `kx_skia_macos.mm` (Graphite-Metal onscreen + CoreText fonts) + `kx_skia_linux.cpp` (raster-only stub, FreeType font dirs; GPU lands in Phase 3a). Metal path compiles + links, fails gracefully headless; runtime check on a real GPU window pending (`zig build run -- metal`).
- **0.5 done** — `ui/` core: `node.zig` (retained tree, dirty flags, hit-test), `paint.zig` (Paint + kx emission), `layout.zig` (Constraints/Size + flex measure/layout algorithms). Unit tests: constraints, dirty propagation, hit-test, flex measure/layout.
- **0.6 done** — `host.zig`: window, dirty-flag event loop (renders only when the tree is dirty; blocks on `SDL_WaitEvent` at true idle = 0 wakeups), resize handling, stats, PPM frame dump. Hello renders a 5-node widget tree (Column[Box, Label, Label, Box]) — verified by PPM pixel analysis (accent card 56683 px, footer 28390 px, white title 1393 px, gray subtitle 873 px). 600 frames at ~0.5 ms/frame raster.
- **0.7 done** — CI: `.github/workflows/ci.yml` (ubuntu-latest + macOS-latest: fetch-deps with cache, zig build, zig build test, headless smoke, ReleaseSmall size gate < 10 Mo — current: 6.0 Mo). First CI run will validate the Linux build (shim compile-checked locally for x86_64-linux-gnu).

**Exit criteria Phase 0: MET.** `zig build run` renders text via a widget tree. `zig build test` green. CI workflow in place.

- **1a done** — `ui/state.zig`: fine-grained reactivity (Signal/Memo/Effect/Store, ADR-0009 C-ABI shape) + 6 tests. Merged as PR #2.
- **1b done** — Widgets P0 (14): Row, Column, Stack, Grid, Padding, Center, Align (`alignTo`), ConstrainedBox, Text, RichText, Icon, Image, Container, Divider (`src/widgets/`, factory-over-Node pattern). Golden tooling: `src/golden.zig` renders any tree offscreen (raster, no window) and asserts pixels — structural assertions only (exact counts for solid rects, presence/absence for text/icons; glyph shapes are font-dependent). kx_skia ABI 0.2.0 (purely additive, ADR-0009): `kx_draw_text_styled` (bold-aware text; `kx_draw_text` unchanged), `kx_measure_text` (real font metrics at layout time, process-global font mgr), image registry (`kx_image_create/draw/destroy` — create once, draw many, 0 per-frame allocs). ui core: `EdgeInsets`, `Alignment` (9-point), `MainAlign`/`CrossAlign`/`TextAlign`, `Constraints.loosen/deflateEdge/enforcedBy`, `flexLayout` v2 with free-space distribution. `zig build test` = 43 tests green; hello smoke + ReleaseSmall 6.0 Mo.

- **1c done** — Input system + 8 input widgets (22/50). `ui/input.zig`: `InputRouter` — pointer dispatch (hit-test → deepest node, capture for drags, bubbling until handled), hover enter/leave, keyboard focus routing, open-popup barrier (click outside closes + consumes). Events are platform-agnostic (`PointerEvent`/`KeyEvent`); the host maps SDL mouse/finger/text/key into them. `Node.visible` (invisible subtrees skip paint + hit-test) and `VTable.on_pointer`/`on_key` (optional, backward compatible). Widgets (`src/widgets/input.zig`): Button (pressed/hover states + onPressed), Toggle/Checkbox/Radio/Slider/Chip — signal-driven (Phase 1a), unsubscribe on deinit — TextField (focus, UTF-8 editing with multi-byte-safe backspace, placeholder, cursor, onChanged/onSubmitted), Dropdown (overlay menu as child nodes, `hitTestSubtree` for out-of-bounds popup children). Golden tooling grew `Renderer` for interactive multi-frame tests (dispatch input between frames). 78 tests green.

- **1d done** — Gestures: `ui/gestures.zig` (GestureArena + 7 recognizers: tap, double-tap, long-press, pan, swipe/fling, pinch, rotate; tuned constants: slop 12, tap 200ms, double-tap 300ms, long-press 500ms, swipe 500px/s) + `widgets/gestures.zig` (`GestureDetector` wrapper). Router is now multi-pointer (per-pointer capture, pointer ids + timestamps from SDL; pinch/rotate need them). P0 deviations documented in `docs/GESTURES.md` (long-press fires on first event after threshold — no platform timers; single tap fires immediately). Merged as PR #6. 97 tests green.

- **1e done** — Animations: `ui/anim.zig` (Spring M3E closed-form — under/critical/overdamped, exact at any tick rate; Tween with Ease curves incl. M3 standard/emphasized cubic-bezier + custom fn; SIMD `@Vector(4,f32)` lerp4/lerpColor; Timeline: process-global, time-based, stagger, channels, priority + frame_overrun) + `widgets/anim.zig` (`AnimatedContainer` w/h/color, `AnimatedOffset`, `AnimatedScale` — signal-driven implicit animations, retarget cancels via channels, teardown cancels in-flight). Host: timeline tick every loop iteration, layout pass, **dirty-rect** (retained surface + damage accumulator + `kx_clip_rect`), **frame budget** 8.3 ms (~120 fps pacing; overrun pauses low-priority anims). kx_skia ABI **0.3.0** (additive): `kx_save/restore/translate/scale/clip_rect/clip_reset`. Node: `markDirtyRect` + root damage accumulator + `pre/post_children_paint` vtable hooks (canvas transform around children). Gestures: arena tick → long-press fires exactly at 500 ms (detector registers a timeline ticker). Widgets 26/50. Merged as PR #7. 134 tests green. `docs/ANIMATION.md`.

- **1f done** — Scroll: `ui/scroll.zig` (ScrollState clamping + `visibleRange` virtualization math) + wheel input (`input.ScrollEvent` + router `dispatchScroll` bubbling; host maps `SDL_EVENT_MOUSE_WHEEL`). Widgets: `ListView` (virtualized vertical list — 10k items keep ~7 live child nodes; window diffs on scroll), `GridView` (virtualized grid, row-aligned window), `ScrollView` (single-child scroll), `Scrollbar` (drives any scrollable via the new vtable hooks `scroll_info`/`scroll_set_offset` — no widget-to-widget dependency). Scroll input: wheel + drag (moves bubble from items; only scrolls while the router has a capture — hover never scrolls) + programmatic (`scrollBy`/`setScrollOffset`). Children paint translated by -offset and clipped to the viewport (reuses the Phase 1e transform hooks: `pre/post_children_paint` + `map_paint_rect` + `pre_children_hit` — hit-testing and damage land at the visual position). VTable gained `on_scroll` + the scrollable hooks. Widgets 30/50. Merged as PR #8 (Devin review round: mapped input coordinates for scrolled controls, raw window-space drag deltas + per-pointer tracks for concurrent fingers, `Node.deinit` releases router references, offset re-clamp on resize, scrollbar thumb ticker, grid 0-column normalization, backward-jump re-anchor). 160 tests green (incl. 10k-item virtualization + frame-time bound).

- **1g done** — Gallery: `src/gallery.zig` + `src/gallery_main.zig` + `src/theme.zig` — full showcase (31 widgets): Input (Button/Toggle/Checkbox/Radio/Slider/TextField/Dropdown/Chip), Gestures (all 9 callbacks on a live detector), Animations (AnimatedContainer pulse / AnimatedOffset slide / AnimatedScale grow), Layout (Row/Column/Stack/Grid/Padding/Center/Align/ConstrainedBox), Typography & media (Text/RichText/Icon/Image), Scroll (ListView 10k + GridView 500 + ScrollView + 2 Scrollbars). Dark/light themes (`Theme` presets) with a live toggle: the themed tree is REBUILT on switch (`Node.remove` + deinit — new primitive) and the bg animates via AnimatedContainer. Dynamic text via the new `BoundText(T)` widget (signal-driven Text, re-measured on change). New small APIs: `Node.remove`, `BoundText`, `textFieldText`/`dropdownSelected` accessors. Build: `zig build gallery` (exe + run step), `zig build test-golden` (custom runner `src/test_runner_golden.zig` — Zig 0.17's compile-time `--test-filter` only matches root-module tests, and this repo's tests live in the widget modules). Host loop fix (exposed by the gallery smoke): an app tick (`on_frame`) now renders EVERY iteration — previously a tick that changed nothing (e.g. an animation value quantized to the same integer) stalled the loop forever (`frames < max_frames` with frames frozen). Widgets 31/50. 170 tests green (29 golden). Gallery ReleaseSmall 6.1 Mo. Merged as PR #9.

**Exit criteria Phase 1: MET.** Gallery runs headless on Linux (CI smoke: 600 frames) and on the dev Mac (`zig build gallery`). 31 widgets functional. State, gestures, animations, scroll 10k work. `zig build test` + `zig build test-golden` green.

**Next: Phase 2a — navigation (page stack, transitions, deep links).**

## What exists (code, this repo)

- ✅ `build.zig` — exe + test + run steps, kx_skia shim (C++/ObjC++), Skia + SDL3 static link, macOS frameworks, per-OS platform shim
- ✅ `src/main.zig` — hello app: builds the demo tree, runs it through the Host
- ✅ `src/sdl.zig` + `src/sdl_c.h` — SDL3 bindings via `b.addTranslateC`
- ✅ `src/kx.zig` — Skia ABI bindings via `b.addTranslateC`
- ✅ `src/ui/` — `node.zig` (tree, dirty flags, hit-test), `paint.zig`, `layout.zig` (constraints + flex)
- ✅ `src/ui.zig` — ui core re-exports
- ✅ `src/demo.zig` — demo widgets (Box, Label, Column) + showcase tree + flex tests
- ✅ `src/host.zig` — window, dirty-flag event loop (0-frame idle), stats, PPM dump
- ✅ `src/widgets/` — widget library (14 P0 + 8 input + 1 gesture + 3 animated + 4 scroll + BoundText = 31, Phases 1b/1c/1d/1e/1f/1g) + `src/widgets.zig` re-exports
- ✅ `src/gallery.zig` + `src/gallery_main.zig` — gallery app (full showcase, dark/light themes) (Phase 1g)
- ✅ `src/theme.zig` — Theme presets (dark/light) (Phase 1g)
- ✅ `src/test_runner_golden.zig` — golden-only test runner (runtime name filter) (Phase 1g)
- ✅ `src/ui/input.zig` — input router (pointer/keyboard/popup, Phase 1c; multi-pointer capture, Phase 1d)
- ✅ `src/ui/gestures.zig` — GestureArena + recognizers (Phase 1d) + `docs/GESTURES.md`
- ✅ `src/widgets/gestures.zig` — GestureDetector wrapper (Phase 1d)
- ✅ `src/ui/anim.zig` — Spring (M3E closed-form), Tween, curves, SIMD lerp, Timeline (Phase 1e) + `docs/ANIMATION.md`
- ✅ `src/widgets/anim.zig` — AnimatedContainer / AnimatedOffset / AnimatedScale (Phase 1e)
- ✅ `src/ui/scroll.zig` — ScrollState (clamping) + visibleRange (virtualization math) (Phase 1f)
- ✅ `src/widgets/list_view.zig` — ListView (virtualized: 10k items → ~7 live nodes) (Phase 1f)
- ✅ `src/widgets/grid_view.zig` — GridView (virtualized, row-aligned window) (Phase 1f)
- ✅ `src/widgets/scroll_view.zig` — ScrollView (single-child scroll) (Phase 1f)
- ✅ `src/widgets/scrollbar.zig` — Scrollbar (drives any scrollable via vtable hooks) (Phase 1f)
- ✅ `src/golden.zig` — offscreen render + pixel assertions + interactive `Renderer` (golden tests; gallery/conformance reuse)
- ✅ `kx_skia/` — C++ shim: `include/kx_skia.h` (C ABI 0.3.0: raster, text+metrics, images, readback, canvas state/transforms/clip), `src/kx_skia_common.cpp` (raster + image registry + canvas state), `src/kx_skia_platform.h`, `src/kx_skia_macos.mm` (Graphite-Metal + CoreText), `src/kx_skia_linux.cpp` (raster stub)
- ✅ `scripts/fetch-deps.sh` — Skia / SDL3 / WAMR at pinned refs
- ✅ `.github/workflows/ci.yml` — build + test + smoke + size gate on ubuntu + macOS
- ✅ `docs/` — planning set (ARCHITECTURE, ROADMAP, PERF-BUDGETS, STATUS, README, STATE.md, 9 ADRs)
- ✅ `deps/` (gitignored) — built artifacts, macos-arm64

## What exists (from spikes — knowledge, not code)

Reference material only: pins, build recipes, platform quirks, measurements. No spike code is reused — the framework is written from scratch.

| Asset | Location (in `klaxon-spikes` repo) | Value |
|---|---|---|
| Skia build recipe (args.gn + externals SHAs, proven at pin) | `spikes/src/k0-linux/scripts/`, `spikes/src/w0-graphite-wasm/scripts/` | Reproducible Skia build |
| Backend table (per platform, measured) | `VERDICT-SPIKES.md` | graphite-metal/vulkan/dawn, ganesh-gl/gles, raster |
| Impeller elimination verdict (3 OS, measured) | `spikes/src/i0-impeller/` | Justifies ADR-0002 |
| WAMR > Wasmi > bytebox/zware (measured) | `spikes/src/p0-runtime/` | Justifies ADR-0007 |
| SDL3 + Zig quirks (complete list) | `spikes/src/k1-sdl/`, `SESSION-STATE.md` | Avoid re-discovering pitfalls |
| Skia pin 8643b1d6 API quirks (ParagraphBuilder, ICU, etc.) | `spikes/src/k0-linux/` | API adaptation notes |
| Perf measurements (retail Adreno 750, sim Metal, llvmpipe) | `spikes/`, `gates/` | Baseline for budgets |
| Platform quirks (Dawn=CMake, icudtl.dat, 16KiB Android, etc.) | `spikes/` child reports | Platform integration notes |
| Gallery wasm (proven: Skia wasm renders in Chrome) | `spikes/src/w0-graphite-wasm/` | WASM target feasibility |

## What does NOT exist (greenfield)

- ❌ Navigation
- ❌ i18n
- ❌ All 50 widgets
- ❌ A11y bridges (6)
- ❌ DevTools
- ❌ CLI
- ❌ Packaging
- ❌ Benchmarks
- ❌ Documentation (beyond this planning set)

## Toolchain quirks (learned 2026-10-06/07, macOS arm64 + Zig 0.17.0)

- **Zig 0.17 removed `@cImport`** → C bindings via `b.addTranslateC` over a C header + `root_module.addImport`.
- **Zig 0.17 build API**: `linkLibC()` gone → `module.link_libc = true`. `addIncludePath` / `addObjectFile` / `linkFramework(name, .{})` / `addCSourceFiles(.language=)` / `linkLibrary` moved from `Compile` to `root_module`. `b.args` gone.
- **Zig 0.17 process args**: `std.process.args()` gone → `pub fn main(init: std.process.Init.Minimal)`, iterate via `std.process.Args.Iterator.init(init.args)`.
- **Zig 0.17 stdlib**: `std.fs.cwd()` gone. `std.fmt.bufPrintZ` → `bufPrintSentinel` (len excludes the sentinel). `std.time.nanoTimestamp` gone and no `std.time.Instant` — use `SDL_GetTicksNS()` for frame timing. `std.ArrayList` is unmanaged → use `std.array_list.Managed(T)`. `GeneralPurposeAllocator` → `std.heap.DebugAllocator`.
- **Zig gotchas**: method call on a struct literal needs parens (`(T{...}).method()`); sibling decls are not struct members (`VTable` is `ui.node.VTable`, not `Node.VTable`).
- **Skia @ pin 8643b1d6**: no `bin/gn` wrapper → run `python3 bin/fetch-gn` first (downloads `bin/gn`). Host has `python3` only, no `python`. Requires `-std=c++20`; shim flags: `-fno-exceptions -fno-rtti -DSK_GANESH -DSK_GRAPHITE -DNDEBUG`.
- **Skia @ pin**: `SkSurface::flush()` no longer exists (raster is synchronous). Graphite-Metal: `ContextFactory::MakeMetal(MtlBackendContext, ContextOptions)`, `BackendTextures::MakeMetal(SkISize, CFTypeRef)`, `SkSurfaces::WrapBackendTexture`, `InsertRecordingInfo{.fRecording, .fTargetSurface}`, `submit()` default. `SkFontMgr_New_CoreText` in libskia.a (`include/ports/SkFontMgr_mac_ct.h`). Linux font mgrs: `SkFontMgr_New_Custom_Directory` / `SkFontMgr_New_Custom_Empty` (`include/ports/SkFontMgr_directory.h`, `SkFontMgr_empty.h`).
- **C++ runtime alignment**: libskia.a references libc++ symbols (`std::__1`) → Linux builds Skia with `-stdlib=libc++` to match zig's bundled libc++ (CI installs `libc++-dev`). macOS is libc++ everywhere already.
- **WAMR darwin**: the `vmlib` target is renamed on output → static lib is `libiwasm.a`.
- **SDL3 macOS link**: needs frameworks Cocoa, IOKit, CoreVideo, CoreAudio, AudioToolbox, AudioUnit, ForceFeedback, GameController, Metal, QuartzCore, CoreHaptics, AVFoundation, UniformTypeIdentifiers, CoreBluetooth, CoreFoundation, CoreGraphics, Carbon. The camera backend pulls CoreMedia — avoided by trimming (`-DSDL_CAMERA=OFF -DSDL_SENSOR=OFF -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF`).
- **Pixel formats**: Skia `kRGBA_8888` readback (memory R,G,B,A) == `SDL_PIXELFORMAT_ABGR8888`.
- **Headless smoke test**: `SDL_VIDEODRIVER=dummy ./zig-out/bin/hello` renders without opening a window.
- **zig cc cross-compile**: C++ cross-target needs `-lc++` for the bundled libc++ headers.

## Decisions made (see ADR/)

| ADR | Decision |
|---|---|
| ADR-0001 | Zig 0.17 (pinned) |
| ADR-0002 | Skia only (Graphite/Ganesh/raster). Impeller eliminated. |
| ADR-0003 | SDL3 for platform layer |
| ADR-0004 | Retained widget tree with dirty flags |
| ADR-0005 | SDL_AudioStream + dr_libs + libopus + OS AAC decoder |
| ADR-0006 | WASM plugins (app-level, signed Git registries) |
| ADR-0007 | WAMR 2.4.4 fast-interp (no-Rust policy) |
| ADR-0008 | Performance gates as CI contract |
| ADR-0009 | Public API contract = C ABI (language-agnostic bindings) |

## Target metrics (v1)

| Metric | Target |
|---|---|
| fps p99 (real scenes, incl. video_playback) | ≥ 120 |
| frame p99 | ≤ 8.3 ms |
| RSS hello | < 40 Mo |
| TTFF | < 100 ms |
| Binary size hello | < 5 Mo (CI gate < 10 Mo — current 6.0 Mo) |
| WASM size hello | < 5 Mo |
| allocs_per_frame | 0 |
| Widget count | 50 |
| Platforms | Linux x64/arm64, Windows x64, macOS arm64, Android arm64/x64, iOS arm64, Web WASM |

## Next steps

1. ~~Create `github.com/Vehicoule/klaxon`~~ done — old `Klaxon` renamed `klaxon-spikes` (archive)
2. ~~Copy `klaxon-docs/` into `docs/`~~ done
3. ~~`scripts/fetch-deps.sh`~~ done — Skia + SDL3 (trimmed) + WAMR built into `deps/` (macos-arm64)
4. ~~`build.zig` hello (SDL3)~~ done
5. ~~`kx_skia/` shim~~ done — raster renders a widget tree (PPM-verified); Metal compiles+links, runtime check pending on real GPU (`zig build run -- metal`)
6. ~~`ui/` core + `host.zig`~~ done — node/paint/layout + dirty-flag event loop + stats
7. ~~CI~~ done — workflow written (ubuntu + macOS); first run validates Linux build
8. ~~Phase 1a: `ui/state.zig` — Signal/Memo/Effect/Store (fine-grained reactivity) + unit tests~~ done (PR #2)
9. ~~Phase 1b: widgets P0 (Row, Column, Stack, Grid, Padding, Center, Align, ConstrainedBox, Text, RichText, Icon, Image, Container, Divider) + golden tests~~ done (PR #3)
10. ~~Phase 1c: input widgets (Button, Toggle, Checkbox, Radio, Slider, TextField, Dropdown, Chip) + input router~~ done (PR #4)
11. ~~Phase 1d: gestures (GestureArena: tap/double-tap/long-press/pan/swipe/pinch/rotate) + GestureDetector~~ done (PR #6)
12. ~~Phase 1e: animations (Spring M3E closed-form, Tween, SIMD, timeline, dirty-rect, frame budget) + AnimatedContainer/Offset/Scale~~ done (PR #7)
13. ~~Phase 1f: scroll (ListView/GridView virtualized, ScrollView, Scrollbar)~~ done (PR #8)
14. ~~Phase 1g: gallery (full showcase: all widgets, themes, animations, gestures, scroll 10k)~~ done (PR #9)
15. **Phase 2a: navigation (`ui/navigator.zig` — page stack, transitions, deep links, back stack)**
