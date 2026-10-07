// Gestures (Phase 1d) — GestureArena + recognizers.
//
// Pointer events (ui/input.zig, multi-touch) → GestureArena → recognizers →
// callbacks. The arena arbitrates conflicts: two-pointer recognizers
// (pinch/rotate) are fed first and co-fire; when one accepts it claims the
// interaction (single-pointer recognizers are reset and skipped while it is
// active). Among single-pointer recognizers, ongoing gestures (pan) fire
// immediately and terminal ones (tap, …) are resolved after the pass
// (double-tap suppresses the same-event tap).
//
// Recognizers (tuned constants below; P0: px == dp, density lands with themes):
//   Tap        down + up within slop and < 200 ms
//   DoubleTap  two taps < 300 ms apart, within slop
//   LongPress  down ≥ 500 ms without moving beyond slop
//   Pan        move > slop → drag (start / update deltas / end velocity)
//   Swipe      pan released with velocity > 500 px/s (dominant axis)
//   Pinch      2 pointers → scale = current distance / initial distance
//   Rotate     2 pointers → per-move atan2 delta, wrapped to [-π, π]
//
// P0 deviations (documented):
//   - Without a timeline, long-press fires on the first event after the
//     500 ms threshold (a still-held pointer fires on release). With the
//     host's timeline (Phase 1e) the arena is ticked every loop iteration
//     and long-press fires exactly at the threshold.
//   - A single tap fires immediately; if a second tap follows, the first tap
//     has already fired (no tap-delay timer). The same-event second tap is
//     suppressed for on_tap when on_double_tap fires.
//   - Register pan XOR swipe on the same detector (both track the same drag).
const std = @import("std");
const input = @import("input.zig");

// --- Tuned constants (1d.6) ---

pub const SLOP: f32 = 12; // movement tolerance before a gesture claims
pub const TAP_TIMEOUT_MS: u64 = 200; // max duration of a tap
pub const DOUBLE_TAP_MS: u64 = 300; // max interval between two taps
pub const LONG_PRESS_MS: u64 = 500; // hold duration for a long-press
pub const SWIPE_VELOCITY: f32 = 500; // px/s fling threshold
pub const VELOCITY_WINDOW_MS: u64 = 100; // velocity estimation window

// --- Callbacks (ADR-0009 shape: fn ptr + userdata; payloads as extra args) ---

const Callback = ui_state.Callback;
const ui_state = @import("state.zig");

pub const PanCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, dx: f32, dy: f32) void,
    userdata: ?*anyopaque,
};

pub const PanStartCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, dx: f32, dy: f32) void,
    userdata: ?*anyopaque,
};

pub const PanEndCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, vx: f32, vy: f32, dx: f32, dy: f32) void,
    userdata: ?*anyopaque,
};

pub const SwipeDirection = enum { left, right, up, down };

pub const SwipeCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, dir: SwipeDirection, vx: f32, vy: f32) void,
    userdata: ?*anyopaque,
};

pub const PinchCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, scale: f32) void,
    userdata: ?*anyopaque,
};

pub const RotateCallback = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, delta_radians: f32) void,
    userdata: ?*anyopaque,
};

pub const GestureCallbacks = struct {
    on_tap: ?Callback = null,
    on_double_tap: ?Callback = null,
    on_long_press: ?Callback = null,
    on_pan_start: ?PanStartCallback = null,
    on_pan_update: ?PanCallback = null,
    on_pan_end: ?PanEndCallback = null,
    on_swipe: ?SwipeCallback = null,
    on_pinch: ?PinchCallback = null,
    on_rotate: ?RotateCallback = null,
};

// --- Fire (a recognizer claimed the gesture) ---

pub const Fire = union(enum) {
    tap,
    double_tap,
    long_press,
    pan_start: struct { dx: f32, dy: f32 }, // down → claiming move
    pan_update: struct { dx: f32, dy: f32 },
    pan_end: struct { vx: f32, vy: f32, dx: f32, dy: f32 }, // velocity + last move → up
    swipe: struct { dir: SwipeDirection, vx: f32, vy: f32 },
    pinch: struct { scale: f32 },
    rotate: struct { delta: f32 }, // per-move delta, wrapped to [-π, π]
};

// --- Recognizer (one state machine per gesture kind) ---

pub const Kind = enum { tap, double_tap, long_press, pan, swipe, pinch, rotate };

const Sample = struct { x: f32, y: f32, t: u64 };

const TrackedPointer = struct { id: u64, x: f32, y: f32 };

