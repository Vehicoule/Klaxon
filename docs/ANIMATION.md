# Animations — Springs, Tweens, SIMD, Timeline (Phase 1e)

Modules: `src/ui/anim.zig` (physics + curves + SIMD + Timeline),
`src/widgets/anim.zig` (AnimatedContainer / AnimatedOffset / AnimatedScale).
Host integration: `src/host.zig` (timeline tick, layout pass, dirty-rect,
frame budget).

## Design

- **Time-based, not step-based.** An animation evaluates its value at
  `now - start`, so the tick rate never changes the result — no drift, no
  accumulated error. The host ticks the timeline once per loop iteration
  (~120 Hz while animating); deadlines (stagger, long-press) compare against
  the same clock and are exact. The roadmap's "240 Hz" is the timeline's
  clock resolution, not a required wakeup rate.
- **Values are `@Vector(4, f32)`.** One animation drives up to 4 properties
  at once (x/y/w/h, RGBA, …) with SIMD math (`lerp4`, `lerpColor`).
- **Channels.** An animation carries a `channel` (what it writes). Playing on
  a busy channel cancels the previous animation — retargeting mid-flight is
  free and never double-writes.
- **ADR-0009 shape.** Callbacks are fn ptr + userdata.

## Spring (M3E physics, closed form)

`x'' = -(k/m)(x - target) - (c/m) x'`, solved exactly in all three regimes
(underdamped / critically damped / overdamped). Presets:

| Preset | stiffness | damping | mass | feel |
|---|---|---|---|---|
| `Spring{}` (default) | 380 | 32 | 1 | snappy, slight overshoot |
| `Spring.gentle` | 180 | 24 | 1 | soft |
| `Spring.bouncy` | 700 | 40 | 1 | springy |

Springs are asymptotic: an animation completes when the envelope decays
below 0.1 units per lane (`springSettleMs`, computed at play time), then
snaps to the exact target — no visible pop.

## Tween (driven curves)

`Motion = .{ .tween = .{ .duration_ms, .curve } }` interpolates
`from → to` over the duration with a curve:

| Curve | shape |
|---|---|
| `.linear` | identity |
| `.ease_in` / `.ease_out` / `.ease_in_out` | quadratic |
| `.standard` | M3 standard: cubic-bezier(0.2, 0, 0, 1) |
| `.emphasized` | M3 emphasized: cubic-bezier(0.05, 0.7, 0.1, 1) |
| `.{ .custom = fn }` | any `fn (t: f32) f32` (no userdata — hot path) |

Cubic beziers are solved with Newton-Raphson + bisection (exact, stateless).

## Timeline

Process-global (`anim.setCurrent`, installed by the host — same pattern as
the input router). The host ticks it every loop iteration.

| Feature | API |
|---|---|
| Play | `tl.play(.{ .kind = …, .from = …, .channel = …, .on_update = …, .on_complete = … })` → id |
| Cancel | `tl.cancel(id)` / `tl.cancelChannel(ch)` (widget teardown) |
| Stagger | `.delay_ms` (start is delayed; the value holds `from` until then) |
| Priority | `.priority = .low` — paused while `frame_overrun` (1e.7) |
| Tickers | `tl.addTicker/removeTicker` — time-based subscribers (gesture arenas) |

## Animated widgets (implicit animations)

The app drives a **Signal**; the widget animates its displayed value toward
the target and repaints/relayouts as it ticks. Without a timeline (unit
tests), target changes snap to the target.

```zig
const w = try ui.state.Signal(f32).init(allocator, 10);
const box = try widgets.anim.animatedContainer(allocator, .{
    .width = w,
    .motion = .{ .spring = .{} }, // or .{ .tween = .{ .duration_ms = 300, .curve = .{ .ease = .standard } } }
});
w.set(40); // animates 10 → 40
```

| Widget | Animates | Mechanism |
|---|---|---|
| `AnimatedContainer` | width, height (one SIMD animation, lanes 0/1), color (SIMD channel lerp) | measure/paint read display signals; display changes mark dirty + layout-dirty |
| `AnimatedOffset` | child offset (dx, dy) | paint-time canvas transform (`kx_save/translate/restore`); damage = swept region |
| `AnimatedScale` | child scale (uniform, pivot = center) | paint-time canvas transform; damage = bbox of old/new scaled regions |

Both transform widgets wrap the children's paint via the vtable's
`pre_children_paint` / `post_children_paint` hooks — no layout invalidation,
so dirty-rect repaints only the swept region.

## Dirty-rect (1e.6)

The surface is **retained** between frames (the host never clears). Every
dirty mark unions its rect into the root's damage accumulator
(`Node.markDirty` → own bounds; `Node.markDirtyRect` → explicit rect, e.g.
an offset sweep). The host repaints the whole tree **clipped** to the
damage region (`kx_clip_rect`): Skia discards out-of-region draws, untouched
pixels stay. A layout pass (size/structure changes) forces a full repaint.

## Frame budget (1e.7)

Rendering is paced to the **8.3 ms budget** (~120 fps target, the metrics
gate): `paceFrame` delays only the remainder of the budget; slow frames run
unthrottled. When a frame's paint exceeds the budget, the timeline's
`frame_overrun` flag pauses `.low`-priority animations until frames recover
(time-based: they resume without a glitch).

## Gestures

The `GestureDetector` registers its arena as a timeline ticker: long-press
fires **exactly** at the 500 ms threshold (no pointer event needed). Without
a timeline it keeps the event-driven fallback (fires on the first event
after the threshold).

## P0 deviations

- **Tap fires immediately** (no tap-delay timer): a second tap does not
  cancel the first `on_tap`. A same-event double-tap suppresses the tap.
- **Size animations repaint fully** (layout moves content — the dirty-rect
  covers the old + new regions only when layout is untouched, i.e. offsets,
  scales, colors).
- **Opacity/hero** need a layer/composite ABI (`kx_save_layer`) — later phase.

## Tests

`zig build test` — spring closed form (initial state, overshoot, settle,
critical/overdamped, SIMD lanes, settle time), tween endpoints/midpoint,
curves (incl. cubic-bezier monotonicity, custom fn), SIMD lerp4/lerpColor,
timeline (play/tick/complete, stagger, cancel, channel retarget, frame
overrun, tickers), node damage accumulation, animated widgets (size/color
through manual ticks, retarget, teardown-cancel, offset/scale goldens),
gesture arena tick + detector ticker registration.
