// Animated widgets (Phase 1e) — implicit animations: the app drives a
// Signal; the widget animates its displayed value toward the target (spring
// or tween) through ui/anim.zig's Timeline and repaints/relayouts as it
// ticks. Retargeting mid-flight cancels the previous animation (channels).
//
//   AnimatedContainer — width / height / color (layout + paint animations)
//   AnimatedOffset    — child offset (paint-time canvas transform)
//   AnimatedScale     — child scale around its center (paint-time transform)
//
// Without a timeline (unit tests), target changes snap to the target.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const anim = @import("../ui/anim.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const EdgeInsets = ui.layout.EdgeInsets;
const Color = ui.paint.Color;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

/// A display-signal change repaints AND re-layouts the node (animated size).
fn markDirtyLayoutCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    n.markDirty();
    n.markLayoutDirty();
}

// --- AnimatedContainer — width / height / color ---

pub const AnimatedContainerOptions = struct {
    width: ?*ui.state.Signal(f32) = null,
    height: ?*ui.state.Signal(f32) = null,
    color: ?*ui.state.Signal(Color) = null,
    radius: f32 = 0,
    padding: EdgeInsets = .{},
    motion: anim.Motion = .{ .spring = .{} },
};

const ContainerState = struct {
    opts: AnimatedContainerOptions,
    w_sig: ?*ui.state.Signal(f32) = null,
    h_sig: ?*ui.state.Signal(f32) = null,
    color_sig: ?*ui.state.Signal(Color) = null,
    size_effect: ?*ui.state.Effect = null,
    color_effect: ?*ui.state.Effect = null,
    // Channel markers (stable addresses): one animation per property group.
    size_channel: u8 = 0,
    color_channel: u8 = 0,
};

fn sizeUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const s: *ContainerState = @ptrCast(@alignCast(userdata.?));
    // One SIMD animation drives width + height at once (lanes 0/1).
    if (s.w_sig) |sig| sig.set(v[0]);
    if (s.h_sig) |sig| sig.set(v[1]);
}

fn colorUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const s: *ContainerState = @ptrCast(@alignCast(userdata.?));
    if (s.color_sig) |sig| sig.set(anim.vec4ToColor(v));
}

fn sizeEffectCb(userdata: ?*anyopaque) void {
    const s: *ContainerState = @ptrCast(@alignCast(userdata.?));
    var from: anim.Vec4 = .{ 0, 0, 0, 0 };
    var to: anim.Vec4 = .{ 0, 0, 0, 0 };
    if (s.w_sig) |sig| {
        from[0] = sig.peek(); // display: untracked read
        to[0] = if (s.opts.width) |w| w.get() else from[0]; // target: tracked
    }
    if (s.h_sig) |sig| {
        from[1] = sig.peek();
        to[1] = if (s.opts.height) |h| h.get() else from[1];
    }
    if (@reduce(.And, from == to)) {
        // Retargeted to the displayed value: stop the channel's animation.
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.size_channel));
        return;
    }
    const tl = anim.timeline() orelse {
        if (s.w_sig) |sig| sig.set(to[0]); // no timeline: snap
        if (s.h_sig) |sig| sig.set(to[1]);
        return;
    };
    _ = tl.play(.{
        .kind = anim.Animation.kindOf(s.opts.motion, from, to),
        .from = from,
        .channel = @ptrCast(&s.size_channel),
        .on_update = .{ .fn_ptr = sizeUpdateCb, .userdata = s },
    });
}

fn colorEffectCb(userdata: ?*anyopaque) void {
    const s: *ContainerState = @ptrCast(@alignCast(userdata.?));
    const sig = s.color_sig orelse return;
    const from = anim.colorToVec4(sig.peek());
    const to = anim.colorToVec4(s.opts.color.?.get()); // target: tracked
    if (@reduce(.And, from == to)) {
        // Retargeted to the displayed value: stop the channel's animation.
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.color_channel));
        return;
    }
    const tl = anim.timeline() orelse {
        sig.set(anim.vec4ToColor(to)); // no timeline: snap
        return;
    };
    _ = tl.play(.{
        .kind = anim.Animation.kindOf(s.opts.motion, from, to),
        .from = from,
        .channel = @ptrCast(&s.color_channel),
        .on_update = .{ .fn_ptr = colorUpdateCb, .userdata = s },
    });
}

