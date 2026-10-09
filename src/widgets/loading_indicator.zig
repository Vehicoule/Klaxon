// LoadingIndicator (Phase 2d.4 PR #32, M3E) — the Material 3 Expressive
// shape-morphing loading indicator: an indeterminate morph loop and a
// determinate progress variant, plain + contained.
//
// Spec: Compose LoadingIndicator.kt + LoadingIndicatorTokens:
//   - container 48x48 (ContainerWidth/Height), CornerFull; the contained
//     variant fills it PrimaryContainer with an OnPrimaryContainer
//     indicator; the plain variant is transparent with a Primary indicator
//   - the indicator is 38dp (ActiveSize), scaled 38/48 within the container
//   - indeterminate: morphs between 7 shapes every 650ms
//     (MorphIntervalMillis), +90° of shape rotation per morph, plus a
//     continuous global rotation (360° per 4666ms, GlobalRotationDuration-
//     Millis, linear)
//   - determinate: morphs Circle -> SoftBurst with progress (0..1), rotating
//     -180° over the full range
//
// The widget is a LEAF: it paints its container + the current shape (a
// filled polygon generated in Zig; no path crosses the kx ABI —
// kx_fill_polygon, ABI 0.9.0).
//
// v1 deviations (documented, fixed later):
//   - The shapes are REGULAR N-gons + a circle + a pill (a stadium) rendered
//     as sharp filled polygons — the M3E RoundedPolygon corner rounding and
//     vertex-count normalization are a follow-up (a RoundedPolygon port).
//   - No morph VERTEX interpolation: the indeterminate loop switches shapes
//     discretely every 650ms (the within-morph +90° rotation still animates,
//     linearly — the M3E spring is a follow-up); the determinate variant
//     switches circle -> burst at progress 0.5.
//   - The v1 shape sequence approximates the M3E one by vertex count:
//     [12-gon (SoftBurst), 9-gon (Cookie9Sided), pentagon (Pentagon), pill
//     (Pill), 8-gon (Sunny), square (Cookie4Sided), circle (Oval)].
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const LoadingIndicatorOptions = struct {
    /// The contained variant: a PrimaryContainer 48x48 CornerFull container
    /// with an OnPrimaryContainer indicator (else plain: transparent
    /// container, Primary indicator).
    contained: bool = false,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (LoadingIndicatorTokens / LoadingIndicatorDefaults).
const container_size: f32 = 48; // ContainerWidth/Height
const indicator_size: f32 = 38; // ActiveSize
const morph_interval_ms: u32 = 650; // MorphIntervalMillis
const rotation_period_ms: u32 = 4666; // GlobalRotationDurationMillis
const quarter: f32 = 90; // +90° of shape rotation per morph

/// A shape: a regular N-gon, a pill (a stadium), or a circle.
const ShapeKind = enum { ngon, pill, circle };
const ShapeDef = struct { kind: ShapeKind, n: usize = 0 }; // n: ngons only

/// The v1 indeterminate sequence (7 shapes, approximating the M3E one).
const indeterminate_shapes = [_]ShapeDef{
    .{ .kind = .ngon, .n = 12 }, // SoftBurst
    .{ .kind = .ngon, .n = 9 }, // Cookie9Sided
    .{ .kind = .ngon, .n = 5 }, // Pentagon
    .{ .kind = .pill }, // Pill
    .{ .kind = .ngon, .n = 8 }, // Sunny
    .{ .kind = .ngon, .n = 4 }, // Cookie4Sided (a square)
    .{ .kind = .circle }, // Oval
};

/// The v1 determinate sequence (Circle -> SoftBurst, 2 shapes).
const determinate_shapes = [_]ShapeDef{
    .{ .kind = .circle },
    .{ .kind = .ngon, .n = 12 },
};

const LiState = struct {
    opts: LoadingIndicatorOptions,
    /// The determinate progress (0..1); null = the indeterminate morph loop.
    sig: ?*ui.state.Signal(f32) = null,
    morph_index: usize = 0,
    morph_rotation: f32 = 0, // the per-morph +90° steps
    morph_progress: f32 = 0, // 0..1 within the current morph (drives +90°)
    global_rotation: f32 = 0, // 0..360 continuous
    loop_running: bool = false, // the indeterminate loop launched
    anim_channel: u8 = 0, // morph channel marker (stable address)
    rot_channel: u8 = 0, // global rotation channel marker (stable address)
};

fn stateOf(n: *Node) *LiState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The current shape index + rotation (pub accessors — tests + the app).
pub fn morphIndex(n: *Node) usize {
    return stateOf(n).morph_index;
}
pub fn shapeRotation(n: *Node) f32 {
    const s = stateOf(n);
    if (s.sig != null) {
        const p = std.math.clamp(s.sig.?.peek(), 0, 1);
        return -p * 180; // determinate: counterclockwise
    }
    return s.morph_progress * quarter + s.morph_rotation + s.global_rotation;
}

fn liMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = container_size, .h = container_size });
}