pub const Recognizer = struct {
    kind: Kind,
    state: enum { idle, possible, accepted, rejected } = .idle,
    // single-pointer tracking (the recognizer follows only its own pointer)
    tracking: ?u64 = null,
    start_x: f32 = 0,
    start_y: f32 = 0,
    start_time: u64 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    // velocity ring (samples inside VELOCITY_WINDOW_MS) — every read is
    // bounded by sample_len, so the slots start undefined
    samples: [8]Sample = undefined,
    sample_len: u8 = 0,
    // double-tap memory (survives cancels)
    has_last_tap: bool = false,
    last_tap_time: u64 = 0,
    last_tap_x: f32 = 0,
    last_tap_y: f32 = 0,
    // multi-pointer state (pinch / rotate)
    ptr_a: ?TrackedPointer = null,
    ptr_b: ?TrackedPointer = null,
    initial_distance: f32 = 0,
    initial_angle: f32 = 0,
    last_angle: f32 = 0,
    long_press_fired: bool = false,

    pub fn reset(rec: *Recognizer) void {
        rec.state = .idle;
        rec.tracking = null;
        rec.ptr_a = null;
        rec.ptr_b = null;
        rec.long_press_fired = false;
        rec.sample_len = 0;
        // double-tap memory is not gesture state: it survives cancels.
    }

    /// Feed one pointer event. Returns the fired gesture, if this recognizer
    /// claimed it.
    pub fn feed(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
        return switch (rec.kind) {
            .tap => feedTap(rec, ev),
            .double_tap => feedDoubleTap(rec, ev),
            .long_press => feedLongPress(rec, ev),
            .pan, .swipe => feedPan(rec, ev),
            .pinch => feedPinch(rec, ev),
            .rotate => feedRotate(rec, ev),
        };
    }

    /// Timeline tick (Phase 1e): fires time-based gestures precisely — a
    /// long-press fires exactly at the threshold, no pointer event needed
    /// (the host ticks the timeline every loop iteration). Other recognizers
    /// are purely event-driven and tick nothing.
    pub fn tick(rec: *Recognizer, now_ms: u64) ?Fire {
        if (rec.kind != .long_press) return null;
        if (rec.state != .possible or rec.long_press_fired) return null;
        if (now_ms - rec.start_time < LONG_PRESS_MS) return null;
        rec.long_press_fired = true;
        rec.state = .idle;
        rec.tracking = null;
        return .long_press;
    }
};

fn dist(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return @sqrt(dx * dx + dy * dy);
}

/// Single-pointer recognizers follow only the pointer they started with.
fn follows(rec: *Recognizer, ev: input.PointerEvent) bool {
    if (rec.tracking) |p| return ev.pointer == p;
    return ev.phase == .down; // idle: only a down can start tracking
}

fn beginDown(rec: *Recognizer, ev: input.PointerEvent) void {
    rec.state = .possible;
    rec.tracking = ev.pointer;
    rec.start_x = ev.x;
    rec.start_y = ev.y;
    rec.start_time = ev.time_ms;
    rec.last_x = ev.x;
    rec.last_y = ev.y;
}

fn addSample(rec: *Recognizer, ev: input.PointerEvent) void {
    if (rec.sample_len == rec.samples.len) {
        std.mem.copyForwards(Sample, rec.samples[0 .. rec.samples.len - 1], rec.samples[1..rec.samples.len]);
        rec.samples[rec.samples.len - 1] = .{ .x = ev.x, .y = ev.y, .t = ev.time_ms };
    } else {
        rec.samples[rec.sample_len] = .{ .x = ev.x, .y = ev.y, .t = ev.time_ms };
        rec.sample_len += 1;
    }
}

/// Two-pointer tracking: fill slots on down — when the pair is complete the
/// gesture (re-)accepts with fresh initial distance/angle (a replacement
/// finger re-enters the gesture). Third pointers are ignored.
fn trackDown(rec: *Recognizer, ev: input.PointerEvent) void {
    if (rec.ptr_a == null) {
        rec.ptr_a = .{ .id = ev.pointer, .x = ev.x, .y = ev.y };
    } else if (rec.ptr_b == null and ev.pointer != rec.ptr_a.?.id) {
        rec.ptr_b = .{ .id = ev.pointer, .x = ev.x, .y = ev.y };
    }
    if (rec.ptr_a != null and rec.ptr_b != null) {
        const a = rec.ptr_a.?;
        const b = rec.ptr_b.?;
        rec.initial_distance = dist(a.x, a.y, b.x, b.y);
        rec.initial_angle = std.math.atan2(b.y - a.y, b.x - a.x);
        rec.last_angle = rec.initial_angle;
        rec.state = .accepted;
    }
}

