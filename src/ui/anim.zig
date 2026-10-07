// Animations (Phase 1e) — springs (M3E physics), tweens (driven curves),
// SIMD interpolation, and the global Timeline scheduler.
//
// Design:
//   - Time-based, not step-based: an Animation evaluates its value at
//     (now - start), so the tick rate never changes the result (no drift).
//     The host ticks the timeline once per loop iteration (~120 Hz while
//     animating); deadlines (stagger, long-press) are exact because they
//     compare against the same clock — the "240 Hz" of the roadmap is the
//     timeline's clock resolution, not a required wakeup rate.
//   - Values are @Vector(4, f32): one animation drives up to 4 properties
//     at once (x/y/w/h, RGBA, …) with SIMD math (1e.3).
//   - The Timeline is process-global (setCurrent, like the input router).
//     Animations carry a `channel` (what they write): playing on a busy
//     channel cancels the previous animation — retargeting mid-flight is
//     free and never double-writes.
//   - Frame budget (1e.7): the host flags frame_overrun when a frame's paint
//     exceeds 8.3 ms; low-priority animations pause while overrun (they are
//     time-based, so they resume without a glitch).
//   - ADR-0009 shape: callbacks are fn ptr + userdata.
const std = @import("std");
const state_mod = @import("state.zig");

pub const Callback = state_mod.Callback;

pub const Vec4 = @Vector(4, f32);

pub const Color = u32; // 0xRRGGBBAA (matches ui.paint.Color)

// --- Spring (M3E physics, closed-form) ---
//
//   x'' = -(k/m)(x - target) - (c/m) x'
//
// Solved exactly (underdamped / critically damped / overdamped), so the
// result is independent of the tick rate. Presets are M3E-inspired:
// default (stiffness 380, damping 32, mass 1) is snappy with a slight
// overshoot; gentle is soft, bouncy is springy.

pub const Spring = struct {
    stiffness: f32 = 380,
    damping: f32 = 32,
    mass: f32 = 1,

    pub const gentle: Spring = .{ .stiffness = 180, .damping = 24 };
    pub const bouncy: Spring = .{ .stiffness = 700, .damping = 40 };

    /// Displacement from the target at time t (seconds), given the initial
    /// displacement d0 and velocity v0. Exact closed form.
    pub fn displacement(s: Spring, d0: f32, v0: f32, t: f32) f32 {
        const k = @max(s.stiffness, 0.001);
        const m = @max(s.mass, 0.001);
        const omega0 = @sqrt(k / m);
        const zeta = s.damping / (2 * @sqrt(k * m));
        if (zeta < 1 - 1e-4) {
            // Underdamped: oscillation with exponential decay.
            const omega_d = omega0 * @sqrt(1 - zeta * zeta);
            const e = @exp(-zeta * omega0 * t);
            const b = (v0 + zeta * omega0 * d0) / omega_d;
            return e * (d0 * @cos(omega_d * t) + b * @sin(omega_d * t));
        }
        if (zeta > 1 + 1e-4) {
            // Overdamped: two real roots.
            const sq = @sqrt(zeta * zeta - 1);
            const r1 = -omega0 * (zeta - sq);
            const r2 = -omega0 * (zeta + sq);
            const a = (v0 - r2 * d0) / (r1 - r2);
            const b = d0 - a;
            return a * @exp(r1 * t) + b * @exp(r2 * t);
        }
        // Critically damped.
        const e = @exp(-omega0 * t);
        return (d0 + (v0 + omega0 * d0) * t) * e;
    }

    /// Velocity at time t (seconds) — the derivative of displacement.
    pub fn velocity(s: Spring, d0: f32, v0: f32, t: f32) f32 {
        const k = @max(s.stiffness, 0.001);
        const m = @max(s.mass, 0.001);
        const omega0 = @sqrt(k / m);
        const zeta = s.damping / (2 * @sqrt(k * m));
        if (zeta < 1 - 1e-4) {
            const omega_d = omega0 * @sqrt(1 - zeta * zeta);
            const e = @exp(-zeta * omega0 * t);
            const b = (v0 + zeta * omega0 * d0) / omega_d;
            return e * ((b * omega_d - zeta * omega0 * d0) * @cos(omega_d * t) -
                (d0 * omega_d + zeta * omega0 * b) * @sin(omega_d * t));
        }
        if (zeta > 1 + 1e-4) {
            const sq = @sqrt(zeta * zeta - 1);
            const r1 = -omega0 * (zeta - sq);
            const r2 = -omega0 * (zeta + sq);
            const a = (v0 - r2 * d0) / (r1 - r2);
            const b = d0 - a;
            return a * r1 * @exp(r1 * t) + b * r2 * @exp(r2 * t);
        }
        const e = @exp(-omega0 * t);
        return ((v0 + omega0 * d0) - omega0 * (d0 + (v0 + omega0 * d0) * t)) * e;
    }

    /// Slowest decay rate of the envelope (1/s) — used for settle estimates.
    fn decayRate(s: Spring) f32 {
        const k = @max(s.stiffness, 0.001);
        const m = @max(s.mass, 0.001);
        const omega0 = @sqrt(k / m);
        const zeta = s.damping / (2 * @sqrt(k * m));
        if (zeta < 1) return zeta * omega0;
        if (zeta > 1) return omega0 * (zeta - @sqrt(zeta * zeta - 1));
        return omega0;
    }
};

