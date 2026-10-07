# Gestures — GestureArena + Recognizers (Phase 1d)

Module: `src/ui/gestures.zig` (arena + recognizers), `src/widgets/gestures.zig`
(`GestureDetector` wrapper). Input routing: `src/ui/input.zig`.

## Flow

```
SDL3 pointer events (mouse + multi-touch fingers, with pointer id + timestamp)
  → InputRouter (per-pointer capture, bubbling)
  → GestureDetector.on_pointer
  → GestureArena.feed
  → recognizers (state machines) → first to claim wins → callbacks
```

## Recognizers

| Recognizer | Trigger | Callback |
|---|---|---|
| Tap | down + up within slop, < 200 ms | `on_tap` |
| DoubleTap | 2 taps < 300 ms apart, within slop | `on_double_tap` |
| LongPress | down ≥ 500 ms without moving beyond slop | `on_long_press` |
| Pan | move > slop → drag | `on_pan_start` / `on_pan_update(dx, dy)` / `on_pan_end(vx, vy)` |
| Swipe | pan released with velocity > 500 px/s | `on_swipe(dir, vx, vy)` |
| Pinch | 2 pointers → scale = current / initial distance | `on_pinch(scale)` |
| Rotate | 2 pointers → angle delta (atan2) | `on_rotate(delta_radians)` |

## Tuned constants (P0: px == dp)

| Constant | Value |
|---|---|
| `SLOP` | 12 px |
| `TAP_TIMEOUT_MS` | 200 |
| `DOUBLE_TAP_MS` | 300 |
| `LONG_PRESS_MS` | 500 |
| `SWIPE_VELOCITY` | 500 px/s |
| `VELOCITY_WINDOW_MS` | 100 (velocity estimation window) |

## Usage

```zig
const root = try widgets.gestures.gestureDetector(allocator, .{
    .callbacks = .{
        .on_tap = .{ .fn_ptr = onTap, .userdata = self },
        .on_pan_update = .{ .fn_ptr = onPan, .userdata = self },
    },
});
root.add(child);
```

Callbacks are ADR-0009 shaped: fn ptr + userdata, payloads as extra args.

## Arbitration

Recognizers within a detector compete; when one claims, it wins and the
others have already rejected themselves (their state machines are mutually
exclusive by construction). Single-pointer recognizers follow only the
pointer they started with; pinch/rotate track two pointers by id. A
double-tap suppresses the same-event single tap. `cancel()` (pointer leave /
popup barrier) resets every in-flight gesture.

## P0 deviations (fixed by later phases)

- **Long-press has no platform timer**: it fires on the first event after the
  500 ms threshold (a still-held pointer fires on release). The 240 Hz
  timeline (Phase 1e) will drive it precisely.
- **Single tap fires immediately**: if a second tap follows, the first tap
  has already fired (no tap-delay timer).
- **Register pan XOR swipe** on the same detector (both track the same drag).
- Velocity is average-over-window (100 ms), not Flutter's weighted tracker.

## Tests

`zig build test` — recognizer state machines with synthetic timestamps (tap
slop/timeout, double-tap interval, long-press threshold, pan deltas +
velocity, swipe fling threshold + direction, pinch scale, rotate angle),
arena resolution (double-tap suppression, cancel), multi-pointer capture in
the router, and a golden test (tap → signal → child repaints).