fn containerMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ContainerState, n);
    const inner = c.deflateEdge(s.opts.padding);
    var size = Size{};
    if (n.children.items.len > 0) {
        const cs = n.children.items[0].measure(inner);
        size = .{ .w = cs.w + s.opts.padding.hSum(), .h = cs.h + s.opts.padding.vSum() };
    }
    if (s.w_sig) |sig| size.w = sig.peek(); // animated width overrides
    if (s.h_sig) |sig| size.h = sig.peek();
    return c.constrain(size);
}
fn containerLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    const s = stateOf(ContainerState, n);
    n.children.items[0].layout(.{
        .x = bounds.x + s.opts.padding.left,
        .y = bounds.y + s.opts.padding.top,
        .w = @max(0, bounds.w - s.opts.padding.hSum()),
        .h = @max(0, bounds.h - s.opts.padding.vSum()),
    });
}
fn containerPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ContainerState, n);
    const sig = s.color_sig orelse return;
    const b = n.bounds;
    if (s.opts.radius > 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, sig.peek());
    } else {
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, sig.peek());
    }
}
fn containerDeinit(n: *Node) void {
    const s = stateOf(ContainerState, n);
    // Cancel in-flight animations on our channels before freeing (UAF guard).
    if (anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.size_channel));
        tl.cancelChannel(@ptrCast(&s.color_channel));
    }
    if (s.size_effect) |e| e.deinit();
    if (s.color_effect) |e| e.deinit();
    if (s.w_sig) |sig| sig.deinit();
    if (s.h_sig) |sig| sig.deinit();
    if (s.color_sig) |sig| sig.deinit();
    n.allocator.destroy(s);
}
const container_vtable = ui.node.VTable{ .measure = containerMeasure, .layout = containerLayout, .paint = containerPaint, .deinit = containerDeinit };

pub fn animatedContainer(allocator: std.mem.Allocator, opts: AnimatedContainerOptions) !*Node {
    const node = try Node.create(allocator, &container_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ContainerState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    if (opts.width) |w| {
        s.w_sig = try ui.state.Signal(f32).init(allocator, w.peek());
        errdefer if (s.w_sig) |sig| sig.deinit();
    }
    if (opts.height) |h| {
        s.h_sig = try ui.state.Signal(f32).init(allocator, h.peek());
        errdefer if (s.h_sig) |sig| sig.deinit();
    }
    if (opts.color) |col| {
        s.color_sig = try ui.state.Signal(Color).init(allocator, col.peek());
        errdefer if (s.color_sig) |sig| sig.deinit();
    }
    if (s.w_sig != null or s.h_sig != null) {
        s.size_effect = try ui.state.Effect.init(allocator, sizeEffectCb, s);
        errdefer if (s.size_effect) |e| e.deinit();
        s.size_effect.?.run(); // subscribe; display starts at the target
    }
    if (s.color_sig != null) {
        s.color_effect = try ui.state.Effect.init(allocator, colorEffectCb, s);
        errdefer if (s.color_effect) |e| e.deinit();
        s.color_effect.?.run();
    }
    // Display changes repaint (color) / repaint + relayout (size).
    if (s.w_sig) |sig| sig.subscribe(.{ .callback = .{ .fn_ptr = markDirtyLayoutCb, .userdata = node } });
    if (s.h_sig) |sig| sig.subscribe(.{ .callback = .{ .fn_ptr = markDirtyLayoutCb, .userdata = node } });
    if (s.color_sig) |sig| ui.state.bindNode(node, sig);
    node.state = s;
    return node;
}

// --- AnimatedOffset — child offset (paint-time translate) ---

pub const Offset = struct { x: f32 = 0, y: f32 = 0 };

pub const AnimatedOffsetOptions = struct {
    offset: *ui.state.Signal(Offset),
    motion: anim.Motion = .{ .spring = .{} },
};

const OffsetState = struct {
    opts: AnimatedOffsetOptions,
    node: *Node,
    dx: f32 = 0,
    dy: f32 = 0,
    effect: ?*ui.state.Effect = null,
    channel: u8 = 0,
};

fn applyOffset(s: *OffsetState, v: anim.Vec4) void {
    // Damage: a pure translation covers bbox(old region, new region).
    const b = s.node.bounds;
    const old = Rect{ .x = b.x + s.dx, .y = b.y + s.dy, .w = b.w, .h = b.h };
    s.dx = v[0];
    s.dy = v[1];
    const new = Rect{ .x = b.x + s.dx, .y = b.y + s.dy, .w = b.w, .h = b.h };
    s.node.markDirtyRect(ui.node.rectUnion(old, new));
}

fn offsetUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    applyOffset(@ptrCast(@alignCast(userdata.?)), v);
}

