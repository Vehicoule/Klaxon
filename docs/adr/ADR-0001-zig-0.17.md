# ADR-0001 — Zig 0.17 as the framework language

**Status**: Accepted
**Date**: 2026-10-06

## Context

Klaxon needs a systems language with: C interop, no runtime/GC, static binaries, fast compile times, and a comptime meta-programming system for the DSL.

## Decision

**Zig 0.17 (pinned).** Converge toward stability as Zig matures.

## Rationale

| Criterion | Zig | C | Rust | C++ |
|---|---|---|---|---|
| C interop | Native | Native | FFI (friction) | Native |
| Runtime/GC | None | None | None | Optional (heavy if used) |
| Static binaries | Yes | Yes | Yes | Yes |
| Compile speed | Fast (0.5s Debug, 2.6s ReleaseSmall) | Fast | Slow (cargo) | Slow |
| comptime DSL | Yes (unique) | No | Macros (limited) | Templates (ugly) |
| Ecosystem maturity | Young | Mature | Mature | Mature |
| Agent IA productivity | Medium (learning curve) | High | Medium | Medium |

Zig's comptime is the decisive factor: the DSL is type-safe, refactorable, zero-parser. No other language offers this.

## Risks

- **Breaking changes**: Zig is 0.x. Mitigation: pin version, CI tests the bump before upgrading.
- **Young ecosystem**: few mature libraries. Mitigation: vendor what we need (Skia, SDL3, WAMR), write the rest in Zig.
- **Stability direction**: Zig's recent releases focus on foundation stability (~1 release/year). Risk decreasing.

## Consequences

- Pin Zig 0.17.0 in `build.zig.zon` and CI.
- Document Zig 0.17 quirks (SDL_Init returns bool, `@cImport` C++ limits, `std.process.Init` API).
- No Rust in the stack (see ADR-0007).
