# Klaxon — Documentation

> Klaxon is a cross-platform UI framework written in Zig, targeting desktop, mobile, and web (WASM). It aims to compete with Flutter and Qt on performance, binary size, and developer experience.

## Document map

### Core documents (read these first)

| Document | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Vision, stack, layers, modules, widget tree, state management, layout, renderer, build, testing, DevTools, memory, packaging |
| [ROADMAP.md](ROADMAP.md) | 6 phases from foundations to v1. Timeline, deliverables, exit criteria, v1 checklist |
| [PERF-BUDGETS.md](PERF-BUDGETS.md) | Target metrics, gates by scene × platform × backend, measurement methodology, CI vs device |
| [STATUS.md](STATUS.md) | Current state. Updated every session. What exists, what doesn't, next steps |

### Architecture Decision Records (ADR)

| ADR | Decision |
|---|---|
| [ADR-0001](adr/ADR-0001-zig-0.17.md) | Zig 0.17 (pinned) |
| [ADR-0002](adr/ADR-0002-skia-only.md) | Skia only (Graphite/Ganesh/raster). Impeller eliminated by measurement. |
| [ADR-0003](adr/ADR-0003-sdl3.md) | SDL3 for platform layer |
| [ADR-0004](adr/ADR-0004-retained-tree.md) | Retained widget tree with dirty flags (not immutable) |
| [ADR-0005](adr/ADR-0005-audio-decoders.md) | SDL_AudioStream + dr_libs + libopus + OS AAC decoder |
| [ADR-0006](adr/ADR-0006-wasm-plugins.md) | WASM plugins (app-level, signed Git registries) |
| [ADR-0007](adr/ADR-0007-wamr-runtime.md) | WAMR 2.4.4 fast-interp (no-Rust policy) |
| [ADR-0008](adr/ADR-0008-perf-gates.md) | Performance gates as CI contract |
| [ADR-0009](adr/ADR-0009-c-abi-contract.md) | Public API contract = C ABI (language-agnostic bindings) |

### Deep-dive documents (written during development)

| Document | Topic | Phase |
|---|---|---|
| STATE.md | State management (Signal, Memo, Effect, Store) | Phase 1a |
| ANIMATION.md | Animation system (Spring, Tween, SIMD, dirty-rect) | Phase 1e |
| GESTURES.md | Gesture system (GestureArena, recognizers) | Phase 1d |
| NAVIGATION.md | Navigation (Navigator 2.0, transitions, deep links) | Phase 2a |
| A11Y.md | Accessibility (semantic tree, 6 bridges) | Phase 2c |
| I18N.md | Internationalization (tr, ARB, RTL, pluralization) | Phase 2b |
| TESTING.md | Testing strategy (unit, widget, golden, integration) | Phase 4b |
| DEVTOOLS.md | DevTools (overlay, inspector, memory ledger) | Phase 4a |
| BUILD.md | Build system + CLI + packaging | Phase 5 |
| PLATFORM.md | Platform integration (14 services) | Phase 2-3 |
| WIDGETS.md | Widget API reference (50 widgets) | Phase 1-4 |

## Repos

```
github.com/Vehicoule/
├── klaxon              ← The framework (this project, greenfield)
├── vehicule            ← The app (consumer, WASM plugins; exists on GitHub, currently empty)
├── klaxon-plugin-sdk   ← Plugin SDK (independent semver; not created yet)
└── klaxon-spikes        ← Experiments (archive = the old Klaxon repo, renamed 2026-10; recipes, measurements, quirks)
```

## Conventions

- **Code comments**: English.
- **Documentation**: English.
- **ADR format**: Context → Decision → Rationale → Consequences.
- **STATUS.md**: updated at the end of every session.
- **Perf budgets**: written before the module. Regression = red build.
