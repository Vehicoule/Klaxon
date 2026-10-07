// GestureDetector (Phase 1d) — declarative gesture wrapper. Wraps a child
// (fill semantics, like Padding) and feeds its pointer events to a
// GestureArena (ui/gestures.zig): recognizers compete, the first to claim
// wins, callbacks fire. The detector claims pointer events on its area;
// children with their own input handlers (Button, …) still get them first
// (hit-test → deepest node → bubbling).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const anim = @import("../ui/anim.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

pub const GestureDetectorOptions = struct {
    callbacks: gestures.GestureCallbacks = .{},
};

const DetectorState = struct {
    arena: gestures.GestureArena,
    /// Set when the arena is registered as a timeline ticker (long-press
    /// precision, Phase 1e): the ticker is removed at deinit.
    ticker: ?anim.Timeline.Ticker = null,
};

fn arenaTickCb(userdata: ?*anyopaque, now_ms: u64) void {
    const arena: *gestures.GestureArena = @ptrCast(@alignCast(userdata.?));
    arena.tick(now_ms);
}

fn arenaHasPendingCb(userdata: ?*anyopaque) bool {
    const arena: *gestures.GestureArena = @ptrCast(@alignCast(userdata.?));
    return arena.hasPendingTimeWork();
}

fn detectorMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(c);
    return c.constrain(size);
}
fn detectorLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn detectorPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn detectorOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(DetectorState, n);
    s.arena.feed(ev);
    return true; // a gesture detector claims pointer events on its area
}
fn detectorDeinit(n: *Node) void {
    const s = stateOf(DetectorState, n);
    if (s.ticker) |t| {
        if (anim.timeline()) |tl| tl.removeTicker(t);
    }
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const detector_vtable = ui.node.VTable{
    .measure = detectorMeasure,
    .layout = detectorLayout,
    .paint = detectorPaint,
    .deinit = detectorDeinit,
    .on_pointer = detectorOnPointer,
};

pub fn gestureDetector(allocator: std.mem.Allocator, opts: GestureDetectorOptions) !*Node {
    const node = try Node.create(allocator, &detector_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DetectorState);
    errdefer allocator.destroy(s);
    s.* = .{ .arena = gestures.GestureArena.init(opts.callbacks) };
    // Register the arena as a timeline ticker: long-press fires precisely at
    // the threshold (the host ticks the timeline every loop iteration), and
    // has_pending lets the host bound its idle wait while a pointer is held.
    if (anim.timeline()) |tl| {
        const t = anim.Timeline.Ticker{
            .fn_ptr = arenaTickCb,
            .userdata = &s.arena,
            .has_pending = arenaHasPendingCb,
        };
        tl.addTicker(t);
        s.ticker = t;
    }
    node.state = s;
    return node;
}

// --- tests ---

const Rec = struct { fired: u32 = 0, last_dx: f32 = 0, last_dy: f32 = 0 };

fn recCb(userdata: ?*anyopaque) void {
    const r: *Rec = @ptrCast(@alignCast(userdata.?));
    r.fired += 1;
}

fn recPanCb(userdata: ?*anyopaque, dx: f32, dy: f32) void {
    const r: *Rec = @ptrCast(@alignCast(userdata.?));
    r.fired += 1;
    r.last_dx = dx;
    r.last_dy = dy;
}

test "detector fires on_tap through the router" {
    var rec = Rec{};
    const root = try gestureDetector(std.testing.allocator, .{
        .callbacks = .{ .on_tap = .{ .fn_ptr = recCb, .userdata = &rec } },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = input.InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 50, .time_ms = 1000 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 50, .y = 50, .time_ms = 1050 });
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    // a drag is not a tap
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 50, .time_ms = 2000 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 90, .y = 50, .time_ms = 2050 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 90, .y = 50, .time_ms = 2100 });
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
}