fn offsetEffectCb(userdata: ?*anyopaque) void {
    const s: *OffsetState = @ptrCast(@alignCast(userdata.?));
    const target = s.opts.offset.get(); // tracked
    const from: anim.Vec4 = .{ s.dx, s.dy, 0, 0 };
    const to: anim.Vec4 = .{ target.x, target.y, 0, 0 };
    if (@reduce(.And, from == to)) {
        // Retargeted to the displayed value: stop the channel's animation.
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.channel));
        return;
    }
    const tl = anim.timeline() orelse {
        applyOffset(s, to); // no timeline: snap
        return;
    };
    _ = tl.play(.{
        .kind = anim.Animation.kindOf(s.opts.motion, from, to),
        .from = from,
        .channel = @ptrCast(&s.channel),
        .on_update = .{ .fn_ptr = offsetUpdateCb, .userdata = s },
    });
}

fn offsetMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn offsetLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn offsetPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // the transform wraps the children's paint (hooks below)
}
fn offsetPrePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(OffsetState, n);
    ui.paint.save(ctx);
    ui.paint.translate(ctx, s.dx, s.dy);
}
fn offsetPostPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}
/// The children paint at bounds + (dx, dy): hit area and damage follow.
fn offsetHitBounds(n: *Node) Rect {
    const s = stateOf(OffsetState, n);
    const b = n.bounds;
    return .{ .x = b.x + s.dx, .y = b.y + s.dy, .w = b.w, .h = b.h };
}
fn offsetPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(OffsetState, n);
    return .{ .x = px - s.dx, .y = py - s.dy };
}
fn offsetMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(OffsetState, n);
    return .{ .x = rect.x + s.dx, .y = rect.y + s.dy, .w = rect.w, .h = rect.h };
}
fn offsetDeinit(n: *Node) void {
    const s = stateOf(OffsetState, n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.channel));
    if (s.effect) |e| e.deinit();
    n.allocator.destroy(s);
}
const offset_vtable = ui.node.VTable{
    .measure = offsetMeasure,
    .layout = offsetLayout,
    .paint = offsetPaint,
    .deinit = offsetDeinit,
    .pre_children_paint = offsetPrePaint,
    .post_children_paint = offsetPostPaint,
    .map_paint_rect = offsetMapPaintRect,
    .hit_bounds = offsetHitBounds,
    .pre_children_hit = offsetPreChildrenHit,
};

pub fn animatedOffset(allocator: std.mem.Allocator, opts: AnimatedOffsetOptions) !*Node {
    const node = try Node.create(allocator, &offset_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(OffsetState);
    errdefer allocator.destroy(s);
    const initial = opts.offset.peek();
    s.* = .{ .opts = opts, .node = node, .dx = initial.x, .dy = initial.y };
    s.effect = try ui.state.Effect.init(allocator, offsetEffectCb, s);
    errdefer if (s.effect) |e| e.deinit();
    s.effect.?.run(); // subscribe; display starts at the target
    node.state = s;
    return node;
}

// --- AnimatedScale — child scale around its center (paint-time scale) ---

pub const AnimatedScaleOptions = struct {
    scale: *ui.state.Signal(f32), // uniform factor, pivot = the child's center
    motion: anim.Motion = .{ .spring = .{} },
};

const ScaleState = struct {
    opts: AnimatedScaleOptions,
    node: *Node,
    factor: f32 = 1,
    effect: ?*ui.state.Effect = null,
    channel: u8 = 0,
};

/// The child's region under a uniform scale around the bounds' center.
fn scaledRect(b: Rect, f: f32) Rect {
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{ .x = cx - b.w * f / 2, .y = cy - b.h * f / 2, .w = b.w * f, .h = b.h * f };
}

fn applyScale(s: *ScaleState, v: anim.Vec4) void {
    const old = scaledRect(s.node.bounds, s.factor);
    s.factor = v[0];
    const new = scaledRect(s.node.bounds, s.factor);
    s.node.markDirtyRect(ui.node.rectUnion(old, new));
}

fn scaleUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    applyScale(@ptrCast(@alignCast(userdata.?)), v);
}