/// Time (ms) for a spring animation to decay below 0.1 units on every lane.
/// Computed once at play time from the initial state (per-lane amplitude).
pub fn springSettleMs(spring: Spring, from: Vec4, to: Vec4, v0: Vec4) u32 {
    const rate = spring.decayRate();
    if (rate <= 0.0001) return 10_000; // undamped: never settles, cap
    const omega0 = @sqrt(@max(spring.stiffness, 0.001) / @max(spring.mass, 0.001));
    var max_ms: f32 = 0;
    inline for (0..4) |i| {
        const d0 = from[i] - to[i];
        const amp = @max(@abs(d0), @abs(v0[i]) / omega0);
        if (amp > 0.1) {
            const t = @log(amp / 0.1) / rate;
            max_ms = @max(max_ms, t * 1000);
        }
    }
    return @intFromFloat(@max(max_ms, 1));
}

// --- Curves (tweens) ---

pub const Ease = enum {
    linear,
    ease_in, // quadratic
    ease_out, // quadratic
    ease_in_out, // quadratic in-out
    standard, // M3 standard: cubic-bezier(0.2, 0, 0, 1)
    emphasized, // M3 emphasized: cubic-bezier(0.05, 0.7, 0.1, 1)
};

/// A tween curve: a fixed easing or a custom fn (no userdata — hot path).
pub const Curve = union(enum) {
    ease: Ease,
    custom: *const fn (t: f32) f32,
};

pub fn sampleCurve(c: Curve, t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return switch (c) {
        .ease => |e| sampleEase(e, x),
        .custom => |f| std.math.clamp(f(x), 0.0, 1.0),
    };
}

pub fn sampleEase(e: Ease, t: f32) f32 {
    return switch (e) {
        .linear => t,
        .ease_in => t * t,
        .ease_out => 1 - (1 - t) * (1 - t),
        .ease_in_out => if (t < 0.5) 2 * t * t else 1 - 2 * (1 - t) * (1 - t),
        .standard => cubicBezier(0.2, 0.0, 0.0, 1.0, t),
        .emphasized => cubicBezier(0.05, 0.7, 0.1, 1.0, t),
    };
}

/// Evaluate a cubic bezier easing curve (CSS-style: endpoints (0,0)/(1,1),
/// control points (x1,y1)/(x2,y2)) at time fraction x. Newton-Raphson with
/// a bisection fallback — exact, no state.
pub fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) f32 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // Newton-Raphson.
    var t: f32 = x;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const e = bezierCoord(t, x1, x2) - x;
        if (@abs(e) < 1e-6) break;
        const d = bezierDeriv(t, x1, x2);
        if (@abs(d) < 1e-6) break;
        t = std.math.clamp(t - e / d, 0.0, 1.0);
    }
    // Bisection refinement.
    var lo: f32 = 0;
    var hi: f32 = 1;
    i = 0;
    while (i < 24) : (i += 1) {
        if (bezierCoord(t, x1, x2) < x) lo = t else hi = t;
        t = (lo + hi) / 2;
    }
    return bezierCoord(t, y1, y2);
}

