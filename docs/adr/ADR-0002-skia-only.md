# ADR-0002 — Skia only (Graphite primary + Ganesh fallback + raster last resort)

**Status**: Accepted (confirmed by measurements, reversed from initial Impeller choice)
**Date**: 2026-10-06 (reversed 2026-10-04 from ADR draft v5-v15)

## Context

Klaxon needs a 2D renderer with: GPU acceleration (Vulkan/Metal/D3D12/WebGPU), CPU fallback (raster), mature text rendering (CJK, RTL, emoji), and cross-platform support (desktop + mobile + web).

Initial choice was Impeller (Flutter's renderer). Spikes measured both.

## Decision

**Skia only.** Impeller eliminated.

Backend hierarchy:
- **Primary**: Graphite (Vulkan/Metal/Dawn-D3D12/WebGPU) — modern, GPU-first
- **Fallback**: Ganesh (GLES/GL/WebGL2) — for devices without Vulkan/Metal
- **Last resort**: Raster (CPU) — for devices without GPU

Text: SkParagraph + FontMgr fallback (multi-script verified).

## Rationale (measured)

| Benchmark | Impeller | Skia | Winner |
|---|---|---|---|
| Metal (macOS, real GPU, 7/9 scenes) | ×1.4-×4.3 slower | — | **Skia** |
| Metal (iOS sim, 9/9 scenes) | ×2.4-×13 slower | — | **Skia** |
| Software (llvmpipe, Linux) | ×2-×30 slower | — | **Skia** |
| RSS floor (context alone) | ~39 Mo | ~14 Mo | **Skia** |
| Raster paths (N=1000) | ~24 ms | 10.3 ms | **Skia** |
| Blur (s5, Metal) | — | 3.8 ms vs 83.7 ms raster (×22) | **Skia** |

Impeller's only wins: marginal (s8 points ×0.79 macOS, first-frame ~65ms faster). Not enough to justify a second renderer.

**Graphite-first validated by industry**: Google is removing Ganesh from Chrome. Graphite is the future of Skia.

## Alternatives considered

| Alternative | Verdict |
|---|---|
| Impeller | Eliminated by measurements (3 OS, 3 independent measurements) |
| wgpu | GPU abstraction, not a 2D renderer. Would require writing text/paths/filters from scratch. |
| Vello | Alpha, blur incomplete. Watch-item 12-18 months. |
| tiny-skia | CPU-only, zero text, zero filters. Unusable for a CJK hub. |
| Custom renderer in Zig | Insane for a solo project. Text CJK alone = 60% of effort. |

## Consequences

- Skia build is heavy (~45 min, ~25 Mo of .a). Mitigation: CI builds with cache.
- No C API for Graphite → custom C++ shim required (kx_skia/).
- Ganesh will be removed by Google eventually → plan Skia pin upgrade path.
- iOS pin: `skia_enable_graphite=false` (simulator limitation).