fn scaleEffectCb(userdata: ?*anyopaque) void {
    const s: *ScaleState = @ptrCast(@alignCast(userdata.?));
    const target = s.opts.scale.get(); // tracked
    const from: anim.Vec4 = .{ s.factor, 0, 0, 0 };
    const to: anim.Vec4 = .{ target, 0, 0, 0 };
    if (@reduce(.And, from == to)) {
        // Retargeted to the displayed value: stop the channel's animation.
        if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.channel));
        return;
    }
    const tl = anim.timeline() orelse {
        applyScale(s, to); // no timeline: snap
        return;
    };
    _ = tl.play(.{
        .kind = anim.Animation.kindOf(s.opts.motion, from, to),
        .from = from,
        .channel = @ptrCast(&s.channel),
        .on_update = .{ .fn_ptr = scaleUpdateCb, .userdata = s },
    });
}

fn scaleMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn scaleLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn scalePaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn scalePrePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ScaleState, n);
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    ui.paint.save(ctx);
    ui.paint.translate(ctx, cx, cy);
    ui.paint.scale(ctx, s.factor, s.factor);
    ui.paint.translate(ctx, -cx, -cy);
}
fn scalePostPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.restore(ctx);
}
/// The children paint scaled around the bounds' center: hit area and damage
/// follow (a zero factor leaves a degenerate, unhittable rect).
fn scaleHitBounds(n: *Node) Rect {
    const s = stateOf(ScaleState, n);
    return scaledRect(n.bounds, s.factor);
}
fn scalePreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(ScaleState, n);
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{ .x = cx + (px - cx) / s.factor, .y = cy + (py - cy) / s.factor };
}
fn scaleMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(ScaleState, n);
    const b = n.bounds;
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    return .{
        .x = cx + (rect.x - cx) * s.factor,
        .y = cy + (rect.y - cy) * s.factor,
        .w = rect.w * s.factor,
        .h = rect.h * s.factor,
    };
}
fn scaleDeinit(n: *Node) void {
    const s = stateOf(ScaleState, n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.channel));
    if (s.effect) |e| e.deinit();
    n.allocator.destroy(s);
}
const scale_vtable = ui.node.VTable{
    .measure = scaleMeasure,
    .layout = scaleLayout,
    .paint = scalePaint,
    .deinit = scaleDeinit,
    .pre_children_paint = scalePrePaint,
    .post_children_paint = scalePostPaint,
    .map_paint_rect = scaleMapPaintRect,
    .hit_bounds = scaleHitBounds,
    .pre_children_hit = scalePreChildrenHit,
};

pub fn animatedScale(allocator: std.mem.Allocator, opts: AnimatedScaleOptions) !*Node {
    const node = try Node.create(allocator, &scale_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ScaleState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .node = node, .factor = opts.scale.peek() };
    s.effect = try ui.state.Effect.init(allocator, scaleEffectCb, s);
    errdefer if (s.effect) |e| e.deinit();
    s.effect.?.run();
    node.state = s;
    return node;
}

// --- tests ---

fn testTimeline() anim.Timeline {
    return anim.Timeline.init(std.testing.allocator);
}

test "animatedContainer: target change animates the display size (tween)" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 10);
    defer w.deinit();
    const h = try ui.state.Signal(f32).init(std.testing.allocator, 20);
    defer h.deinit();
    const root = try animatedContainer(std.testing.allocator, .{
        .width = w,
        .height = h,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try std.testing.expectEqual(@as(f32, 10), root.measure(.{}).w);
    w.set(40); // effect → play (from 10 → 40)
    try std.testing.expect(tl.hasActive());
    root.dirty = false;
    root.layout_dirty = false;
    tl.tick(0); // lazy start
    tl.tick(50); // halfway
    try std.testing.expectApproxEqAbs(@as(f32, 25), root.measure(.{}).w, 0.01);
    try std.testing.expect(root.dirty and root.layout_dirty); // display change flags both
    tl.tick(100); // completes → exact target
    try std.testing.expectEqual(@as(f32, 40), root.measure(.{}).w);
    try std.testing.expect(!tl.hasActive());
}

test "animatedContainer: without a timeline, target changes snap" {
    anim.setCurrent(null);
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 10);
    defer w.deinit();
    const root = try animatedContainer(std.testing.allocator, .{ .width = w });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    w.set(40);
    try std.testing.expectEqual(@as(f32, 40), root.measure(.{}).w); // snapped
}

