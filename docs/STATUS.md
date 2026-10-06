# Status — Klaxon Framework

> Updated at the end of every session. Photo of where we are right now.

**Last updated**: 2026-10-06 (Phase 0 — Foundations, in progress)

## Current phase

**Phase 0 — Foundations.** Repo live: `github.com/Vehicoule/klaxon` (greenfield). The old `Klaxon` repo is renamed `klaxon-spikes` (experiments archive: recipes, measurements, quirks). Docs live in `docs/`. `scripts/fetch-deps.sh` is written; the Skia/SDL3/WAMR build is running. Next: `build.zig` hello-world (raster) → `zig build run` opens a window with text.

## What exists (from spikes — knowledge, not code)

Reference material only: pins, build recipes, platform quirks, measurements. No spike code is reused — the framework is written from scratch.

| Asset | Location (in `klaxon-spikes` repo) | Value |
|---|---|---|
| Skia build recipe (args.gn + externals SHAs, proven at pin) | `spikes/src/k0-linux/scripts/`, `spikes/src/w0-graphite-wasm/scripts/` | Reproducible Skia build |
| Backend table (per platform, measured) | `VERDICT-SPIKES.md` | graphite-metal/vulkan/dawn, ganesh-gl/gles, raster |
| Impeller elimination verdict (3 OS, measured) | `spikes/src/i0-impeller/` | Justifies ADR-0002 |
| WAMR > Wasmi > bytebox/zware (measured) | `spikes/src/p0-runtime/` | Justifies ADR-0007 |
| SDL3 + Zig 0.17 quirks (complete list) | `spikes/src/k1-sdl/`, `SESSION-STATE.md` | Avoid re-discovering pitfalls |
| Skia pin 8643b1d6 API quirks (ParagraphBuilder, ICU, etc.) | `spikes/src/k0-linux/` | API adaptation notes |
| Perf measurements (retail Adreno 750, sim Metal, llvmpipe) | `spikes/`, `gates/` | Baseline for budgets |
| Platform quirks (Dawn=CMake, icudtl.dat, 16KiB Android, etc.) | `spikes/` child reports | Platform integration notes |
| Gallery wasm (proven: Skia wasm renders in Chrome) | `spikes/src/w0-graphite-wasm/` | WASM target feasibility |

## What does NOT exist (greenfield)

- ❌ `build.zig` (to be written)
- ❌ `scripts/fetch-deps.sh` (to be written)
- ❌ `kx_skia/` factorized shim (to be written from spike knowledge)
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

## Decisions made (see ADR/)

| ADR | Decision |
|---|---|
| ADR-0001 | Zig 0.17 (pinned) |
| ADR-0002 | Skia only (Graphite/Ganesh/raster). Impeller eliminated. |
| ADR-0003 | SDL3 for platform layer |
| ADR-0004 | Retained widget tree with dirty flags |
| ADR-0005 | SDL_AudioStream + dr_libs + libopus + OS AAC decoder |
| ADR-0006 | WASM plugins (app-level, not framework) |
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
3. `scripts/fetch-deps.sh` — written; Skia + SDL3 + WAMR building into `deps/`
4. `build.zig` hello-world (raster) → `zig build run` opens a window
5. `kx_skia/` factorized shim — macOS first (Metal + raster), Linux in Phase 3a
6. `ui/` core modules + CI green (macOS + Linux runners)
