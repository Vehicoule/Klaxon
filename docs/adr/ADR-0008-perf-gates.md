# ADR-0008 — Performance gates as CI contract

**Status**: Accepted
**Date**: 2026-10-06

## Context

Performance regressions are silent killers. A feature that works but is 2× slower ships, and nobody notices until users complain. Klaxon makes performance contractual: budgets are written **before** the module, and a regression fails the build.

## Decision

**Two-tier system: Gate CI (red build) + North Star (design direction).**

Gates are defined in `gates/thresholds.json` (machine-readable). `zig build test` reads them and fails on violation.

## Gate CI (protects the build)

Measured on every commit. A violation = red build = no merge.

| Scene | Metric | Gate | Platform |
|---|---|---|---|
| hello | TTFF | < 200 ms | Linux (llvmpipe proxy) |
| hello | TTFF | < 100 ms | Android device |
| hello | RSS peak | < 60 Mo | Linux (proxy) |
| hello | RSS peak | **< 40 Mo** | Android device |
| hello | Binary size | < 10 Mo | Linux x64 |
| scroll_10k | fps p99 | ≥ 60 | Linux (proxy) |
| scroll_10k | fps p99 | ≥ 120 | Android device |
| scroll_10k | frame p99 | ≤ 16.7 ms (proxy) / ≤ 8.3 ms (device) | Both |
| scroll_10k | allocs_per_frame | == 0 | All |
| scroll_10k | draw_calls | < 100 | All |
| anim_100 | fps p99 | ≥ 60 (proxy) / ≥ 120 (device) | Both |
| anim_100 | frame CPU p99 | ≤ 16.7 ms (proxy) / ≤ 8.3 ms (device) | Both |
| gallery | fps p99 | ≥ 60 (proxy) / ≥ 120 (device) | Both |
| gallery | RSS peak | < 100 Mo | All |

## North Star (design direction, not a failure)

Ambitious targets approached by construction. Informs architecture decisions.

| Metric | North Star |
|---|---|
| fps p99 | 120 everywhere, zero dropped frames |
| frame p99 | ≤ 8.3 ms everywhere |
| RSS hello | < 20 Mo |
| TTFT | < 50 ms |
| Binary size | < 5 Mo |
| WASM size | < 5 Mo |
| allocs_per_frame | 0 (already at max) |
| draw_calls (scroll) | < 50 (aggressive batching) |
| Idle | 0 wakeups/min |

## Measurement methodology

1. **Frames ≥ N before averaging**: minimum 120 frames (2s at 60fps). A single idle frame must never become "the average."
2. **Idle-throttle gaps excluded from pacing_p99**: OS may throttle between frames when idle. These gaps are not jank.
3. **Driver recorded in every result**: llvmpipe = software, never extrapolated to hardware. Every JSON carries a `driver` field.
4. **Cold start = median of 3**: variance on first run is high.
5. **RSS = peak (ru_maxrss)**: the peak is what matters for OOM.
6. **Binary size = post-strip, post-zipalign**: measure the final artifact.
7. **Build time = e2e cold cache**: full pipeline (zig + C shim + link + package), not just `zig build`.

## CI vs device

| Metric | CI (llvmpipe) | Device (nightly) |
|---|---|---|
| fps / frame time | Proxy (gate ≥ 60) | Real (gate ≥ 120) |
| RSS | Disqualified (driver SW adds ~60 Mo) | Real gate |
| TTFF | Proxy | Real gate |
| Binary size | Real gate | Real gate |
| allocs_per_frame | Real gate | Real gate |
| draw_calls | Real gate | Real gate |

## Consequences

- Every module ships with a budget entry in `thresholds.json`.
- Perf regression = red build = no merge. Same as a failing unit test.
- `gates/device.sh` runs device gates nightly (adb, install, run scenes, collect metrics).
- Benchmarks compare Klaxon vs Flutter vs Qt vs Compose on identical scenes.
- DevTools overlay shows live metrics (fps, frame time, RSS, draw calls).
