// Progress indicators (Phase 2d.1 PR B, M3E batch 1) — linear + circular.
//
// Spec: m3.material.io/components/progress-indicators (M3E) + Compose
// LinearProgressIndicatorTokens / CircularProgressIndicatorTokens:
//   - linear: active + track 4dp, round caps, primary on secondary_container;
//     M3E wavy: amplitude 3dp, wavelength 40dp, wave height 10dp
//   - circular: 40dp, stroke 4dp, round caps, primary on secondary_container
//   - motion: determinate progress animates with the M3E spring in Compose;
//     v1 renders the value statically (a live Signal(?f32) variant is the
//     documented extension). Indeterminate loops: linear sweeps a segment
//     (Compose runs a two-segment 1750ms cycle — v1 uses one segment,
//     deviation documented), circular rotates a fixed arc (Compose grows/
//     shrinks a 270dp arc over a 6000ms cycle with 1080deg global rotation —
//     v1 keeps the sweep fixed and rotates, deviation documented).
//
// Painting: flat linear uses rounded rects (radius = thickness/2 = round
// caps); wavy linear and circular use kx_stroke_polyline (ABI 0.5.0) with
// points generated in Zig — a full circle is 48 segments, the wave is sampled
// on a fixed stack buffer (adaptive step, 0 allocs per frame).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = ui.anim;
const node_mod = ui.node;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens (Compose *ProgressIndicatorTokens).
const linear_thickness: f32 = 4;
const wave_height: f32 = 10;
const wave_amplitude: f32 = 3;
const wave_wavelength: f32 = 40;
const circular_size: f32 = 40;
const circular_stroke: f32 = 4;
const circular_indet_sweep: f32 = 270; // degrees, fixed in v1
const arc_segments: usize = 48; // per full circle
const wave_points: usize = 192; // fixed stack buffer (adaptive step)
const linear_indet_ms: u32 = 1750; // Compose LinearAnimationDuration
const circular_indet_ms: u32 = 6000; // Compose CircularAnimationProgressDuration
const circular_indet_rotation: f32 = 1080; // degrees per cycle

pub const ProgressKind = enum { linear, circular };

pub const ProgressOptions = struct {
    kind: ProgressKind = .linear,
    /// 0..1 determinate; null = indeterminate (loops forever).
    progress: ?f32 = null,
    wavy: bool = false, // linear only (M3E)
    theme: Theme = theme_mod.light,
};

const ProgressState = struct {
    opts: ProgressOptions,
    phase: f32 = 0, // indeterminate animation phase 0..1 (loops)
    anim_channel: u8 = 0, // channel marker (stable address)
};

fn stateOf(n: *Node) *ProgressState {
    return @ptrCast(@alignCast(n.state.?));
}

fn progressMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const h: f32 = if (s.opts.kind == .linear) (if (s.opts.wavy) wave_height else linear_thickness) else circular_size;
    const w: f32 = if (s.opts.kind == .circular) circular_size else (if (std.math.isFinite(c.max_w)) c.max_w else 160);
    return c.constrain(.{ .w = w, .h = h });
}

fn progressLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}

/// One point of an arc, in degrees, centered at (cx, cy) with radius r.
/// Angles are degrees, 0 = 3 o'clock, positive clockwise (y down).
fn arcPoint(cx: f32, cy: f32, r: f32, deg: f32) struct { x: f32, y: f32 } {
    const rad = deg * std.math.pi / 180;
    return .{ .x = cx + r * @cos(rad), .y = cy + r * @sin(rad) };
}

/// Fill xs/ys with an arc from `start_deg` sweeping `sweep_deg` (clockwise).
/// Returns the point count (<= max).
fn arcPolyline(xs: []f32, ys: []f32, cx: f32, cy: f32, r: f32, start_deg: f32, sweep_deg: f32) usize {
    const n: usize = @intFromFloat(@ceil(@abs(sweep_deg) / 360 * arc_segments));
    const count = @min(@max(n, 2), xs.len);
    for (0..count) |i| {
        const p = arcPoint(cx, cy, r, start_deg + sweep_deg * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1)));
        xs[i] = p.x;
        ys[i] = p.y;
    }
    return count;
}

/// Fill xs/ys with a sine wave over [x0, x1]: y = yc + amp * sin(...).
/// `phase` scrolls the wave (indeterminate). Returns the point count.
fn wavePolyline(xs: []f32, ys: []f32, x0: f32, x1: f32, yc: f32, amp: f32, wavelength: f32, phase: f32) usize {
    const width = @max(0, x1 - x0);
    if (width <= 0) {
        xs[0] = x0;
        ys[0] = yc + amp * @sin(2 * std.math.pi * (x0 - phase * wavelength) / wavelength);
        return 1;
    }
    // At least a 4px step, capped by the buffer. The step derives from the
    // FINAL segment count so the last sample lands exactly on x1 (a step
    // computed before the cap would end one step short on wide tracks).
    const want: usize = @as(usize, @intFromFloat(@ceil(width / 4))) + 1;
    const count = @min(want, xs.len);
    const step = width / @as(f32, @floatFromInt(count - 1));
    for (0..count) |i| {
        const x = x0 + @as(f32, @floatFromInt(i)) * step;
        xs[i] = x;
        ys[i] = yc + amp * @sin(2 * std.math.pi * (x - phase * wavelength) / wavelength);
    }
    return count;
}