fn bezierCoord(t: f32, c1: f32, c2: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t;
}

fn bezierDeriv(t: f32, c1: f32, c2: f32) f32 {
    const u = 1 - t;
    return 3 * u * u * c1 + 6 * u * t * (c2 - c1) + 3 * t * t * (1 - c2);
}

// --- SIMD interpolation (1e.3) ---

/// SIMD lerp of 4 lanes: one instruction stream interpolates x/y/w/h (or
/// RGBA) at once.
pub fn lerp4(a: Vec4, b: Vec4, t: f32) Vec4 {
    const tv: Vec4 = @splat(t);
    return a + (b - a) * tv;
}

/// SIMD color lerp: unpack the 4 channels, lerp, repack (straight channels).
pub fn lerpColor(a: Color, b: Color, t: f32) Color {
    const av: Vec4 = .{
        @as(f32, @floatFromInt((a >> 24) & 0xFF)),
        @as(f32, @floatFromInt((a >> 16) & 0xFF)),
        @as(f32, @floatFromInt((a >> 8) & 0xFF)),
        @as(f32, @floatFromInt(a & 0xFF)),
    };
    const bv: Vec4 = .{
        @as(f32, @floatFromInt((b >> 24) & 0xFF)),
        @as(f32, @floatFromInt((b >> 16) & 0xFF)),
        @as(f32, @floatFromInt((b >> 8) & 0xFF)),
        @as(f32, @floatFromInt(b & 0xFF)),
    };
    const v = lerp4(av, bv, t);
    const r: u32 = @intFromFloat(std.math.clamp(v[0], 0, 255));
    const g: u32 = @intFromFloat(std.math.clamp(v[1], 0, 255));
    const bl: u32 = @intFromFloat(std.math.clamp(v[2], 0, 255));
    const al: u32 = @intFromFloat(std.math.clamp(v[3], 0, 255));
    return (r << 24) | (g << 16) | (bl << 8) | al;
}

/// Unpack a color into lerp lanes (R, G, B, A as f32).
pub fn colorToVec4(c: Color) Vec4 {
    return .{
        @as(f32, @floatFromInt((c >> 24) & 0xFF)),
        @as(f32, @floatFromInt((c >> 16) & 0xFF)),
        @as(f32, @floatFromInt((c >> 8) & 0xFF)),
        @as(f32, @floatFromInt(c & 0xFF)),
    };
}

/// Pack lerp lanes back into a color (truncating, like lerpColor).
pub fn vec4ToColor(v: Vec4) Color {
    const r: u32 = @intFromFloat(std.math.clamp(v[0], 0, 255));
    const g: u32 = @intFromFloat(std.math.clamp(v[1], 0, 255));
    const b: u32 = @intFromFloat(std.math.clamp(v[2], 0, 255));
    const a: u32 = @intFromFloat(std.math.clamp(v[3], 0, 255));
    return (r << 24) | (g << 16) | (b << 8) | a;
}

// --- Animation (one running value) ---

pub const Priority = enum { high, low };

/// Motion spec for the animated widgets: a spring or a tween.
pub const Motion = union(enum) {
    spring: Spring,
    tween: struct { duration_ms: u32, curve: Curve },
};