test "animatedContainer: retargeting mid-flight cancels the previous animation" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 10);
    defer w.deinit();
    const root = try animatedContainer(std.testing.allocator, .{
        .width = w,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    w.set(40);
    tl.tick(0); // lazy start
    tl.tick(50); // mid-flight at 25
    try std.testing.expectApproxEqAbs(@as(f32, 25), root.measure(.{}).w, 0.01);
    w.set(10); // retarget back: the size animation is replaced, not stacked
    var active: usize = 0;
    for (tl.animations.items) |a| {
        if (!a.done) active += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), active);
    tl.tick(50); // the new tween starts here
    tl.tick(100); // 50 ms into the new tween (25 → 10)
    try std.testing.expectApproxEqAbs(@as(f32, 17.5), root.measure(.{}).w, 0.01);
}

test "animatedContainer: retargeting to the displayed value stops the animation" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 10);
    defer w.deinit();
    const root = try animatedContainer(std.testing.allocator, .{
        .width = w,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    w.set(40); // animates 10 → 40
    tl.tick(0); // lazy start
    tl.tick(50); // displayed = 25
    try std.testing.expectApproxEqAbs(@as(f32, 25), root.measure(.{}).w, 0.01);
    w.set(25); // retarget to the displayed value: the animation must stop
    try std.testing.expect(!tl.hasActive());
    tl.tick(100); // nothing left running: the display stays at 25
    try std.testing.expectApproxEqAbs(@as(f32, 25), root.measure(.{}).w, 0.01);
}

test "animatedContainer: deinit cancels in-flight animations (no UAF)" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 10);
    defer w.deinit();
    const root = try animatedContainer(std.testing.allocator, .{
        .width = w,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    w.set(40);
    try std.testing.expect(tl.hasActive());
    root.deinit(); // cancels the channel's animation
    try std.testing.expect(!tl.hasActive());
    tl.tick(50); // nothing left to write into freed memory
}

test "golden: animatedContainer color interpolates mid-animation" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const red: Color = 0xFF0000FF;
    const blue: Color = 0x0000FFFF;
    const color = try ui.state.Signal(Color).init(std.testing.allocator, red);
    defer color.deinit();
    const w = try ui.state.Signal(f32).init(std.testing.allocator, 40);
    defer w.deinit();
    const h = try ui.state.Signal(f32).init(std.testing.allocator, 40);
    defer h.deinit();
    const bg: Color = 0x000000FF;
    const root = try animatedContainer(std.testing.allocator, .{
        .width = w,
        .height = h,
        .color = color,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(red, f1.pixelAt(20, 20));
    // red → blue, halfway: channels at 50%
    color.set(blue);
    tl.tick(0); // lazy start
    tl.tick(50);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x7F007FFF), f2.pixelAt(20, 20));
    tl.tick(100); // completes
    r.paint(root, bg);
    var f3 = try r.readback(std.testing.allocator);
    defer f3.deinit();
    try std.testing.expectEqual(blue, f3.pixelAt(20, 20));
}