/// Two-pointer tracking: clear the slot of a lifting pointer. Returns true
/// when a tracked pointer lifted (the gesture ends); unrelated fingers are
/// ignored.
fn trackUp(rec: *Recognizer, ev: input.PointerEvent) bool {
    var lifted = false;
    if (rec.ptr_a) |a| {
        if (a.id == ev.pointer) {
            rec.ptr_a = null;
            lifted = true;
        }
    }
    if (rec.ptr_b) |b| {
        if (b.id == ev.pointer) {
            rec.ptr_b = null;
            lifted = true;
        }
    }
    if (lifted) rec.state = .idle;
    return lifted;
}

/// Wrap an angle delta into [-π, π].
fn wrapAngle(d: f32) f32 {
    var r = d;
    const two_pi: f32 = 2 * std.math.pi;
    while (r > std.math.pi) r -= two_pi;
    while (r < -std.math.pi) r += two_pi;
    return r;
}

/// Update the tracked position of `ev.pointer` (ptr_a/ptr_b). Returns false
/// if the pointer is not part of the gesture.
fn trackMove(rec: *Recognizer, ev: input.PointerEvent) bool {
    if (rec.ptr_a) |*a| {
        if (a.id == ev.pointer) {
            a.x = ev.x;
            a.y = ev.y;
            return true;
        }
    }
    if (rec.ptr_b) |*b| {
        if (b.id == ev.pointer) {
            b.x = ev.x;
            b.y = ev.y;
            return true;
        }
    }
    return false;
}

/// Velocity (px/s) over the samples inside the estimation window.
fn velocity(rec: *Recognizer, now: u64) struct { vx: f32, vy: f32 } {
    if (rec.sample_len == 0) return .{ .vx = 0, .vy = 0 };
    var first = rec.samples[rec.sample_len - 1];
    for (rec.samples[0..rec.sample_len]) |s| {
        if (now - s.t <= VELOCITY_WINDOW_MS) {
            first = s;
            break;
        }
    }
    const last = rec.samples[rec.sample_len - 1];
    const dt_ms = last.t - first.t;
    if (dt_ms == 0) return .{ .vx = 0, .vy = 0 };
    const dt: f32 = @as(f32, @floatFromInt(dt_ms)) / 1000;
    return .{ .vx = (last.x - first.x) / dt, .vy = (last.y - first.y) / dt };
}

// --- Tap ---