pub const Animation = struct {
    pub const Kind = union(enum) {
        spring: struct { spring: Spring, to: Vec4, v0: Vec4, settle_ms: u32 },
        tween: struct { duration_ms: u32, curve: Curve, to: Vec4 },
    };

    pub const UpdateCallback = struct {
        fn_ptr: *const fn (userdata: ?*anyopaque, value: Vec4) void,
        userdata: ?*anyopaque,
    };

    kind: Kind,
    from: Vec4,
    start_ms: u64 = 0,
    delay_ms: u32 = 0, // stagger (1e.4)
    priority: Priority = .high,
    /// Playing a new animation on the same channel cancels this one.
    channel: ?*anyopaque = null,
    on_update: ?UpdateCallback = null,
    on_complete: ?Callback = null,
    id: u32 = 0,
    done: bool = false,

    pub fn springAnim(from: Vec4, to: Vec4, spring: Spring, v0: Vec4) Kind {
        return .{ .spring = .{
            .spring = spring,
            .to = to,
            .v0 = v0,
            .settle_ms = springSettleMs(spring, from, to, v0),
        } };
    }

    pub fn tweenAnim(to: Vec4, duration_ms: u32, curve: Curve) Kind {
        return .{ .tween = .{ .duration_ms = duration_ms, .curve = curve, .to = to } };
    }

    pub fn kindOf(motion: Motion, from: Vec4, to: Vec4) Kind {
        return switch (motion) {
            .spring => |s| springAnim(from, to, s, .{ 0, 0, 0, 0 }),
            .tween => |t| tweenAnim(to, t.duration_ms, t.curve),
        };
    }

    /// The animated value at `now_ms` (timeline clock). Pure — the tick rate
    /// never changes the result.
    pub fn valueAt(a: *const Animation, now_ms: u64) Vec4 {
        if (now_ms < a.start_ms) return a.from; // delayed (stagger)
        const t_ms = now_ms - a.start_ms;
        return switch (a.kind) {
            .spring => |s| springValue(a.from, s.to, s.spring, s.v0, t_ms),
            .tween => |tw| tweenValue(a.from, tw.to, tw.curve, t_ms, tw.duration_ms),
        };
    }

    /// True once the animation has reached its final value (springs settle:
    /// the envelope decays below 0.1 units per lane).
    pub fn isComplete(a: *const Animation, now_ms: u64) bool {
        if (now_ms < a.start_ms) return false;
        const t_ms = now_ms - a.start_ms;
        return switch (a.kind) {
            .spring => |s| t_ms >= s.settle_ms,
            .tween => |tw| t_ms >= tw.duration_ms,
        };
    }

    pub fn finalValue(a: *const Animation) Vec4 {
        return switch (a.kind) {
            .spring => |s| s.to,
            .tween => |t| t.to,
        };
    }
};

/// SIMD closed-form spring value (all lanes share the physics, per-lane
/// initial displacement/velocity).
fn springValue(from: Vec4, to: Vec4, spring: Spring, v0: Vec4, t_ms: u64) Vec4 {
    const t: f32 = @as(f32, @floatFromInt(t_ms)) / 1000;
    const k = @max(spring.stiffness, 0.001);
    const m = @max(spring.mass, 0.001);
    const omega0 = @sqrt(k / m);
    const zeta = spring.damping / (2 * @sqrt(k * m));
    const d0 = from - to;
    const zeta_w0 = zeta * omega0;
    if (zeta < 1 - 1e-4) {
        const omega_d = omega0 * @sqrt(1 - zeta * zeta);
        const e: Vec4 = @splat(@exp(-zeta_w0 * t));
        const c: Vec4 = @splat(@cos(omega_d * t));
        const s: Vec4 = @splat(@sin(omega_d * t));
        const b = (v0 + @as(Vec4, @splat(zeta_w0)) * d0) / @as(Vec4, @splat(omega_d));
        return to + e * (d0 * c + b * s);
    }
    if (zeta > 1 + 1e-4) {
        const sq = @sqrt(zeta * zeta - 1);
        const r1 = -omega0 * (zeta - sq);
        const r2 = -omega0 * (zeta + sq);
        const e1: Vec4 = @splat(@exp(r1 * t));
        const e2: Vec4 = @splat(@exp(r2 * t));
        const a = (v0 - @as(Vec4, @splat(r2)) * d0) / @as(Vec4, @splat(r1 - r2));
        const b = d0 - a;
        return to + a * e1 + b * e2;
    }
    const e: Vec4 = @splat(@exp(-omega0 * t));
    return to + (d0 + (v0 + @as(Vec4, @splat(omega0)) * d0) * @as(Vec4, @splat(t))) * e;
}

fn tweenValue(from: Vec4, to: Vec4, curve: Curve, t_ms: u64, duration_ms: u32) Vec4 {
    if (duration_ms == 0) return to;
    const clamped = @min(t_ms, duration_ms);
    const t: f32 = @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(duration_ms));
    return lerp4(from, to, sampleCurve(curve, t));
}