fn progressPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const t = s.opts.theme;
    const active = t.colors.primary;
    const track = t.colors.secondary_container;
    switch (s.opts.kind) {
        .linear => {
            const cy = b.y + b.h / 2;
            if (!s.opts.wavy) {
                // track (full width pill) + active (progress pill)
                ui.paint.fillRRect(ctx, b.x, cy - linear_thickness / 2, b.w, linear_thickness, linear_thickness / 2, track);
                // the active window: [x0, x1] — determinate = the progress
                // prefix; indeterminate = one sweeping segment (v1 deviation
                // from Compose's two-segment cycle — see the file header)
                const seg = b.w * 0.4;
                const pos = s.phase * (b.w + seg) - seg;
                const x0: f32 = if (s.opts.progress) |_| b.x else b.x + std.math.clamp(pos, 0, b.w);
                const x1: f32 = if (s.opts.progress) |p| b.x + b.w * std.math.clamp(p, 0, 1) else b.x + std.math.clamp(pos + seg, 0, b.w);
                if (x1 > x0) ui.paint.fillRRect(ctx, x0, cy - linear_thickness / 2, x1 - x0, linear_thickness, linear_thickness / 2, active);
            } else {
                var xs: [wave_points]f32 = undefined;
                var ys: [wave_points]f32 = undefined;
                // track: the full wave; active: the wave over the progress
                // window (or the sweeping segment when indeterminate)
                const n_track = wavePolyline(&xs, &ys, b.x, b.x + b.w, cy, wave_amplitude, wave_wavelength, s.phase);
                ui.paint.strokePolyline(ctx, xs[0..n_track], ys[0..n_track], linear_thickness, true, track);
                const seg = b.w * 0.4;
                const pos = s.phase * (b.w + seg) - seg;
                const x0: f32 = if (s.opts.progress) |_| b.x else b.x + std.math.clamp(pos, 0, b.w);
                const x1: f32 = if (s.opts.progress) |p| b.x + b.w * std.math.clamp(p, 0, 1) else b.x + std.math.clamp(pos + seg, 0, b.w);
                if (x1 > x0) {
                    const n_active = wavePolyline(&xs, &ys, x0, x1, cy, wave_amplitude, wave_wavelength, s.phase);
                    ui.paint.strokePolyline(ctx, xs[0..n_active], ys[0..n_active], linear_thickness, true, active);
                }
            }
        },
        .circular => {
            const cx = b.x + b.w / 2;
            const cy = b.y + b.h / 2;
            const r = (@min(b.w, b.h) - circular_stroke) / 2;
            var xs: [arc_segments]f32 = undefined;
            var ys: [arc_segments]f32 = undefined;
            // track: the full ring
            const n_track = arcPolyline(&xs, &ys, cx, cy, r, 0, 360);
            ui.paint.strokePolyline(ctx, xs[0..n_track], ys[0..n_track], circular_stroke, false, track);
            // active: determinate = arc from the top spanning progress*360;
            // indeterminate = fixed arc rotating (v1 deviation — header)
            const start: f32 = -90;
            const sweep: f32 = if (s.opts.progress) |p| 360 * std.math.clamp(p, 0, 1) else circular_indet_sweep;
            const rotation: f32 = if (s.opts.progress == null) s.phase * circular_indet_rotation else 0;
            if (sweep > 0) {
                const n_active = arcPolyline(&xs, &ys, cx, cy, r, start + rotation, sweep);
                ui.paint.strokePolyline(ctx, xs[0..n_active], ys[0..n_active], circular_stroke, true, active);
            }
        },
    }
}

fn progressDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    n.allocator.destroy(s);
}

const progress_vtable = ui.node.VTable{
    .measure = progressMeasure,
    .layout = progressLayout,
    .paint = progressPaint,
    .deinit = progressDeinit,
};

/// Indeterminate animation: loop a 0..1 phase tween (linear easing). Without
/// a timeline the indicator renders its phase-0 state (tests).
fn startIndeterminate(n: *Node, s: *ProgressState) void {
    const tl = anim.timeline() orelse return;
    const duration: u32 = if (s.opts.kind == .linear) linear_indet_ms else circular_indet_ms;
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, duration, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.anim_channel),
        .on_update = .{ .fn_ptr = progressPhaseCb, .userdata = n },
        .on_complete = .{ .fn_ptr = progressLoopCb, .userdata = n },
    });
}

