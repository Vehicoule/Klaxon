// ScrollView (Phase 1f) — scrolls a single child of any (taller) size.
//
// The child is measured with an unbounded height (it takes its natural size)
// and laid out at the content height; painting translates the child by
// -offset and clips to the viewport (pre/post_children_paint). Not
// virtualized (P0): the whole child is one node — use ListView/GridView for
// large collections.
//
// P0: fills the (bounded) viewport; vertical scroll only.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const scroll_mod = @import("../ui/scroll.zig");
const scroll_util = @import("scroll_util.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

pub const ScrollViewOptions = struct {
    wheel_speed: f32 = 48,
};

const ScrollViewState = struct {
    opts: ScrollViewOptions,
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    content_h: f32 = 0,
};

fn scrollViewMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ScrollViewState, n);
    // The child takes its natural height (unbounded vertically); the
    // ScrollView fills the viewport.
    if (n.children.items.len > 0) {
        const child_c: Constraints = .{ .max_w = c.max_w, .max_h = std.math.inf(f32) };
        const cs = n.children.items[0].measure(child_c);
        s.content_h = cs.h;
        s.scroll.content = cs.h;
    }
    return c.constrain(.{ .w = c.max_w, .h = c.max_h });
}

fn scrollViewLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(ScrollViewState, n);
    s.scroll.viewport = bounds.h;
    if (n.children.items.len > 0) {
        // Measure the child unbounded (natural height) — same pattern as
        // Stack's layout. Layout may run without a prior measure pass.
        const child_c: Constraints = .{ .max_w = bounds.w, .max_h = std.math.inf(f32) };
        const cs = n.children.items[0].measure(child_c);
        s.content_h = cs.h;
        s.scroll.content = cs.h;
        _ = s.scroll.setOffset(s.scroll.offset); // re-clamp after a resize
        n.children.items[0].layout(.{
            .x = bounds.x,
            .y = bounds.y,
            .w = bounds.w,
            .h = @max(cs.h, bounds.h),
        });
    }
}

fn scrollViewPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn scrollViewPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ScrollViewState, n);
    const b = n.bounds;
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    ui.paint.translate(ctx, 0, -s.scroll.offset);
}
fn scrollViewPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx);
}
fn scrollViewMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(ScrollViewState, n);
    return .{ .x = rect.x, .y = rect.y - s.scroll.offset, .w = rect.w, .h = rect.h };
}
fn scrollViewPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(ScrollViewState, n);
    return .{ .x = px, .y = py + s.scroll.offset };
}
fn scrollViewOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ScrollViewState, n);
    return s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
}
fn scrollViewOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(ScrollViewState, n);
    return s.input.onScroll(ev, &s.scroll, s.opts.wheel_speed, setScrollOffset, n);
}
fn scrollViewScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    return stateOf(ScrollViewState, n).scroll.info();
}
fn scrollViewScrollSetOffset(n: *Node, value: f32) void {
    _ = setScrollOffset(n, value);
}
fn scrollViewDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(ScrollViewState, n));
}
const scroll_view_vtable = ui.node.VTable{
    .measure = scrollViewMeasure,
    .layout = scrollViewLayout,
    .paint = scrollViewPaint,
    .deinit = scrollViewDeinit,
    .on_pointer = scrollViewOnPointer,
    .on_scroll = scrollViewOnScroll,
    .scroll_info = scrollViewScrollInfo,
    .scroll_set_offset = scrollViewScrollSetOffset,
    .pre_children_paint = scrollViewPreChildrenPaint,
    .post_children_paint = scrollViewPostChildrenPaint,
    .map_paint_rect = scrollViewMapPaintRect,
    .pre_children_hit = scrollViewPreChildrenHit,
};