// --- Timeline (process-global scheduler) ---

pub const Timeline = struct {
    animations: std.array_list.Managed(Animation),
    tickers: std.array_list.Managed(Ticker),
    next_id: u32 = 1,
    last_now_ms: u64 = 0,
    /// Set by the host when a frame's paint exceeded the 8.3 ms budget:
    /// low-priority animations pause while overrun (1e.7).
    frame_overrun: bool = false,
    allocator: std.mem.Allocator,

    /// Time-based subscriber (e.g. a gesture arena — long-press precision).
    pub const Ticker = struct {
        fn_ptr: *const fn (userdata: ?*anyopaque, now_ms: u64) void,
        userdata: ?*anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator) Timeline {
        return .{
            .animations = std.array_list.Managed(Animation).init(allocator),
            .tickers = std.array_list.Managed(Ticker).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(tl: *Timeline) void {
        tl.animations.deinit();
        tl.tickers.deinit();
    }

    /// True while at least one animation is still running (cancelled ones
    /// are removed lazily on the next tick, so they don't count).
    pub fn hasActive(tl: *const Timeline) bool {
        for (tl.animations.items) |a| {
            if (!a.done) return true;
        }
        return false;
    }

    /// Register an animation. Same-channel animations are cancelled first
    /// (retargeting mid-flight). Returns the animation id (for cancel).
    pub fn play(tl: *Timeline, a: Animation) u32 {
        if (a.channel) |ch| {
            for (tl.animations.items) |*other| {
                if (!other.done and other.channel != null and other.channel.? == ch) other.done = true;
            }
        }
        var anim = a;
        anim.id = tl.next_id;
        tl.next_id += 1;
        anim.start_ms = tl.last_now_ms + anim.delay_ms;
        tl.animations.append(anim) catch @panic("klaxon: out of memory");
        return anim.id;
    }

    /// Cancel by id (no-op if unknown or already done).
    pub fn cancel(tl: *Timeline, id: u32) void {
        for (tl.animations.items) |*a| {
            if (a.id == id) a.done = true;
        }
    }

    /// Cancel every active animation on a channel (widget teardown: the
    /// channel's owner is about to be freed).
    pub fn cancelChannel(tl: *Timeline, channel: *anyopaque) void {
        for (tl.animations.items) |*a| {
            if (!a.done and a.channel != null and a.channel.? == channel) a.done = true;
        }
    }

    pub fn addTicker(tl: *Timeline, t: Ticker) void {
        tl.tickers.append(t) catch @panic("klaxon: out of memory");
    }

    pub fn removeTicker(tl: *Timeline, t: Ticker) void {
        var i: usize = 0;
        while (i < tl.tickers.items.len) {
            const cur = tl.tickers.items[i];
            if (cur.fn_ptr == t.fn_ptr and cur.userdata == t.userdata) {
                _ = tl.tickers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Advance the timeline: tick subscribers, then every active animation
    /// (time-based evaluation — the tick rate never changes the result).
    pub fn tick(tl: *Timeline, now_ms: u64) void {
        tl.last_now_ms = now_ms;
        for (tl.tickers.items) |t| t.fn_ptr(t.userdata, now_ms);
        var i: usize = 0;
        while (i < tl.animations.items.len) {
            var a = &tl.animations.items[i];
            if (a.done) {
                _ = tl.animations.swapRemove(i);
                continue;
            }
            if (a.priority == .low and tl.frame_overrun) {
                i += 1; // paused while the frame budget is blown (1e.7)
                continue;
            }
            if (a.isComplete(now_ms)) {
                if (a.on_update) |cb| cb.fn_ptr(cb.userdata, a.finalValue());
                if (a.on_complete) |cb| cb.fn_ptr(cb.userdata);
                _ = tl.animations.swapRemove(i);
                continue;
            }
            if (now_ms >= a.start_ms) {
                if (a.on_update) |cb| cb.fn_ptr(cb.userdata, a.valueAt(now_ms));
            }
            i += 1;
        }
    }
};

threadlocal var current_timeline: ?*Timeline = null;

/// Install the process-global timeline (the host does this at init;
/// single-window P0). Null clears it (tests).
pub fn setCurrent(tl: ?*Timeline) void {
    current_timeline = tl;
}

/// The process-global timeline, or null (widgets then snap to targets).
pub fn timeline() ?*Timeline {
    return current_timeline;
}

// --- tests ---

test "spring: closed form matches initial state (d(0)=d0, v(0)=v0)" {
    const s = Spring{};
    try std.testing.expectApproxEqAbs(@as(f32, 100), s.displacement(100, 0, 0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.velocity(100, 0, 0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -50), s.velocity(100, -50, 0), 1e-2);
}

test "spring: underdamped overshoots, then settles" {
    const s = Spring{}; // zeta ≈ 0.82
    const omega0 = @sqrt(380.0);
    const zeta = 32.0 / (2 * @sqrt(380.0));
    const omega_d = omega0 * @sqrt(1 - zeta * zeta);
    const t_half = std.math.pi / omega_d;
    // half a period later the displacement flipped sign (overshoot)
    try std.testing.expect(s.displacement(100, 0, @as(f32, t_half)) < 0);
    // settles below 0.1% of the initial amplitude (velocity leads the
    // displacement by ~omega_d, so it is still a few px/s at settle time)
    const settle_s = @log(100.0 / 0.1) / (zeta * omega0);
    try std.testing.expect(@abs(s.displacement(100, 0, @as(f32, settle_s))) < 0.5);
    try std.testing.expect(@abs(s.velocity(100, 0, @as(f32, settle_s))) < 5.0);
}

test "spring: critically damped never overshoots and settles" {
    const s = Spring{ .stiffness = 380, .damping = 2 * @sqrt(380.0) };
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.01) {
        try std.testing.expect(s.displacement(100, 0, t) > -0.001);
    }
    try std.testing.expect(@abs(s.displacement(100, 0, 1.0)) < 1.0);
}

test "spring: overdamped converges without oscillation" {
    const s = Spring{ .damping = 80 }; // zeta ≈ 2.05
    try std.testing.expectApproxEqAbs(@as(f32, 100), s.displacement(100, 0, 0), 1e-4);
    var t: f32 = 0;
    while (t < 2.0) : (t += 0.01) {
        try std.testing.expect(s.displacement(100, 0, t) > -0.001);
    }
    try std.testing.expect(@abs(s.displacement(100, 0, 2.0)) < 1.0);
}

test "spring: settle time grows with amplitude" {
    const small = springSettleMs(Spring{}, .{ 100, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    const big = springSettleMs(Spring{}, .{ 1000, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    try std.testing.expect(big > small);
    try std.testing.expect(small > 0);
}

test "spring: SIMD value is per-lane exact" {
    var a = Animation{
        .kind = Animation.springAnim(.{ 100, 0, 50, 0 }, .{ 0, 0, 0, 0 }, Spring{}, .{ 0, 0, 0, 0 }),
        .from = .{ 100, 0, 50, 0 },
    };
    const v0 = a.valueAt(0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), v0[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v0[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 50), v0[2], 1e-3);
    const s = Spring{};
    const expect = s.displacement(50, 0, 0.25);
    try std.testing.expectApproxEqAbs(expect, a.valueAt(250)[2], 1e-3);
}

test "tween: endpoints exact, midpoint interpolated (linear)" {
    var a = Animation{
        .kind = Animation.tweenAnim(.{ 100, 30, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 10, 0, 0 },
        .start_ms = 0,
    };
    try std.testing.expectEqual(@as(Vec4, .{ 0, 10, 0, 0 }), a.valueAt(0));
    try std.testing.expectEqual(@as(Vec4, .{ 100, 30, 0, 0 }), a.valueAt(100));
    const mid = a.valueAt(50);
    try std.testing.expectApproxEqAbs(@as(f32, 50), mid[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20), mid[1], 1e-3);
    // past the end clamps to the target
    try std.testing.expectEqual(@as(Vec4, .{ 100, 30, 0, 0 }), a.valueAt(999));
    try std.testing.expect(a.isComplete(100));
    try std.testing.expect(!a.isComplete(99));
}

test "curves: endpoints exact for every ease" {
    inline for (std.meta.tags(Ease)) |e| {
        try std.testing.expectEqual(@as(f32, 0), sampleEase(e, 0));
        try std.testing.expectEqual(@as(f32, 1), sampleEase(e, 1));
    }
    try std.testing.expectEqual(@as(f32, 0.5), sampleEase(.linear, 0.5));
    // M3 standard is fast-out: at t=0.5 it is well past the midpoint
    const mid = sampleEase(.standard, 0.5);
    try std.testing.expect(mid > 0.7 and mid < 0.9);
}

test "cubicBezier: linear bezier is the identity, M3 curves are monotonic" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cubicBezier(0, 0, 1, 1, 0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cubicBezier(0, 0, 1, 1, 0.25), 1e-4);
    var prev: f32 = 0;
    var x: f32 = 0;
    while (x <= 1.0) : (x += 0.05) {
        const y = cubicBezier(0.2, 0.0, 0.0, 1.0, x);
        try std.testing.expect(y >= prev - 1e-4);
        prev = y;
    }
}

fn doubleIt(t: f32) f32 {
    return 2 * t;
}

test "curves: custom fn curve is sampled and clamped" {
    try std.testing.expectEqual(@as(f32, 1), sampleCurve(.{ .custom = doubleIt }, 0.5));
    try std.testing.expectEqual(@as(f32, 1), sampleCurve(.{ .custom = doubleIt }, 0.9)); // clamped
    try std.testing.expectEqual(@as(f32, 0), sampleCurve(.{ .custom = doubleIt }, 0));
}

test "SIMD lerp4 interpolates all lanes at once" {
    const v = lerp4(.{ 0, 10, 20, 30 }, .{ 4, 14, 24, 34 }, 0.5);
    try std.testing.expectEqual(@as(Vec4, .{ 2, 12, 22, 32 }), v);
    try std.testing.expectEqual(@as(Vec4, .{ 0, 10, 20, 30 }), lerp4(.{ 0, 10, 20, 30 }, .{ 4, 14, 24, 34 }, 0));
}

test "SIMD lerpColor: endpoints exact, midpoint per-channel" {
    const red: Color = 0xFF0000FF;
    const blue: Color = 0x0000FFFF;
    try std.testing.expectEqual(red, lerpColor(red, blue, 0));
    try std.testing.expectEqual(blue, lerpColor(red, blue, 1));
    try std.testing.expectEqual(@as(Color, 0x7F007FFF), lerpColor(red, blue, 0.5));
    // pack/unpack round-trip
    try std.testing.expectEqual(blue, vec4ToColor(colorToVec4(blue)));
}

// --- Timeline tests ---

const Rec = struct { values: [8]f32 = undefined, n: u32 = 0, completed: u32 = 0 };

fn recUpdate(userdata: ?*anyopaque, v: Vec4) void {
    const r: *Rec = @ptrCast(@alignCast(userdata.?));
    if (r.n < r.values.len) {
        r.values[r.n] = v[0];
        r.n += 1;
    }
}

fn recComplete(userdata: ?*anyopaque) void {
    const r: *Rec = @ptrCast(@alignCast(userdata.?));
    r.completed += 1;
}

fn testTimeline() Timeline {
    return Timeline.init(std.testing.allocator);
}

test "timeline: tween plays, ticks, completes exactly once" {
    var tl = testTimeline();
    defer tl.deinit();
    var rec = Rec{};
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &rec },
        .on_complete = .{ .fn_ptr = recComplete, .userdata = &rec },
    });
    try std.testing.expect(tl.hasActive());
    tl.tick(0);
    tl.tick(50);
    tl.tick(100); // completes: final value + on_complete
    try std.testing.expect(!tl.hasActive());
    try std.testing.expectEqual(@as(u32, 3), rec.n);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rec.values[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 50), rec.values[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), rec.values[2], 1e-3);
    try std.testing.expectEqual(@as(u32, 1), rec.completed);
    tl.tick(200); // gone: no more updates
    try std.testing.expectEqual(@as(u32, 3), rec.n);
}

test "timeline: stagger delays the start" {
    var tl = testTimeline();
    defer tl.deinit();
    var rec = Rec{};
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .delay_ms = 50,
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &rec },
    });
    tl.tick(25);
    try std.testing.expectEqual(@as(u32, 0), rec.n); // not started
    tl.tick(100); // 50 ms into the tween
    try std.testing.expectEqual(@as(u32, 1), rec.n);
    try std.testing.expectApproxEqAbs(@as(f32, 50), rec.values[0], 1e-3);
}

test "timeline: cancel stops the animation" {
    var tl = testTimeline();
    defer tl.deinit();
    var rec = Rec{};
    const id = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &rec },
    });
    tl.tick(0);
    tl.cancel(id);
    tl.tick(50);
    tl.tick(100);
    try std.testing.expectEqual(@as(u32, 1), rec.n);
    try std.testing.expect(!tl.hasActive());
}