test "detector fires pan callbacks with deltas" {
    var start = Rec{};
    var upd = Rec{};
    const root = try gestureDetector(std.testing.allocator, .{
        .callbacks = .{
            .on_pan_start = .{ .fn_ptr = recPanCb, .userdata = &start },
            .on_pan_update = .{ .fn_ptr = recPanCb, .userdata = &upd },
        },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = input.InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10, .time_ms = 0 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 30, .y = 10, .time_ms = 10 }); // start (> slop)
    router.dispatchPointer(root, .{ .phase = .move, .x = 45, .y = 25, .time_ms = 20 }); // update
    try std.testing.expectEqual(@as(u32, 1), start.fired);
    try std.testing.expectApproxEqAbs(@as(f32, 20), start.last_dx, 0.001); // down → claim
    try std.testing.expectApproxEqAbs(@as(f32, 0), start.last_dy, 0.001);
    try std.testing.expectEqual(@as(u32, 1), upd.fired);
    try std.testing.expectApproxEqAbs(@as(f32, 15), upd.last_dx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15), upd.last_dy, 0.001);
}

test "detector registers its arena with the timeline (long-press via tick)" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    var rec = Rec{};
    const root = try gestureDetector(std.testing.allocator, .{
        .callbacks = .{ .on_long_press = .{ .fn_ptr = recCb, .userdata = &rec } },
    });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = input.InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 50, .time_ms = 0 });
    tl.tick(499);
    try std.testing.expectEqual(@as(u32, 0), rec.fired);
    tl.tick(500); // timeline-driven: fires without a pointer event
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
}

test "detector with no callbacks still claims events (and leaks nothing)" {
    const root = try gestureDetector(std.testing.allocator, .{});
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var router = input.InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 50, .time_ms = 0 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 50, .y = 50, .time_ms = 50 });
    try std.testing.expect(router.capturedNode(0) == null); // capture released
}

// --- golden: tap on the detector repaints a signal-bound child ---

const SigBoxState = struct { sig: *ui.state.Signal(u32) };

fn sigBoxMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = 40, .h = 40 });
}
fn sigBoxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn sigBoxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *SigBoxState = @ptrCast(@alignCast(n.state.?));
    ui.paint.fillRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.sig.get());
}
fn sigBoxDeinit(n: *Node) void {
    const s: *SigBoxState = @ptrCast(@alignCast(n.state.?));
    s.sig.unsubscribe(.{ .node = n });
    n.allocator.destroy(s);
}
const sig_box_vtable = ui.node.VTable{ .measure = sigBoxMeasure, .layout = sigBoxLayout, .paint = sigBoxPaint, .deinit = sigBoxDeinit };

fn sigBox(allocator: std.mem.Allocator, sig: *ui.state.Signal(u32)) !*Node {
    const node = try Node.create(allocator, &sig_box_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(SigBoxState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = sig };
    node.state = s;
    ui.state.bindNode(node, sig);
    return node;
}

fn toggleCb(userdata: ?*anyopaque) void {
    const sig: *ui.state.Signal(u32) = @ptrCast(@alignCast(userdata.?));
    const red: u32 = 0xFF0000FF;
    const green: u32 = 0x00FF00FF;
    sig.set(if (sig.get() == red) green else red);
}

test "golden: tap on a gesture detector repaints the child" {
    const bg = 0x101010FF;
    const red = 0xFF0000FF;
    const green = 0x00FF00FF;
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, red);
    defer sig.deinit();
    const root = try gestureDetector(std.testing.allocator, .{
        .callbacks = .{ .on_tap = .{ .fn_ptr = toggleCb, .userdata = sig } },
    });
    defer root.deinit();
    root.add(try sigBox(std.testing.allocator, sig));
    var r = try golden.Renderer.init(std.testing.allocator, 64, 64);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(@as(u64, 64 * 64), f1.countColor(red)); // child fills
    // tap at the center → on_tap → signal flips → child repaints green
    router.dispatchPointer(root, .{ .phase = .down, .x = 32, .y = 32, .time_ms = 1000 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 32, .y = 32, .time_ms = 1050 });
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u64, 64 * 64), f2.countColor(green));
    try std.testing.expectEqual(@as(u64, 0), f2.countColor(red));
}
