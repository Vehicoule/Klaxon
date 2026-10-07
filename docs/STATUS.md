# Status — Klaxon Framework

> Updated at the end of every session. Photo of where we are right now.

**Last updated**: 2026-10-07 (Phase 1b — Widgets P0, COMPLETE)

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

**Next: Phase 1c — input widgets (Button, Toggle, Checkbox, Radio, Slider, TextField, Dropdown, Chip).**

## What exists (code, this repo)

- ✅ `build.zig` — exe + test + run steps, kx_skia shim (C++/ObjC++), Skia + SDL3 static link, macOS frameworks, per-OS platform shim
- ✅ `src/main.zig` — hello app: builds the demo tree, runs it through the Host
- ✅ `src/sdl.zig` + `src/sdl_c.h` — SDL3 bindings via `b.addTranslateC`
- ✅ `src/kx.zig` — Skia ABI bindings via `b.addTranslateC`
- ✅ `src/ui/` — `node.zig` (tree, dirty flags, hit-test), `paint.zig`, `layout.zig` (constraints + flex)
- ✅ `src/ui.zig` — ui core re-exports
- ✅ `src/demo.zig` — demo widgets (Box, Label, Column) + showcase tree + flex tests
- ✅ `src/host.zig` — window, dirty-flag event loop (0-frame idle), stats, PPM dump
- ✅ `src/widgets/` — P0 widget library (14 widgets, Phase 1b) + `src/widgets.zig` re-exports
- ✅ `src/golden.zig` — offscreen render + pixel assertions (golden tests; gallery/conformance reuse)
- ✅ `kx_skia/` — C++ shim: `include/kx_skia.h` (C ABI 0.2.0: raster, text+metrics, images, readback), `src/kx_skia_common.cpp` (raster + image registry), `src/kx_skia_platform.h`, `src/kx_skia_macos.mm` (Graphite-Metal + CoreText), `src/kx_skia_linux.cpp` (raster stub)
- ✅ `scripts/fetch-deps.sh` — Skia / SDL3 / WAMR at pinned refs
- ✅ `.github/workflows/ci.yml` — build + test + smoke + size gate on ubuntu + macOS
- ✅ `docs/` — planning set (ARCHITECTURE, ROADMAP, PERF-BUDGETS, STATUS, README, 9 ADRs)
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

- ❌ Gallery (to be written — Phase 1g)
- ❌ Input widgets (Button, Toggle, ...) — Phase 1c, next
- ❌ Gestures
- ❌ Animations
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
9. ~~Phase 1b: widgets P0 (Row, Column, Stack, Grid, Padding, Center, Align, ConstrainedBox, Text, RichText, Icon, Image, Container, Divider) + golden tests~~ done (this PR)
10. **Phase 1c: input widgets (Button, Toggle, Checkbox, Radio, Slider, TextField, Dropdown, Chip)**