pub fn scrollView(allocator: std.mem.Allocator, opts: ScrollViewOptions) !*Node {
    const node = try Node.create(allocator, &scroll_view_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(ScrollViewState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- scroll API (programmatic + Scrollbar) ---

pub fn scrollOffset(n: *Node) f32 {
    return stateOf(ScrollViewState, n).scroll.offset;
}

pub fn setScrollOffset(n: *Node, value: f32) bool {
    const s = stateOf(ScrollViewState, n);
    if (!s.scroll.setOffset(value)) return false;
    n.markDirty();
    return true;
}

pub fn scrollBy(n: *Node, dy: f32) void {
    _ = setScrollOffset(n, stateOf(ScrollViewState, n).scroll.offset + dy);
}

// --- tests ---

test "scrollView: measures the child unbounded, fills the viewport" {
    const sv = try scrollView(std.testing.allocator, .{});
    defer sv.deinit();
    sv.add(try golden.solidBox(std.testing.allocator, 100, 500, 0xFF0000FF));
    const size = sv.measure(.{ .max_w = 100, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 100), size.w);
    try std.testing.expectEqual(@as(f32, 200), size.h); // viewport, not content
    sv.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(f32, 500), sv.children.items[0].bounds.h); // content
    const info = sv.vtable.scroll_info.?(sv);
    try std.testing.expectEqual(@as(f32, 500), info.content);
    try std.testing.expectEqual(@as(f32, 300), info.max_offset);
}

test "scrollView: wheel and drag scroll, clamped" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const sv = try scrollView(std.testing.allocator, .{});
    defer sv.deinit();
    sv.add(try golden.solidBox(std.testing.allocator, 100, 500, 0xFF0000FF));
    sv.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    router.dispatchScroll(sv, .{ .x = 50, .y = 50, .delta_y = -2 }); // 2 clicks down
    try std.testing.expectEqual(@as(f32, 96), scrollOffset(sv));
    router.dispatchPointer(sv, .{ .phase = .down, .x = 50, .y = 100 });
    router.dispatchPointer(sv, .{ .phase = .move, .x = 50, .y = 60 }); // up 40
    try std.testing.expectEqual(@as(f32, 136), scrollOffset(sv));
    _ = setScrollOffset(sv, 10_000);
    try std.testing.expectEqual(@as(f32, 300), scrollOffset(sv)); // clamped
}

test "golden: scrollView clips the child and translates it on scroll" {
    const bg: Color = 0x000000FF;
    const red: Color = 0xFF0000FF;
    const blue: Color = 0x0000FFFF;
    const sv = try scrollView(std.testing.allocator, .{});
    defer sv.deinit();
    // Two stacked boxes: red 0..100, blue 100..200 (content 200, viewport 100).
    const col = try ui.node.Node.create(std.testing.allocator, &column_vtable);
    // No separate deinit: sv.deinit() tears down the whole tree (children first).
    col.add(try golden.solidBox(std.testing.allocator, 100, 100, red));
    col.add(try golden.solidBox(std.testing.allocator, 100, 100, blue));
    sv.add(col);
    var r = try golden.Renderer.init(std.testing.allocator, 100, 100);
    defer r.deinit();
    sv.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    r.paint(sv, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(@as(u64, 100 * 100), f1.countColor(red)); // top half
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(blue));
    _ = setScrollOffset(sv, 100); // scrolled: blue fills the viewport
    r.paint(sv, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u64, 0), f2.countColor(red));
    try std.testing.expectEqual(@as(u64, 100 * 100), f2.countColor(blue));
}

// A minimal vertical stack for the golden test (avoids pulling widgets/layout).
fn colMeasure(n: *Node, c: Constraints) Size {
    var h: f32 = 0;
    var w: f32 = 0;
    for (n.children.items) |child| {
        const cs = child.measure(c);
        h += cs.h;
        w = @max(w, cs.w);
    }
    return c.constrain(.{ .w = w, .h = h });
}
fn colLayout(n: *Node, bounds: Rect) void {
    var y = bounds.y;
    for (n.children.items) |child| {
        const cs = child.measure(.{ .max_w = bounds.w, .max_h = std.math.inf(f32) });
        child.layout(.{ .x = bounds.x, .y = y, .w = bounds.w, .h = cs.h });
        y += cs.h;
    }
}
fn colPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
const column_vtable = ui.node.VTable{ .measure = colMeasure, .layout = colLayout, .paint = colPaint };
