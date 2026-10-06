# ADR-0009: Public API contract = C ABI (language-agnostic bindings)

**Status**: Accepted (2026-10-07)
**Deciders**: project owner
**Related**: ADR-0001 (Zig), ADR-0006 (WASM plugins), ADR-0007 (WAMR)

## Context

Klaxon's core stays in Zig. The goal is that apps can eventually be written in other languages — Zig natively, plus bindings for Lua, Python, JavaScript, C, and friends; sandboxed plugins in WASM per ADR-0006. The question: **what must be decided upfront, while the framework is young, so that adding a language later is a thin binding instead of a rewrite?**

## Decision

1. **All user-facing framework APIs are exposed through a C ABI** (`klaxon.h`): opaque handles, plain data (`f32`/`i32`/`u32`, null-terminated strings), and C function pointers for callbacks. The Zig API remains the reference implementation; the C ABI is the stable contract.
2. **ABI versioning from day one**: `kx_abi_version()` returns a semver string. Breaking changes bump the major version. (`kx_skia.h` is already marked "stable contract" — this formalizes it.)
3. **Boundary rules** that keep the C ABI cheap:
   - No Zig types cross the boundary: no slices, optionals, error unions, or closures-with-capture in public signatures. Plain data + fn ptrs only.
   - Strings are copied at the boundary (or ref-counted) — never borrowed across languages.
   - Callbacks are plain C function pointers + `void* userdata`. The guest must keep them alive for the subscription's lifetime.
   - All guest-visible objects cross as opaque handles.
4. **WASM plugins (ADR-0006) stay the sandboxing story** for app-level extensibility. The C ABI is for *driving* the framework (apps); WASM is for *sandboxed extensions* (plugins). Complementary, not competing.

## Rationale

The C ABI is the seam that makes any C-FFI language able to drive the framework with a thin binding (~100-300 lines): Lua via LuaJIT `ffi`, Python via ctypes/cffi, Go via cgo, C# via P/Invoke, Swift, Kotlin/Native. The retained-tree vtable model (`ui/node.zig`) maps naturally onto C function pointers. Keeping this discipline from day one means each new language is a binding, not a fork. Retrofitting it later means reworking every public signature.

The `kx_skia` shim already proves the pattern at renderer scale (opaque handles, no C++/Zig types crossing). ADR-0009 extends the same pattern upward: renderer → ui → host.

## Consequences

**Positive:**
- Language choice becomes a binding decision, not an architecture decision.
- ABI stability is contractual (semver), like `kx_skia.h`.
- The seam is already proven (`kx_skia`) — extending it is mechanical.

**Negative / costs:**
- Some Zig ergonomics are lost at the boundary (wrappers are more verbose than the native API).
- The C ABI layer is ~800-1500 lines of mechanical Zig to maintain alongside the Zig API.
- Phase 1 must keep public widget APIs C-ABI-shaped (plain data + fn ptrs) — a style constraint on the Zig API.

**Deferred (not v1):**
- The full `klaxon.h` (widget constructors, host run, signal subscriptions) and any per-language binding. They land when a second language is actually wanted (V2 / optional track). Phase 1a (signals) will make signals C-subscribable from the start, so the ABI never needs a rework.

## What changes now (Phase 0/1)

- `kx_abi_version()` added to `kx_skia.h` (semver, breaking = major bump).
- This ADR records the rule: public APIs are C-ABI-shaped; the C ABI layer is the contract.
- Phase 1a (`ui/state.zig`): signals expose a C-subscribable form from day one.
