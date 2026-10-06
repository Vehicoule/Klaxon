# ADR-0007 — WAMR 2.4.4 as the WASM runtime (no Rust policy)

**Status**: Accepted
**Date**: 2026-10-06

## Context

The app needs a WASM runtime for plugins. Requirements: sandboxed, no JIT (iOS blocks dynamic code signing since 18.4), fuel metering (hermetic), memory limits, deadline, C-only (no Rust policy).

## Decision

**WAMR 2.4.4 fast-interp** (Linux Foundation, C runtime).

## Rationale (measured)

| Runtime | Language | Metering | JIT | iOS | Verdict |
|---|---|---|---|---|---|
| **WAMR fast-interp** | C | Hermetic (all opcodes, loops/branches/recursion) | No | Yes | **Selected** |
| Wasmi | Rust | Partial (no StoreLimits in C API) | No | Yes | Eliminated (no-Rust policy) |
| wasm3 | C | None | No | Yes | Eliminated (maintenance-only) |
| bytebox | Zig | Holed (Loop/Branch not metered) | No | Yes | Eliminated (metering gap) |
| zware | Zig | None | No | Yes | Eliminated (no metering) |
| wasmtime | Rust | Good | Yes | No (JIT blocked) | Eliminated (iOS) |

WAMR is the only C runtime with hermetic fuel metering and no JIT.

## No-Rust policy

All owned code is Zig, C, or C++. This eliminates:
- Wasmi (Rust interpreter)
- AccessKit (Rust a11y) → custom Mini-AccessKit (6 bridges)
- tiny-skia (Rust CPU rasterizer) → Skia raster (C++)

Trade-off: more code to maintain (Mini-AccessKit vs AccessKit). Benefit: full stack ownership, no cargo, no crate hell, one ecosystem.

## Budgets (ADR-0008 format)

- Fuel: 200M instructions / 2B max
- Memory: StoreLimits 64 MiB + max_table_elements 64K
- Deadline: 30s (HTTP timeout 10s)
- HTTP: 32 calls max, 8 MiB in+out combined per call
- Artifacts: 5 MiB per downloaded file

## Consequences

- WAMR CVE watch: CVE-2025-64704, CVE-2025-64713 affect fast-interp → bump to 2.4.4 mandatory.
- Plugin quota exceeded = failure value, not crash.
- `PluginRuntime` interface is abstract → future backends (JIT Android, AOT) are swappable.