test "timeline: playing on a busy channel cancels the previous animation" {
    var tl = testTimeline();
    defer tl.deinit();
    var rec_a = Rec{};
    var rec_b = Rec{};
    var channel: u8 = 0;
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&channel),
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &rec_a },
        .on_complete = .{ .fn_ptr = recComplete, .userdata = &rec_a },
    });
    tl.tick(50); // A halfway
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 200, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 50, 0, 0, 0 },
        .channel = @ptrCast(&channel),
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &rec_b },
        .on_complete = .{ .fn_ptr = recComplete, .userdata = &rec_b },
    });
    tl.tick(100); // B at its midpoint
    tl.tick(150); // B completes
    try std.testing.expectEqual(@as(u32, 1), rec_a.n); // A cancelled after its first tick
    try std.testing.expectEqual(@as(u32, 0), rec_a.completed); // never completed
    try std.testing.expectEqual(@as(u32, 2), rec_b.n);
    try std.testing.expectApproxEqAbs(@as(f32, 125), rec_b.values[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 200), rec_b.values[1], 1e-3);
    try std.testing.expectEqual(@as(u32, 1), rec_b.completed);
}

test "timeline: frame overrun pauses low-priority animations only" {
    var tl = testTimeline();
    defer tl.deinit();
    var high = Rec{};
    var low = Rec{};
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .priority = .high,
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &high },
    });
    _ = tl.play(.{
        .kind = Animation.tweenAnim(.{ 100, 0, 0, 0 }, 100, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .priority = .low,
        .on_update = .{ .fn_ptr = recUpdate, .userdata = &low },
    });
    tl.tick(0);
    tl.frame_overrun = true;
    tl.tick(50);
    try std.testing.expectEqual(@as(u32, 2), high.n);
    try std.testing.expectEqual(@as(u32, 1), low.n); // paused
    tl.frame_overrun = false;
    tl.tick(100); // both complete (time-based: no glitch on resume)
    try std.testing.expectEqual(@as(u32, 3), high.n);
    try std.testing.expectEqual(@as(u32, 2), low.n);
}

var ticker_calls: u32 = 0;
var ticker_last: u64 = 0;

fn testTicker(userdata: ?*anyopaque, now_ms: u64) void {
    _ = userdata;
    ticker_calls += 1;
    ticker_last = now_ms;
}

test "timeline: tickers fire on every tick and can be removed" {
    var tl = testTimeline();
    defer tl.deinit();
    ticker_calls = 0;
    const t = Timeline.Ticker{ .fn_ptr = testTicker, .userdata = null };
    tl.addTicker(t);
    tl.tick(42);
    try std.testing.expectEqual(@as(u32, 1), ticker_calls);
    try std.testing.expectEqual(@as(u64, 42), ticker_last);
    tl.removeTicker(t);
    tl.tick(43);
    try std.testing.expectEqual(@as(u32, 1), ticker_calls);
}

test "timeline: global setCurrent/timeline" {
    var tl = testTimeline();
    defer tl.deinit();
    try std.testing.expect(timeline() == null);
    setCurrent(&tl);
    defer setCurrent(null);
    try std.testing.expect(timeline() != null);
}