fn progressPhaseCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.phase = value[0];
    n.markDirty();
}

fn progressLoopCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.opts.progress == null) startIndeterminate(n, s); // loop forever
}

/// Linear + circular progress indicators (M3E).
pub fn progressIndicator(allocator: std.mem.Allocator, opts: ProgressOptions) !*Node {
    const node = try Node.create(allocator, &progress_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(ProgressState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .progress, .label = "Progress" }); // Phase 2c
    if (opts.progress == null) startIndeterminate(node, s);
    return node;
}

// --- tests ---

test "progress: linear measures full width x 4 (flat) / 10 (wavy); circular 40x40" {
    const lin = try progressIndicator(std.testing.allocator, .{});
    defer lin.deinit();
    const m = lin.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 4), m.h);
    const wavy = try progressIndicator(std.testing.allocator, .{ .wavy = true });
    defer wavy.deinit();
    const mw = wavy.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 10), mw.h);
    const cir = try progressIndicator(std.testing.allocator, .{ .kind = .circular });
    defer cir.deinit();
    const mc = cir.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 40), mc.w);
    try std.testing.expectEqual(@as(f32, 40), mc.h);
}

test "progress: arc and wave polylines stay in bounds" {
    var xs: [arc_segments]f32 = undefined;
    var ys: [arc_segments]f32 = undefined;
    // full circle stays within the 40dp box centered at (20, 20)
    const n = arcPolyline(&xs, &ys, 20, 20, 18, 0, 360);
    try std.testing.expectEqual(arc_segments, n);
    for (0..n) |i| {
        try std.testing.expect(xs[i] >= 20 - 18 - 0.01 and xs[i] <= 20 + 18 + 0.01);
        try std.testing.expect(ys[i] >= 20 - 18 - 0.01 and ys[i] <= 20 + 18 + 0.01);
    }
    // a quarter arc has fewer segments than a full circle
    const q = arcPolyline(&xs, &ys, 20, 20, 18, -90, 90);
    try std.testing.expect(q < n);
    try std.testing.expect(q >= 2);
    // wave: amplitude bounded, endpoints exact
    var wxs: [wave_points]f32 = undefined;
    var wys: [wave_points]f32 = undefined;
    const wn = wavePolyline(&wxs, &wys, 0, 400, 5, wave_amplitude, wave_wavelength, 0);
    try std.testing.expect(wn > 2);
    try std.testing.expectEqual(@as(f32, 0), wxs[0]);
    try std.testing.expect(std.math.approxEqAbs(f32, 400, wxs[wn - 1], 0.01));
    for (0..wn) |i| try std.testing.expect(@abs(wys[i] - 5) <= wave_amplitude + 0.01);
}

test "progress: a capped wave polyline still ends exactly on x1 (wide tracks)" {
    var xs: [wave_points]f32 = undefined;
    var ys: [wave_points]f32 = undefined;
    // 960 wide: the buffer caps the samples at wave_points — the step must
    // derive from the final segment count or the track ends one step short
    const n = wavePolyline(&xs, &ys, 0, 960, 5, wave_amplitude, wave_wavelength, 0);
    try std.testing.expectEqual(wave_points, n);
    try std.testing.expect(std.math.approxEqAbs(f32, 960, xs[n - 1], 0.01));
    // degenerate: zero width = a single point
    try std.testing.expectEqual(@as(usize, 1), wavePolyline(&xs, &ys, 5, 5, 5, wave_amplitude, wave_wavelength, 0));
    try std.testing.expectEqual(@as(f32, 5), xs[0]);
}

test "golden: linear progress paints the track and the active segment" {
    const t = theme_mod.light;
    const bar = try progressIndicator(std.testing.allocator, .{ .progress = 0.5, .theme = t });
    defer bar.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 16);
    defer r.deinit();
    bar.layout(.{ .x = 0, .y = 6, .w = 128, .h = 4 });
    r.paint(bar, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the right half is pure track at the vertical center
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(100, 8));
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(126, 8));
    // the left half is the active segment (progress = 0.5)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(2, 8));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(60, 8));
}

test "golden: circular determinate paints the ring and a quarter arc" {
    const t = theme_mod.light;
    const cir = try progressIndicator(std.testing.allocator, .{ .kind = .circular, .progress = 0.25, .theme = t });
    defer cir.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 48);
    defer r.deinit();
    cir.layout(.{ .x = 4, .y = 4, .w = 40, .h = 40 });
    r.paint(cir, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the arc runs from the top (-90deg) clockwise 90deg (progress = 0.25):
    // top and right points are on the active arc, bottom and left stay track
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(24, 6)); // top (arc start)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(42, 24)); // right (arc end)
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(24, 42)); // bottom
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(6, 24)); // left
}