test "golden: animatedOffset paints the child at the animated offset" {
    var tl = testTimeline();
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const bg: Color = 0x000000FF;
    const green: Color = 0x00FF00FF;
    const off = try ui.state.Signal(Offset).init(std.testing.allocator, .{ .x = 0, .y = 0 });
    defer off.deinit();
    const root = try animatedOffset(std.testing.allocator, .{
        .offset = off,
        .motion = .{ .tween = .{ .duration_ms = 100, .curve = .{ .ease = .linear } } },
    });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 20, 20, green));
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    root.layout(.{ .x = 10, .y = 10, .w = 20, .h = 20 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(green, f1.pixelAt(15, 15)); // at (10,10)
    try std.testing.expectEqual(bg, f1.pixelAt(5, 5));
    // animate the offset to (10, 0); halfway the child sits at x=15
    off.set(.{ .x = 10, .y = 0 });
    tl.tick(0); // lazy start
    tl.tick(50);
    try std.testing.expect(root.damage_valid);
    // damage covers the swept region: (10,10,20,20) ∪ (15,10,20,20)
    try std.testing.expectEqual(@as(f32, 10), root.damage.x);
    try std.testing.expectEqual(@as(f32, 10), root.damage.y);
    try std.testing.expectEqual(@as(f32, 25), root.damage.w);
    try std.testing.expectEqual(@as(f32, 20), root.damage.h);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(bg, f2.pixelAt(12, 15)); // old spot vacated
    try std.testing.expectEqual(green, f2.pixelAt(20, 15)); // child at +5
}

test "animatedOffset: without a timeline the offset snaps" {
    anim.setCurrent(null);
    const off = try ui.state.Signal(Offset).init(std.testing.allocator, .{});
    defer off.deinit();
    const root = try animatedOffset(std.testing.allocator, .{ .offset = off });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 10, 10, 0x00FF00FF));
    root.layout(.{ .x = 10, .y = 10, .w = 10, .h = 10 });
    off.set(.{ .x = 10, .y = 0 });
    const s = stateOf(OffsetState, root);
    try std.testing.expectEqual(@as(f32, 10), s.dx);
    try std.testing.expect(root.dirty);
}

test "animatedOffset: hit-testing lands on the visual position" {
    anim.setCurrent(null);
    const off = try ui.state.Signal(Offset).init(std.testing.allocator, .{});
    defer off.deinit();
    const root = try animatedOffset(std.testing.allocator, .{ .offset = off });
    defer root.deinit();
    // Child fills the offset node's bounds (fill semantics).
    const child = try golden.solidBox(std.testing.allocator, 10, 10, 0x00FF00FF);
    root.add(child);
    root.layout(.{ .x = 10, .y = 10, .w = 10, .h = 10 });
    off.set(.{ .x = 20, .y = 0 }); // child visually at (30, 10)
    // hit at the visual position → the child; at the old (vacated) position
    // and far outside → nothing (the offset node's hit area moved with it).
    try std.testing.expectEqual(child, root.hitTest(35, 15).?);
    try std.testing.expect(root.hitTest(15, 15) == null);
    try std.testing.expect(root.hitTest(5, 5) == null);
}

test "animatedOffset: child damage maps to the visual position" {
    anim.setCurrent(null);
    const off = try ui.state.Signal(Offset).init(std.testing.allocator, .{});
    defer off.deinit();
    const root = try animatedOffset(std.testing.allocator, .{ .offset = off });
    defer root.deinit();
    const child = try golden.solidBox(std.testing.allocator, 10, 10, 0x00FF00FF);
    root.add(child);
    root.layout(.{ .x = 10, .y = 10, .w = 10, .h = 10 });
    off.set(.{ .x = 20, .y = 0 }); // visual position (30, 10)
    root.clearDamage();
    child.markDirty(); // the child's bounds mapped through the transform
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 30), root.damage.x);
    try std.testing.expectEqual(@as(f32, 10), root.damage.y);
    try std.testing.expectEqual(@as(f32, 10), root.damage.w);
    try std.testing.expectEqual(@as(f32, 10), root.damage.h);
}

test "golden: animatedScale scales the child around its center" {
    anim.setCurrent(null); // snap
    const bg: Color = 0x000000FF;
    const green: Color = 0x00FF00FF;
    const sc = try ui.state.Signal(f32).init(std.testing.allocator, 1);
    defer sc.deinit();
    const root = try animatedScale(std.testing.allocator, .{ .scale = sc });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 20, 20, green));
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    root.layout(.{ .x = 10, .y = 10, .w = 20, .h = 20 });
    sc.set(2); // 2x around the center (20,20) → covers (0,0)-(40,40)
    r.paint(root, bg);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(green, f.pixelAt(5, 5));
    try std.testing.expectEqual(green, f.pixelAt(35, 35));
    try std.testing.expectEqual(bg, f.pixelAt(45, 45)); // outside the scaled region
    try std.testing.expectEqual(@as(u64, 40 * 40), f.countColor(green));
}
