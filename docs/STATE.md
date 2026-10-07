# State Management — Signals (Phase 1a)

> Fine-grained reactivity, SolidJS-style. Built complete from day one: no BLoC/Riverpod migration later.

Module: `src/ui/state.zig`. Decisions: ADR-0004 (retained tree), ADR-0009 (C ABI shape).

## Primitives

| Primitive | What | Use |
|---|---|---|
| `Signal(T)` | Observable value. `get()` tracks, `set()` notifies (no-op if unchanged) | Any reactive value |
| `Memo(T, compute)` | Cached derived value, recomputed when a dependency changes | Derived state |
| `Effect` | Runs a fn ptr, re-runs when any read dependency changes | Side effects |
| `Store(T)` | Process-global signal per type (first `get(initial)` wins) | Cross-widget shared state |

## How tracking works

Reading a signal inside an `Effect` subscribes that effect (thread-local
`current_effect`). `set()` bumps the version and notifies a **snapshot** of
subscribers (they may subscribe/unsubscribe during notify). A `set()` with an
equal value notifies nobody — no spurious re-renders.

Widgets don't build/rebuild: they are **retained nodes** that read signals and
mark themselves dirty on change:

```zig
const sig = try ui.state.Signal(bool).init(allocator, false);
const node = try widgets.input.toggle(allocator, sig, onChanged, .{});
ui.state.bindNode(node, sig); // sig.set() → node.markDirty() → re-render
```

`bindNode` subscribes the node. **Unsubscribe on deinit** (no GC — a dangling
subscription is a use-after-free):

```zig
fn deinit(n: *ui.node.Node) void {
    s.sig.unsubscribe(.{ .node = n });
    ...
}
```

Signal-driven widgets (Toggle, Checkbox, Radio, Slider, Chip) follow this
pattern; see `src/widgets/input.zig`.

## Subscriber shape (ADR-0009)

Subscribers are a C-ABI-compatible union — plain data, fn ptrs + userdata —
so guest languages can subscribe through thin bindings:

```zig
pub const Callback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque) void,
    userdata: ?*anyopaque,
};
pub const Subscriber = union(enum) { effect: *Effect, node: *Node, callback: Callback };
```

## Performance rule

The hot path (frame loop) never crosses this layer. Subscriptions fire on
**change** (cold path), not per frame. Reading a signal outside an effect is
free (no tracking).

## Tests

`zig build test` — signal set/get + version + no-op on equal, effect
auto-subscribe/re-run, memo recompute, callback subscriber, store global,
`bindNode` marks dirty.
