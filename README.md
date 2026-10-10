# Klaxon

A cross-platform UI framework written in **Zig** — desktop, mobile, and web (WASM). Skia renderer (Graphite primary, Ganesh fallback, raster last resort) on top of SDL3. Built to compete with Flutter and Qt on performance, binary size, and developer experience.

**Stack**: Zig 0.17 (pinned) · Skia · SDL3 · C++ shim. No Rust, no GC, no runtime. Static binaries, split by ABI.

## Quick start

```bash
scripts/fetch-deps.sh   # clone + build Skia, SDL3, WAMR into deps/ (~20-45 min)
zig build run           # hello-world
zig build test          # unit + widget tests
```

## Documentation

Everything lives in [`docs/`](docs/):

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) — vision, stack, modules, widget tree, state, layout, renderer
- [ROADMAP.md](docs/ROADMAP.md) — 6 phases, 12-14 weeks, v1 = everything
- [PERF-BUDGETS.md](docs/PERF-BUDGETS.md) — contractual metrics (fps p99 ≥ 120, RSS < 40 Mo, binary < 5 Mo, ...)
- [STATUS.md](docs/STATUS.md) — current state, updated every session
- [docs/adr/](docs/adr/) — 8 architecture decision records

## Targets (v1)

Linux x64/arm64 · Windows x64/arm64 · macOS arm64 · Android arm64 · iOS arm64 · Web WASM. 50 widgets, full testing (unit/widget/golden/integration), DevTools, CLI, packaging matrix, published benchmarks + conformance suite.

## Repos

```
github.com/Vehicoule/
├── klaxon              ← this repo (the framework)
├── Vehicoule           ← the app (consumer, WASM plugins)
├── klaxon-plugin-sdk   ← plugin SDK (independent semver)
└── klaxon-spikes        ← experiments archive (recipes, measurements, quirks)
```
