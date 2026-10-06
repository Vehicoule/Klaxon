# ADR-0006 — WASM plugins (app-level, not framework)

**Status**: Accepted
**Date**: 2026-10-06

## Context

Vehicule (the app) needs a plugin ecosystem: community-contributed providers for music/anime/books sources. Plugins must be sandboxed, language-agnostic, and hot-updatable.

## Decision

**WASM plugins, sandboxed structurally** (linear memory bounded, zero syscalls). Runtime: WAMR (see ADR-0007). Distribution: signed Git registries (ed25519).

**This is app-level, not framework-level.** Klaxon exposes an abstract `PluginRuntime` interface. The app provides the WAMR implementation.

## Rationale

| Criterion | WASM sandbox | Native plugins (Qt-style) | Lua/JS embedded |
|---|---|---|---|
| Sandbox | Structural (memory + no syscalls) | Disciplinary (trust the plugin) | Disciplinary |
| Language-agnostic | Yes (any language → WASM) | No (Zig/C only) | No (Lua/JS only) |
| Hot update | Yes (swap .wasm, no restart) | No (restart required) | Partial |
| iOS compatible | Yes (no JIT) | Yes | Yes |
| Perf (I/O-bound scraping) | Sufficient | Fastest | Medium |
| Perf (compute-heavy) | Slow (interpreter) | Fast | Medium |

WASM wins for a community plugin ecosystem: language-agnostic, sandboxed, hot-updatable, iOS-compatible.

## Plugin contract (v0.1, ported from Auqw `crates/plugin-host`)

- **11 capabilities**: catalog.search, catalog.metadata, catalog.artwork, catalog.entity, catalog.suggest, playback.resolve, playback.candidates, lyrics.plain, lyrics.synced, radio.seed + tracker
- **Budgets**: fuel 200M/2B, StoreLimits 64 MiB + max_table_elements 64K, deadline 30s, 32 HTTP calls (10s timeout), 8 MiB in+out per call, 5 MiB per artifact
- **Services**: http, kv, clock, pot (provided by host)
- **ABI**: zero-import, no start. `vh_call` v0.1.
- **Distribution**: Git repo + index.json (signed ed25519) + .wasm (sha256 verified) + KEYINFO

## Consequences

- Framework: abstract `PluginRuntime` interface only.
- App: WAMR implementation, registry scanning, signature verification.
- Governance: kill-switch (signed blocklist), reporting (in-app button → GitHub issue).
- SDK: separate repo (`klaxon-plugin-sdk`), independent semver.