fn liLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    _ = bounds;
    // The indeterminate loop starts at the first layout that has a timeline
    // (golden tests have none — the indicator stays static there).
    if (s.sig == null and !s.loop_running) startLoop(n, s);
}

/// Paint a shape centered at (cx, cy): a regular N-gon, a pill (a stadium
/// 2r x r), or a circle, rotated by `rotation` degrees (clockwise).
fn paintShape(ctx: *kx.Ctx, shape: ShapeDef, cx: f32, cy: f32, r: f32, rotation: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    switch (shape.kind) {
        .circle => {
            ui.paint.fillRRect(ctx, cx - r, cy - r, r * 2, r * 2, r, color);
        },
        .pill => {
            // a horizontal stadium: 2r wide, r tall, centered
            ui.paint.fillRRect(ctx, cx - r, cy - r / 2, r * 2, r, r / 2, color);
        },
        .ngon => {
            const n: usize = shape.n;
            // even N-gons get a flat top (a square stays axis-aligned), odd
            // N-gons a vertex up
            const start: f32 = if (n % 2 == 0)
                -std.math.pi / 2.0 + std.math.pi / @as(f32, @floatFromInt(n))
            else
                -std.math.pi / 2.0;
            const rot = rotation * std.math.pi / 180;
            var xs: [16]f32 = undefined;
            var ys: [16]f32 = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a = start + rot + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                xs[i] = cx + @cos(a) * r;
                ys[i] = cy + @sin(a) * r;
            }
            ui.paint.fillPolygon(ctx, xs[0..n], ys[0..n], color);
        },
    }
}

fn liPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    const d = @min(b.w, b.h);
    // the container (the contained variant only)
    if (s.opts.contained) {
        ui.paint.fillRRect(ctx, cx - d / 2, cy - d / 2, d, d, d / 2, t.colors.primary_container);
    }
    // the indicator color
    const color: Color = if (s.opts.contained) t.colors.on_primary_container else t.colors.primary;
    // the shape box: square, scaled 38/48 within the container
    const r = d / 2 * (indicator_size / container_size);
    // the current shape + rotation
    if (s.sig) |sig| {
        const p = std.math.clamp(sig.peek(), 0, 1);
        const shape = determinate_shapes[if (p < 0.5) 0 else 1]; // v1: discrete
        paintShape(ctx, shape, cx, cy, r, -p * 180, color);
    } else {
        const shape = indeterminate_shapes[s.morph_index % indeterminate_shapes.len];
        paintShape(ctx, shape, cx, cy, r, shapeRotation(n), color);
    }
}

/// The indeterminate loop, driven by the timeline: a morph tween (650ms
/// linear — the within-morph +90° rotation) chained per morph, and a global
/// rotation tween (4666ms linear) chained per period. Without a timeline the
/// indicator stays static (golden tests).
fn startLoop(n: *Node, s: *LiState) void {
    const tl = anim.timeline() orelse return;
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, morph_interval_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.anim_channel),
        .on_update = .{ .fn_ptr = liMorphUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liMorphCompleteCb, .userdata = n },
    });
    _ = tl.play(.{
        .kind = anim.Animation.tweenAnim(.{ 360, 0, 0, 0 }, rotation_period_ms, .{ .ease = .linear }),
        .from = .{ 0, 0, 0, 0 },
        .channel = @ptrCast(&s.rot_channel),
        .on_update = .{ .fn_ptr = liRotUpdateCb, .userdata = n },
        .on_complete = .{ .fn_ptr = liRotCompleteCb, .userdata = n },
    });
    s.loop_running = true;
}

fn liMorphUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.morph_progress = value[0];
    n.markDirty();
}

fn liMorphCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.morph_index = (s.morph_index + 1) % indeterminate_shapes.len;
    s.morph_rotation = @mod(s.morph_rotation + quarter, 360);
    s.morph_progress = 0;
    n.markDirty();
    // chain the next morph (the same channel cancels the finished one)
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, morph_interval_ms, .{ .ease = .linear }),
            .from = .{ 0, 0, 0, 0 },
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = liMorphUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = liMorphCompleteCb, .userdata = n },
        });
    }
}

fn liRotUpdateCb(userdata: ?*anyopaque, value: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).global_rotation = value[0];
    n.markDirty();
}

fn liRotCompleteCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.global_rotation = 0;
    n.markDirty();
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.tweenAnim(.{ 360, 0, 0, 0 }, rotation_period_ms, .{ .ease = .linear }),
            .from = .{ 0, 0, 0, 0 },
            .channel = @ptrCast(&s.rot_channel),
            .on_update = .{ .fn_ptr = liRotUpdateCb, .userdata = n },
            .on_complete = .{ .fn_ptr = liRotCompleteCb, .userdata = n },
        });
    }
}

/// The determinate progress changed (the app): repaint.
fn liSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    n.markDirty();
}