fn feedTap(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    if (!follows(rec, ev)) return null;
    switch (ev.phase) {
        .down => {
            beginDown(rec, ev);
            return null;
        },
        .move => {
            if (rec.state == .possible and dist(ev.x, ev.y, rec.start_x, rec.start_y) > SLOP) {
                rec.state = .rejected;
            }
            rec.last_x = ev.x;
            rec.last_y = ev.y;
            return null;
        },
        .up => {
            const ok = rec.state == .possible and
                dist(ev.x, ev.y, rec.start_x, rec.start_y) <= SLOP and
                ev.time_ms - rec.start_time < TAP_TIMEOUT_MS;
            rec.state = .idle;
            rec.tracking = null;
            return if (ok) .tap else null;
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- DoubleTap ---

fn feedDoubleTap(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    if (!follows(rec, ev)) return null;
    switch (ev.phase) {
        .down => {
            beginDown(rec, ev);
            return null;
        },
        .move => {
            if (rec.state == .possible and dist(ev.x, ev.y, rec.start_x, rec.start_y) > SLOP) {
                rec.state = .rejected;
            }
            return null;
        },
        .up => {
            const is_tap = rec.state == .possible and
                dist(ev.x, ev.y, rec.start_x, rec.start_y) <= SLOP and
                ev.time_ms - rec.start_time < TAP_TIMEOUT_MS;
            rec.state = .idle;
            rec.tracking = null;
            if (!is_tap) {
                rec.has_last_tap = false;
                return null;
            }
            if (rec.has_last_tap and
                ev.time_ms - rec.last_tap_time < DOUBLE_TAP_MS and
                dist(ev.x, ev.y, rec.last_tap_x, rec.last_tap_y) <= SLOP)
            {
                rec.has_last_tap = false;
                return .double_tap;
            }
            rec.last_tap_time = ev.time_ms;
            rec.last_tap_x = ev.x;
            rec.last_tap_y = ev.y;
            rec.has_last_tap = true;
            return null;
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- LongPress (P0: fires on the first event after the threshold) ---

fn feedLongPress(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    if (!follows(rec, ev)) return null;
    switch (ev.phase) {
        .down => {
            beginDown(rec, ev);
            rec.long_press_fired = false;
            return null;
        },
        .move => {
            if (rec.state != .possible) return null;
            if (dist(ev.x, ev.y, rec.start_x, rec.start_y) > SLOP) {
                rec.state = .rejected;
                return null;
            }
            if (!rec.long_press_fired and ev.time_ms - rec.start_time >= LONG_PRESS_MS) {
                rec.long_press_fired = true;
                rec.state = .idle;
                rec.tracking = null;
                return .long_press;
            }
            return null;
        },
        .up => {
            const ok = rec.state == .possible and !rec.long_press_fired and
                dist(ev.x, ev.y, rec.start_x, rec.start_y) <= SLOP and
                ev.time_ms - rec.start_time >= LONG_PRESS_MS;
            rec.state = .idle;
            rec.tracking = null;
            return if (ok) .long_press else null;
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- Pan / Swipe (same drag state machine; swipe adds the fling threshold) ---

fn feedPan(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    if (!follows(rec, ev)) return null;
    switch (ev.phase) {
        .down => {
            beginDown(rec, ev);
            rec.sample_len = 0;
            addSample(rec, ev);
            return null;
        },
        .move => {
            if (rec.state == .possible) {
                if (dist(ev.x, ev.y, rec.start_x, rec.start_y) > SLOP) {
                    rec.state = .accepted;
                    rec.last_x = ev.x; // the claiming move is the delta origin
                    rec.last_y = ev.y;
                    addSample(rec, ev);
                    // Report the claiming displacement: the full drag is
                    // pan_start.dx/dy + Σ pan_update + pan_end.dx/dy.
                    return .{ .pan_start = .{ .dx = ev.x - rec.start_x, .dy = ev.y - rec.start_y } };
                }
                return null;
            }
            if (rec.state == .accepted) {
                const dx = ev.x - rec.last_x;
                const dy = ev.y - rec.last_y;
                rec.last_x = ev.x;
                rec.last_y = ev.y;
                addSample(rec, ev);
                return .{ .pan_update = .{ .dx = dx, .dy = dy } };
            }
            return null;
        },
        .up => {
            if (rec.state != .accepted) {
                rec.state = .idle;
                rec.tracking = null;
                return null;
            }
            rec.state = .idle;
            rec.tracking = null;
            addSample(rec, ev);
            const v = velocity(rec, ev.time_ms);
            // The final displacement (last move → up) rides on pan_end.
            const dx = ev.x - rec.last_x;
            const dy = ev.y - rec.last_y;
            if (rec.kind == .swipe and @max(@abs(v.vx), @abs(v.vy)) > SWIPE_VELOCITY) {
                const dir: SwipeDirection = if (@abs(v.vx) >= @abs(v.vy))
                    (if (v.vx > 0) SwipeDirection.right else SwipeDirection.left)
                else
                    (if (v.vy > 0) SwipeDirection.down else SwipeDirection.up);
                return .{ .swipe = .{ .dir = dir, .vx = v.vx, .vy = v.vy } };
            }
            return .{ .pan_end = .{ .vx = v.vx, .vy = v.vy, .dx = dx, .dy = dy } };
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- Pinch (2 pointers → scale) ---

fn feedPinch(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    switch (ev.phase) {
        .down => {
            trackDown(rec, ev);
            return null;
        },
        .move => {
            if (rec.state != .accepted or !trackMove(rec, ev)) return null;
            const a = rec.ptr_a.?;
            const b = rec.ptr_b.?;
            if (rec.initial_distance <= 0) return null;
            return .{ .pinch = .{ .scale = dist(a.x, a.y, b.x, b.y) / rec.initial_distance } };
        },
        .up => {
            _ = trackUp(rec, ev); // ends when a tracked pointer lifts
            return null;
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- Rotate (2 pointers → angle delta) ---

fn feedRotate(rec: *Recognizer, ev: input.PointerEvent) ?Fire {
    switch (ev.phase) {
        .down => {
            trackDown(rec, ev);
            return null;
        },
        .move => {
            if (rec.state != .accepted or !trackMove(rec, ev)) return null;
            const a = rec.ptr_a.?;
            const b = rec.ptr_b.?;
            const angle = std.math.atan2(b.y - a.y, b.x - a.x);
            // Per-move delta wrapped to [-π, π]: no jump when crossing ±π.
            const delta = wrapAngle(angle - rec.last_angle);
            rec.last_angle = angle;
            return .{ .rotate = .{ .delta = delta } };
        },
        .up => {
            _ = trackUp(rec, ev); // ends when a tracked pointer lifts
            return null;
        },
        else => {
            rec.reset();
            return null;
        },
    }
}

// --- GestureArena — feeds recognizers, resolves, invokes callbacks ---

pub const GestureArena = struct {
    recognizers: [8]Recognizer,
    count: u8 = 0,
    callbacks: GestureCallbacks,

    /// Build the arena from the callbacks: one recognizer per gesture kind
    /// with at least one callback set.
    pub fn init(callbacks: GestureCallbacks) GestureArena {
        var arena = GestureArena{ .recognizers = undefined, .callbacks = callbacks };
        const cbs = callbacks;
        arena.push(.tap, cbs.on_tap != null);
        arena.push(.double_tap, cbs.on_double_tap != null);
        arena.push(.long_press, cbs.on_long_press != null);
        arena.push(.pan, cbs.on_pan_start != null or cbs.on_pan_update != null or cbs.on_pan_end != null);
        arena.push(.swipe, cbs.on_swipe != null);
        arena.push(.pinch, cbs.on_pinch != null);
        arena.push(.rotate, cbs.on_rotate != null);
        return arena;
    }

    fn push(arena: *GestureArena, kind: Kind, enabled: bool) void {
        if (enabled and arena.count < arena.recognizers.len) {
            arena.recognizers[arena.count] = .{ .kind = kind };
            arena.count += 1;
        }
    }

    /// Feed one pointer event: recognizers compete; the first to claim wins.
    ///
    /// Arbitration policy:
    ///   - Two-pointer gestures (pinch/rotate) are fed first and are invoked
    ///     immediately — they can co-fire (scale + angle on the same move).
    ///     When one accepts, it claims the interaction: single-pointer
    ///     recognizers are rejected (a pinch must not also fire a tap) and
    ///     skipped while it is active.
    ///   - Ongoing single-pointer gestures (pan start/update) are invoked
    ///     immediately; terminal gestures (tap, double-tap, long-press,
    ///     pan-end, swipe) are collected and resolved after the pass:
    ///     double-tap suppresses the same-event tap.
    pub fn feed(arena: *GestureArena, ev: input.PointerEvent) void {
        if (ev.phase == .enter or ev.phase == .leave or ev.phase == .outside_down) {
            arena.cancel();
            return;
        }
        const cbs = &arena.callbacks;
        // Two-pointer gestures first.
        var two_finger_active = false;
        for (arena.recognizers[0..arena.count]) |*r| {
            if (r.kind != .pinch and r.kind != .rotate) continue;
            if (r.feed(ev)) |f| {
                switch (f) {
                    .pinch => |p| if (cbs.on_pinch) |cb| cb.fn_ptr(cb.userdata, p.scale),
                    .rotate => |p| if (cbs.on_rotate) |cb| cb.fn_ptr(cb.userdata, p.delta),
                    else => {},
                }
            }
            if (r.state == .accepted) {
                two_finger_active = true;
                // The two-finger gesture claims the interaction.
                for (arena.recognizers[0..arena.count]) |*o| {
                    if (o.kind == .pinch or o.kind == .rotate) continue;
                    o.reset();
                }
            }
        }
        if (two_finger_active) return; // single-pointer recognizers rejected
        // Single-pointer recognizers.
        var tap_fire = false;
        var double_tap_fire = false;
        var terminal: ?Fire = null;
        for (arena.recognizers[0..arena.count]) |*r| {
            if (r.kind == .pinch or r.kind == .rotate) continue;
            if (r.feed(ev)) |f| {
                switch (f) {
                    .tap => tap_fire = true,
                    .double_tap => double_tap_fire = true,
                    .pan_start => |p| if (cbs.on_pan_start) |cb| cb.fn_ptr(cb.userdata, p.dx, p.dy),
                    .pan_update => |p| if (cbs.on_pan_update) |cb| cb.fn_ptr(cb.userdata, p.dx, p.dy),
                    .long_press, .pan_end, .swipe => {
                        if (terminal == null) terminal = f;
                    },
                    else => {},
                }
            }
        }
        // Resolution: double-tap suppresses the same-event tap.
        if (double_tap_fire) {
            if (cbs.on_double_tap) |cb| cb.fn_ptr(cb.userdata);
        } else if (tap_fire) {
            if (cbs.on_tap) |cb| cb.fn_ptr(cb.userdata);
        } else if (terminal) |f| {
            switch (f) {
                .long_press => if (cbs.on_long_press) |cb| cb.fn_ptr(cb.userdata),
                .pan_end => |p| if (cbs.on_pan_end) |cb| cb.fn_ptr(cb.userdata, p.vx, p.vy, p.dx, p.dy),
                .swipe => |p| if (cbs.on_swipe) |cb| cb.fn_ptr(cb.userdata, p.dir, p.vx, p.vy),
                else => {},
            }
        }
    }

    /// Cancel every in-flight gesture (pointer left the detector / popup barrier).
    pub fn cancel(arena: *GestureArena) void {
        for (arena.recognizers[0..arena.count]) |*r| r.reset();
    }

    /// Timeline tick: advance time-based recognizers (long-press precision).
    pub fn tick(arena: *GestureArena, now_ms: u64) void {
        for (arena.recognizers[0..arena.count]) |*r| {
            if (r.tick(now_ms)) |f| {
                switch (f) {
                    .long_press => if (arena.callbacks.on_long_press) |cb| cb.fn_ptr(cb.userdata),
                    else => {},
                }
            }
        }
    }

    /// True while a time-based gesture is pending (a long-press waiting for
    /// its deadline) — the host bounds its idle wait while this is true.
    pub fn hasPendingTimeWork(arena: *const GestureArena) bool {
        for (arena.recognizers[0..arena.count]) |r| {
            if (r.kind == .long_press and r.state == .possible and !r.long_press_fired) return true;
        }
        return false;
    }
};

// --- tests (recognizer state machines, synthetic timestamps) ---

fn pev(phase: input.PointerPhase, x: f32, y: f32, t: u64, pointer: u64) input.PointerEvent {
    return .{ .phase = phase, .x = x, .y = y, .time_ms = t, .pointer = pointer };
}

test "tap fires on a quick up within slop, rejects on move or long hold" {
    var r = Recognizer{ .kind = .tap };
    try std.testing.expect(r.feed(pev(.down, 0, 0, 0, 0)) == null);
    try std.testing.expectEqual(Fire.tap, r.feed(pev(.up, 5, 5, 100, 0)).?);
    // moved beyond slop → no tap
    var r2 = Recognizer{ .kind = .tap };
    _ = r2.feed(pev(.down, 0, 0, 0, 0));
    _ = r2.feed(pev(.move, 50, 0, 50, 0));
    try std.testing.expect(r2.feed(pev(.up, 50, 0, 100, 0)) == null);
    // held too long → no tap
    var r3 = Recognizer{ .kind = .tap };
    _ = r3.feed(pev(.down, 0, 0, 0, 0));
    try std.testing.expect(r3.feed(pev(.up, 0, 0, 300, 0)) == null);
}

test "double tap fires on the second quick tap, not on the first" {
    var r = Recognizer{ .kind = .double_tap };
    _ = r.feed(pev(.down, 0, 0, 0, 0));
    try std.testing.expect(r.feed(pev(.up, 0, 0, 50, 0)) == null); // first tap: remembered
    _ = r.feed(pev(.down, 2, 2, 150, 0));
    try std.testing.expectEqual(Fire.double_tap, r.feed(pev(.up, 2, 2, 200, 0)).?);
    // a slow second tap is not a double tap
    var r2 = Recognizer{ .kind = .double_tap };
    _ = r2.feed(pev(.down, 0, 0, 0, 0));
    _ = r2.feed(pev(.up, 0, 0, 50, 0));
    _ = r2.feed(pev(.down, 0, 0, 500, 0));
    try std.testing.expect(r2.feed(pev(.up, 0, 0, 550, 0)) == null);
}

test "long press fires after the hold threshold" {
    var r = Recognizer{ .kind = .long_press };
    _ = r.feed(pev(.down, 0, 0, 0, 0));
    try std.testing.expect(r.feed(pev(.up, 0, 0, 100, 0)) == null); // too short
    var r2 = Recognizer{ .kind = .long_press };
    _ = r2.feed(pev(.down, 0, 0, 0, 0));
    try std.testing.expectEqual(Fire.long_press, r2.feed(pev(.up, 0, 0, 600, 0)).?);
    // moved beyond slop → rejected
    var r3 = Recognizer{ .kind = .long_press };
    _ = r3.feed(pev(.down, 0, 0, 0, 0));
    _ = r3.feed(pev(.move, 50, 0, 600, 0));
    try std.testing.expect(r3.feed(pev(.up, 50, 0, 700, 0)) == null);
}

test "pan: start on slop, update deltas, end with velocity + final delta" {
    var r = Recognizer{ .kind = .pan };
    _ = r.feed(pev(.down, 0, 0, 0, 0));
    try std.testing.expect(r.feed(pev(.move, 5, 0, 10, 0)) == null); // within slop
    // claiming move: reports the down → claim displacement (20, 0)
    const start = r.feed(pev(.move, 20, 0, 20, 0)).?;
    try std.testing.expectEqual(@as(f32, 20), start.pan_start.dx);
    try std.testing.expectEqual(@as(f32, 0), start.pan_start.dy);
    const upd = r.feed(pev(.move, 30, 0, 30, 0)).?;
    try std.testing.expectEqual(@as(f32, 10), upd.pan_update.dx);
    try std.testing.expectEqual(@as(f32, 0), upd.pan_update.dy);
    const end = r.feed(pev(.up, 40, 0, 40, 0)).?;
    // 40 px in 40 ms → 1000 px/s; final displacement 30 → 40 = 10
    try std.testing.expectApproxEqAbs(@as(f32, 1000), end.pan_end.vx, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), end.pan_end.vy, 0.001);
    try std.testing.expectEqual(@as(f32, 10), end.pan_end.dx);
}

test "swipe fires on a fast fling with the dominant direction" {
    var r = Recognizer{ .kind = .swipe };
    _ = r.feed(pev(.down, 0, 0, 0, 0));
    _ = r.feed(pev(.move, 20, 0, 10, 0)); // start
    _ = r.feed(pev(.move, 60, 0, 40, 0)); // fast: 60px in 40ms = 1500 px/s
    const f = r.feed(pev(.up, 60, 0, 40, 0)).?;
    try std.testing.expectEqual(SwipeDirection.right, f.swipe.dir);
    try std.testing.expect(f.swipe.vx > SWIPE_VELOCITY);
    // slow drag → no swipe (pan_end instead)
    var r2 = Recognizer{ .kind = .swipe };
    _ = r2.feed(pev(.down, 0, 0, 0, 0));
    _ = r2.feed(pev(.move, 20, 0, 10, 0));
    _ = r2.feed(pev(.move, 30, 0, 1000, 0)); // 10px in 990ms → slow
    const f2 = r2.feed(pev(.up, 30, 0, 1100, 0)).?;
    try std.testing.expect(std.meta.activeTag(f2) == .pan_end);
}

test "pinch: two pointers, scale = current / initial distance" {
    var r = Recognizer{ .kind = .pinch };
    _ = r.feed(pev(.down, 0, 0, 0, 1));
    _ = r.feed(pev(.down, 100, 0, 0, 2)); // accepted, initial distance 100
    const f = r.feed(pev(.move, 150, 0, 10, 2)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), f.pinch.scale, 0.001);
    // lifting a pointer ends the pinch
    try std.testing.expect(r.feed(pev(.up, 0, 0, 20, 1)) == null);
    try std.testing.expect(r.feed(pev(.move, 200, 0, 30, 2)) == null);
}

test "pinch: an unrelated third finger does not stop the gesture" {
    var r = Recognizer{ .kind = .pinch };
    _ = r.feed(pev(.down, 0, 0, 0, 1));
    _ = r.feed(pev(.down, 100, 0, 0, 2)); // accepted
    _ = r.feed(pev(.down, 500, 500, 5, 3)); // third finger: ignored
    _ = r.feed(pev(.up, 500, 500, 10, 3)); // third finger lifts: gesture survives
    const f = r.feed(pev(.move, 150, 0, 20, 2)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), f.pinch.scale, 0.001);
}

test "pinch: a replacement finger re-enters the gesture" {
    var r = Recognizer{ .kind = .pinch };
    _ = r.feed(pev(.down, 0, 0, 0, 1));
    _ = r.feed(pev(.down, 100, 0, 0, 2)); // accepted, distance 100
    _ = r.feed(pev(.up, 0, 0, 10, 1)); // pointer 1 lifts → idle
    _ = r.feed(pev(.down, 0, 0, 20, 3)); // replacement finger
    // new pair (3..2): (0,0)-(100,0) → (-100,0)-(100,0) = 100 → 200 = 2x
    const f = r.feed(pev(.move, -100, 0, 30, 3)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), f.pinch.scale, 0.001);
}

test "rotate: two pointers, per-move angle delta" {
    var r = Recognizer{ .kind = .rotate };
    _ = r.feed(pev(.down, 0, 0, 0, 1));
    _ = r.feed(pev(.down, 100, 0, 0, 2)); // initial angle 0
    const f = r.feed(pev(.move, 0, 100, 10, 2)).?; // now angle = π/2
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), f.rotate.delta, 0.001);
}

test "rotate: no jump when the angle crosses ±π" {
    var r = Recognizer{ .kind = .rotate };
    _ = r.feed(pev(.down, 0, 0, 0, 1));
    _ = r.feed(pev(.down, -100, 1, 0, 2)); // angle ≈ π - 0.01
    _ = r.feed(pev(.move, -100, 1, 10, 2)); // accepted at ≈ 3.1316
    // cross to ≈ -(π - 0.01): raw delta ≈ -6.26, wrapped → +0.02
    const f = r.feed(pev(.move, -100, -1, 20, 2)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), f.rotate.delta, 0.001);
    try std.testing.expect(f.rotate.delta > 0);
}

test "arena: builds one recognizer per callback set and resolves conflicts" {
    var taps: u32 = 0;
    var double_taps: u32 = 0;
    const cbs = GestureCallbacks{
        .on_tap = .{ .fn_ptr = countCb, .userdata = &taps },
        .on_double_tap = .{ .fn_ptr = countCb, .userdata = &double_taps },
    };
    var arena = GestureArena.init(cbs);
    try std.testing.expectEqual(@as(u8, 2), arena.count);
    // a quick tap fires on_tap only
    arena.feed(pev(.down, 0, 0, 0, 0));
    arena.feed(pev(.up, 0, 0, 50, 0));
    try std.testing.expectEqual(@as(u32, 1), taps);
    try std.testing.expectEqual(@as(u32, 0), double_taps);
    // a second quick tap fires on_double_tap only (tap suppressed same-event)
    arena.feed(pev(.down, 0, 0, 150, 0));
    arena.feed(pev(.up, 0, 0, 200, 0));
    try std.testing.expectEqual(@as(u32, 1), taps);
    try std.testing.expectEqual(@as(u32, 1), double_taps);
    // cancel resets in-flight gestures
    arena.feed(pev(.down, 0, 0, 300, 0));
    arena.feed(pev(.leave, 0, 0, 300, 0));
    arena.feed(pev(.up, 0, 0, 350, 0)); // stale up after cancel → no tap
    try std.testing.expectEqual(@as(u32, 1), taps);
}

fn countCb(userdata: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(userdata.?));
    counter.* += 1;
}

const MultiRec = struct { pinches: u32 = 0, rotates: u32 = 0, last_scale: f32 = 0, last_delta: f32 = 0 };

fn recPinchCb(userdata: ?*anyopaque, scale: f32) void {
    const r: *MultiRec = @ptrCast(@alignCast(userdata.?));
    r.pinches += 1;
    r.last_scale = scale;
}

fn recRotateCb(userdata: ?*anyopaque, delta: f32) void {
    const r: *MultiRec = @ptrCast(@alignCast(userdata.?));
    r.rotates += 1;
    r.last_delta = delta;
}

test "arena: pinch and rotate co-fire on the same move" {
    var rec = MultiRec{};
    var arena = GestureArena.init(.{
        .on_pinch = .{ .fn_ptr = recPinchCb, .userdata = &rec },
        .on_rotate = .{ .fn_ptr = recRotateCb, .userdata = &rec },
    });
    arena.feed(pev(.down, 0, 0, 0, 1));
    arena.feed(pev(.down, 100, 0, 0, 2)); // pair complete
    arena.feed(pev(.move, 150, 50, 10, 2)); // scale + angle change in one move
    try std.testing.expectEqual(@as(u32, 1), rec.pinches);
    try std.testing.expectEqual(@as(u32, 1), rec.rotates);
    try std.testing.expectApproxEqAbs(@sqrt(25000.0) / 100.0, rec.last_scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.32175), rec.last_delta, 0.001); // atan2(50, 150)
}

test "arena: a pinch claims the interaction — no tap fires" {
    var taps: u32 = 0;
    var rec = MultiRec{};
    var arena = GestureArena.init(.{
        .on_tap = .{ .fn_ptr = countCb, .userdata = &taps },
        .on_pinch = .{ .fn_ptr = recPinchCb, .userdata = &rec },
    });
    arena.feed(pev(.down, 0, 0, 0, 1));
    arena.feed(pev(.down, 100, 0, 0, 2)); // pinch accepts → claims the interaction
    arena.feed(pev(.move, 150, 0, 10, 2));
    // lifting a tracked finger quickly would be a tap if the tap recognizer
    // were still tracking — the pinch claim reset it.
    arena.feed(pev(.up, 0, 0, 50, 1));
    arena.feed(pev(.up, 150, 0, 60, 2));
    try std.testing.expectEqual(@as(u32, 1), rec.pinches);
    try std.testing.expectEqual(@as(u32, 0), taps);
}

test "arena: tick fires a long-press exactly at the threshold" {
    var presses: u32 = 0;
    var arena = GestureArena.init(.{ .on_long_press = .{ .fn_ptr = countCb, .userdata = &presses } });
    arena.feed(pev(.down, 0, 0, 0, 0));
    arena.tick(499);
    try std.testing.expectEqual(@as(u32, 0), presses);
    arena.tick(500); // the timeline drives it — no pointer event needed
    try std.testing.expectEqual(@as(u32, 1), presses);
    // a release after a tick-fired long-press does not fire it again
    arena.feed(pev(.up, 0, 0, 600, 0));
    try std.testing.expectEqual(@as(u32, 1), presses);
}

test "single-pointer recognizers ignore other pointers' events" {
    var r = Recognizer{ .kind = .tap };
    _ = r.feed(pev(.down, 0, 0, 0, 1)); // tracking pointer 1
    try std.testing.expect(r.feed(pev(.move, 50, 0, 10, 2)) == null); // pointer 2 ignored
    try std.testing.expectEqual(Fire.tap, r.feed(pev(.up, 0, 0, 50, 1)).?);
}
