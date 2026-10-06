# ADR-0003 — SDL3 as the platform layer

**Status**: Accepted
**Date**: 2026-10-06

## Context

Klaxon needs a cross-platform layer for: windows, input events, audio device, mobile lifecycle, IME (text input), clipboard, haptics.

## Decision

**SDL3 (pinned 3.2.16).**

## Rationale

| Criterion | SDL3 | GLFW | sokol_app | Raw platform code |
|---|---|---|---|---|
| Desktop (Linux/Win/macOS) | Yes | Yes | Yes | 3× codebases |
| Mobile (Android/iOS) | Yes | No | Partial | 2× codebases |
| Audio device | Yes | No | Yes | Per-platform |
| IME (text input) | Yes (partial) | No | No | Per-platform |
| Clipboard | Yes | Yes | Yes | Per-platform |
| Haptics | Yes | No | Yes | Per-platform |
| Maturity | Proven (20+ years) | Proven | Young | — |
| Zig bindings | Manual (sdl.zig) | Manual | Manual | — |

SDL3 is the only library that covers desktop + mobile + audio + input + lifecycle in one C library.

## Known gaps (worked around in Klaxon)

| Gap | Workaround |
|---|---|
| No a11y API | Custom bridges (kx_a11y_*) — SDL doesn't help, everything is ours |
| IME partial (Android #13166: keyboard avoidance) | Framework implements scroll-into-view manually |
| `SDL_AppIterate` spins at idle | Throttle with `SDL_WaitEventTimeout` when `!dirty` |
| `SDL_EVENT_TEXT_INPUT` not translated in wasm host | Fixed in host.zig |
| Retail: `BUTTON_UP` synthesis lost on some OEM drivers | `SDL_TOUCH_MOUSE_EVENTS=0` + direct `FINGER_*` events |

## Consequences

- One C dependency for platform. No per-platform windowing code.
- SDL3 quirks documented in `host.zig` and `sdl.zig`.
- SDL3 trimmed at build time (disable camera, sensors, haptic, joystick → ~2 Mo saved).