fn liDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.anim_channel));
        tl.cancelChannel(@ptrCast(&s.rot_channel));
    }
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const li_vtable = ui.node.VTable{
    .measure = liMeasure,
    .layout = liLayout,
    .paint = liPaint,
    .deinit = liDeinit,
};

/// An M3E loading indicator. `progress` = null → the indeterminate morph
/// loop (timeline-driven; static without a timeline); non-null → determinate
/// (the signal's 0..1 value selects the shape + rotation). The widget is a
/// leaf: it paints its container + the current shape.
pub fn loadingIndicator(allocator: std.mem.Allocator, progress: ?*ui.state.Signal(f32), opts: LoadingIndicatorOptions) !*Node {
    const node = try Node.create(allocator, &li_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(LiState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .sig = progress };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .progress, .label = "Loading indicator" }); // Phase 2c
    if (progress) |sig| sig.subscribe(.{ .callback = .{ .fn_ptr = liSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

test "loading_indicator: measures the 48x48 container" {
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    const m = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(container_size, m.w);
    try std.testing.expectEqual(container_size, m.h);
    try std.testing.expectEqual(ui.semantics.Role.progress, n.semantics.?.role);
}

test "loading_indicator: without a timeline the indeterminate loop stays static at shape 0" {
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expectEqual(@as(usize, 0), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 0), shapeRotation(n));
}

test "loading_indicator: the indeterminate loop advances the morph + rotation on the timeline" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start
    // mid-morph (325ms): morph_progress 0.5 → +45°, plus the global rotation
    // (325/4666 × 360 ≈ 25.07°)
    tl.tick(325);
    try std.testing.expectApproxEqAbs(@as(f32, 45), stateOf(n).morph_progress * quarter, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70.07), shapeRotation(n), 1.0);
}

test "loading_indicator: a completed morph advances the index + 90° (and the rotation wraps)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const n = try loadingIndicator(std.testing.allocator, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    tl.tick(0); // lazy start
    tl.tick(650); // the first morph completes
    try std.testing.expectEqual(@as(usize, 1), morphIndex(n));
    // the next morph starts: morph_progress 0, morph_rotation 90
    try std.testing.expectEqual(@as(f32, 0), stateOf(n).morph_progress);
    try std.testing.expectEqual(@as(f32, 90), stateOf(n).morph_rotation);
    // the second morph completes at 1300ms: index 2, rotation 180
    tl.tick(1300);
    try std.testing.expectEqual(@as(usize, 2), morphIndex(n));
    try std.testing.expectEqual(@as(f32, 180), stateOf(n).morph_rotation);
    // the global rotation is independent (linear, 360° per 4666ms)
    try std.testing.expect(stateOf(n).global_rotation > 0);
}

test "loading_indicator: determinate — the signal selects the shape + rotation" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const n = try loadingIndicator(std.testing.allocator, sig, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 48, .h = 48 });
    try std.testing.expectEqual(@as(f32, 0), shapeRotation(n)); // p=0 → circle, no rotation
    sig.set(0.25);
    try std.testing.expectEqual(@as(f32, -45), shapeRotation(n)); // -p × 180
    sig.set(0.75);
    try std.testing.expectEqual(@as(f32, -135), shapeRotation(n)); // the burst shape, rotated
    // out-of-range progress clamps
    sig.set(2);
    try std.testing.expectEqual(@as(f32, -180), shapeRotation(n));
}

test "golden: the contained variant paints the PrimaryContainer circle + the Primary indicator shape" {
    const t = theme_mod.light;
    const n = try loadingIndicator(std.testing.allocator, null, .{ .contained = true, .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    n.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: a 48dp circle (primary_container), its corner is background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(8, 8));
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(32, 12)); // inside the circle, above the shape
    // the indicator (on_primary_container): shape 0 = a 12-gon at radius
    // 48/2 × 38/48 = 19 centered at (32, 32) — its ink is inside the circle
    try std.testing.expect(f.countColorIn(.{ .x = 13, .y = 13, .w = 38, .h = 38 }, t.colors.on_primary_container) > 0);
    // the exact center is indicator ink (a filled polygon covers it)
    try std.testing.expectEqual(t.colors.on_primary_container, f.pixelAt(32, 32));
}

test "golden: the plain variant paints no container — the Primary shape over the background" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const n = try loadingIndicator(std.testing.allocator, sig, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    n.layout(.{ .x = 8, .y = 8, .w = 48, .h = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // determinate p=0 → the circle shape (radius 19 at (32,32)): primary ink
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(32, 32));
    // the shape's bounding box edge (radius 19 → x = 13..51): just outside is background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(10, 32));
    // no container: the corner is background (not primary_container)
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(8, 8));
    // progress 0.75 → the 12-gon (burst) shape, rotated -135°: ink at the center
    sig.set(0.75);
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(32, 32));
    // a 12-gon has gaps between its points near the bounding radius: the
    // corner of the 38dp box (13, 13) is outside the polygon (rotated)
    try std.testing.expect(f2.countColorIn(.{ .x = 13, .y = 13, .w = 6, .h = 6 }, t.colors.primary) == 0);
}
