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
| Pan | move > slop → drag | `on_pan_start(dx, dy)` / `on_pan_update(dx, dy)` / `on_pan_end(vx, vy, dx, dy)` |
| Swipe | pan released with velocity > 500 px/s | `on_swipe(dir, vx, vy)` |
| Pinch | 2 pointers → scale = current / initial distance | `on_pinch(scale)` |
| Rotate | 2 pointers → per-move angle delta (atan2, wrapped to [-π, π]) | `on_rotate(delta_radians)` |

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

Recognizers within a detector compete for the same pointer(s):

- **Two-pointer gestures (pinch/rotate) are fed first and fire
  immediately** — they can co-fire (scale + angle on the same move). When
  one accepts (second finger down), it **claims the interaction**: every
  single-pointer recognizer is reset and skipped while it is active, so a
  pinch never also fires a tap or a pan.
- **Ongoing single-pointer gestures** (`pan_start`, `pan_update`) fire
  immediately. **Terminal gestures** (tap, double-tap, long-press, pan-end,
  swipe) are collected and resolved after the pass: a double-tap suppresses
  the same-event single tap.
- Single-pointer recognizers follow only the pointer they started with;
  pinch/rotate track two pointers by id. A third finger is ignored, and a
  replacement finger re-enters the gesture with a fresh initial
  distance/angle.
- `cancel()` (pointer leave / popup barrier) resets every in-flight gesture.

### Pan payloads

The full drag displacement is the sum of the three payloads:
`pan_start.dx/dy` (down → claiming move) + Σ `pan_update.dx/dy` +
`pan_end.dx/dy` (last move → up). `pan_end` also carries the release velocity
(px/s, estimated over the last 100 ms).

## P0 deviations

- **Long-press precision**: the detector registers its arena as a timeline
  ticker (Phase 1e) — long-press fires exactly at the 500 ms threshold. Without
  a timeline it falls back to event-driven (first event after the threshold).
- **Single tap fires immediately**: if a second tap follows, the first tap
  has already fired (no tap-delay timer).
- **Register pan XOR swipe** on the same detector (both track the same drag).
- Velocity is average-over-window (100 ms), not Flutter's weighted tracker.

## Tests

`zig build test` — recognizer state machines with synthetic timestamps (tap
slop/timeout, double-tap interval, long-press threshold, pan deltas +
velocity, swipe fling threshold + direction, pinch scale, rotate angle +
±π wrap), arena resolution (double-tap suppression, cancel, pinch/rotate
co-fire, pinch claims the interaction so no tap fires), multi-pointer
capture in the router, and a golden test (tap → signal → child repaints).
