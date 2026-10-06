# Status — Klaxon Framework

> Updated at the end of every session. Photo of where we are right now.

**Last updated**: 2026-10-06 (Phase 0 — Foundations, 0.1 + 0.2 done)

## Current phase

**Phase 0 — Foundations.** Repo live: `github.com/Vehicoule/klaxon` (greenfield). The old `Klaxon` repo is renamed `klaxon-spikes` (experiments archive: recipes, measurements, quirks). Docs live in `docs/`.

- **0.1 done** — `scripts/fetch-deps.sh` builds Skia (11 static libs: graphite + ganesh + raster + Metal), SDL3 (3.6 Mo, trimmed), WAMR (`libiwasm.a`) into `deps/` on macOS arm64. Idempotent, host-aware (macOS arm64 / Linux x64-arm64).
- **0.2 done** — `build.zig` + SDL3 hello: `zig build` links, headless smoke (`SDL_VIDEODRIVER=dummy`) renders 600 frames and exits clean, `zig build test` green.
- **Next** — 0.3/0.4: `kx_skia/` shim (`kx_skia.h` + `kx_skia_common.cpp` + `kx_skia_macos.mm`), raster first → hello renders text via Skia. Then 0.5 `ui/` core, 0.6 `host.zig`, 0.7 CI.

## What exists (code, this repo)

- ✅ `build.zig` — exe + test + run steps, SDL3 static link, macOS frameworks
- ✅ `src/main.zig` — hello app (window + animated frames, self-terminating smoke)
- ✅ `src/sdl.zig` + `src/sdl_c.h` — SDL3 bindings via `b.addTranslateC`
- ✅ `scripts/fetch-deps.sh` — Skia / SDL3 / WAMR at pinned refs
- ✅ `docs/` — planning set (ARCHITECTURE, ROADMAP, PERF-BUDGETS, STATUS, README, 8 ADRs)
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

- ❌ `kx_skia/` factorized shim (to be written)
- ❌ `ui/` modules (to be written)
- ❌ `widgets/` (to be written)
- ❌ Gallery (to be written)
- ❌ CI (to be configured)
- ❌ All 50 widgets
- ❌ State management (signals)
- ❌ Gestures
- ❌ Animations
- ❌ Navigation
- ❌ i18n
- ❌ A11y bridges (6)
- ❌ DevTools
- ❌ CLI
- ❌ Packaging
- ❌ Benchmarks
- ❌ Documentation (beyond this planning set)

## Toolchain quirks (learned 2026-10-06, macOS arm64 + Zig 0.17.0)

- **Zig 0.17 removed `@cImport`** → C bindings via `b.addTranslateC` over a C header (`src/sdl_c.h`) + `root_module.addImport("sdl_c", ...)`.
- **Zig 0.17 build API**: `linkLibC()` gone → `module.link_libc = true`. `addIncludePath` / `addObjectFile` / `linkFramework(name, .{})` moved from `Compile` to `root_module`. `b.args` gone.
- **Skia @ pin 8643b1d6**: no `bin/gn` wrapper → run `python3 bin/fetch-gn` first (downloads `bin/gn`). Host has `python3` only, no `python`.
- **WAMR darwin**: the `vmlib` target is renamed on output → static lib is `libiwasm.a`.
- **SDL3 macOS link**: needs frameworks Cocoa, IOKit, CoreVideo, CoreAudio, AudioToolbox, AudioUnit, ForceFeedback, GameController, Metal, QuartzCore, CoreHaptics, AVFoundation, UniformTypeIdentifiers, CoreBluetooth, CoreFoundation, CoreGraphics, Carbon. The camera backend pulls CoreMedia — avoided by trimming (`-DSDL_CAMERA=OFF -DSDL_SENSOR=OFF -DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_RENDER_VULKAN=OFF`).
- **Headless smoke test**: `SDL_VIDEODRIVER=dummy ./zig-out/bin/hello` renders without opening a window.

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

## Target metrics (v1)

| Metric | Target |
|---|---|
| fps p99 (real scenes) | ≥ 120 |
| frame p99 | ≤ 8.3 ms |
| RSS hello | < 40 Mo |
| TTFF | < 100 ms |
| Binary size hello | < 5 Mo |
| WASM size hello | < 5 Mo |
| allocs_per_frame | 0 |
| Widget count | 50 |
| Platforms | Linux x64/arm64, Windows x64, macOS arm64, Android arm64/x64, iOS arm64, Web WASM |

## Next steps

1. ~~Create `github.com/Vehicoule/klaxon`~~ done — old `Klaxon` renamed `klaxon-spikes` (archive)
2. ~~Copy `klaxon-docs/` into `docs/`~~ done
3. ~~`scripts/fetch-deps.sh`~~ done — Skia + SDL3 (trimmed) + WAMR built into `deps/` (macos-arm64)
4. ~~`build.zig` hello (SDL3)~~ done — links, headless smoke 600 frames OK, `zig build test` green
5. `kx_skia/` shim: `kx_skia.h` + `kx_skia_common.cpp` + `kx_skia_macos.mm` — raster first, then Metal; hello renders text via Skia
6. `ui/` core modules (`node.zig`, `paint.zig`, `layout.zig`) + `host.zig`
7. CI green (macOS + Linux runners)
