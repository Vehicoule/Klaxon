# ADR-0004 — Retained widget tree with dirty flags

**Status**: Accepted
**Date**: 2026-10-06

## Context

UI frameworks use two widget tree models: **retained** (Qt, Slint) or **immutable** (Flutter, Compose, SwiftUI). The choice affects memory, GC requirements, and rebuild strategy.

## Decision

**Retained tree with dirty flags.** Not immutable.

## Rationale

| Criterion | Retained (Qt, Slint) | Immutable (Flutter, Compose) |
|---|---|---|
| Memory | Widgets persist, no recreation | Widgets recreated per frame → allocations |
| GC required | No | Yes (Dart GC, or Compose runtime) |
| Rebuild strategy | `markDirty()` → targeted redraw | Diff algorithm on entire tree |
| Zero-alloc frame loop | Possible | Impossible (allocations per rebuild) |
| Complexity | Simpler to reason about | Hidden complexity in diff algorithm |
| Zig fit | Perfect (no GC, explicit allocators) | Poor (would need arena per frame) |

**Zig has no GC.** An immutable tree would allocate hundreds of widget objects per frame. The retained tree with dirty flags enables:
- Zero allocations in steady-state (gate: `allocs_per_frame == 0`)
- Targeted redraw (only dirty subtrees)
- Explicit memory ownership (arena per frame, pools per subsystem)

## Model

```zig
pub const Node = struct {
    parent: ?*Node,
    children: std.ArrayList(*Node),
    bounds: Rect,
    dirty: bool,           // needs redraw?
    layout_dirty: bool,    // needs relayout?
    paint: Paint,
    semantics: Semantics,
    on_event: ?EventHandler,
    gesture: ?GestureHandler,
    userdata: ?*anyopaque,

    pub fn markDirty(n: *Node) void {
        n.dirty = true;
        if (n.parent) |p| p.markDirty();
    }
};
```

## Consequences

- Widget state lives in `userdata` (persists across frames).
- `markDirty()` propagates up the tree. The frame loop draws only dirty subtrees.
- Layout runs only when `layout_dirty` (not per frame).
- Memory ownership is explicit: arena per frame, pools per subsystem, GPA in debug.
