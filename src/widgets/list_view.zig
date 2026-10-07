// ListView (Phase 1f) — virtualized vertical list.
//
// Virtualization: only the items intersecting the viewport ± `margin` are
// alive as child nodes (10k items → ~10 nodes). The window diffs on scroll
// (scroll_util.syncItemWindow): items leaving are destroyed, items entering
// are created by the factory.
//
// Scroll input: wheel (on_scroll), drag (on_pointer .move while captured —
// items consume down/up for taps, moves bubble up), programmatic
// (scrollBy / setScrollOffset). Children paint translated by -offset and
// clipped to the viewport (pre/post_children_paint); hit-testing and damage
// map through the same transform (pre_children_hit / map_paint_rect).
//
// P0: fixed item height; fills the (bounded) constraints — a ListView needs
// a bounded viewport (like Flutter without shrinkWrap).
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

pub const ItemFactory = scroll_util.ItemFactory;

pub const ListViewOptions = struct {
    item_count: usize,
    factory: ItemFactory,
    item_height: f32 = 48,
    gap: f32 = 0,
    margin: usize = 2, // items kept alive beyond the viewport (each side)
    wheel_speed: f32 = 48, // px per wheel click
};

const ListState = struct {
    opts: ListViewOptions,
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    first: usize = 0, // item index of children[0]
};

fn strideOf(s: *const ListState) f32 {
    return s.opts.item_height + s.opts.gap;
}

fn contentHeight(s: *const ListState) f32 {
    if (s.opts.item_count == 0) return 0;
    return @as(f32, @floatFromInt(s.opts.item_count)) * strideOf(s) - s.opts.gap;
}

fn listMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h }); // fill the viewport
}

fn layoutItem(n: *Node, child: *Node, index: usize) void {
    const s = stateOf(ListState, n);
    child.layout(.{
        .x = n.bounds.x,
        .y = n.bounds.y + @as(f32, @floatFromInt(index)) * strideOf(s),
        .w = n.bounds.w,
        .h = s.opts.item_height,
    });
}

fn listLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(ListState, n);
    s.scroll.viewport = bounds.h;
    s.scroll.content = contentHeight(s);
    if (s.scroll.viewport > 0) {
        const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    // Re-lay out every child (bounds may have changed — resize).
    for (n.children.items, 0..) |child, i| layoutItem(n, child, s.first + i);
}

fn listPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx; // children paint via the transform hooks below
}

/// Clip to the viewport, then translate the content by -offset.
fn listPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ListState, n);
    const b = n.bounds;
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    ui.paint.translate(ctx, 0, -s.scroll.offset);
}
fn listPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx);
}
fn listMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(ListState, n);
    return .{ .x = rect.x, .y = rect.y - s.scroll.offset, .w = rect.w, .h = rect.h };
}
fn listPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(ListState, n);
    return .{ .x = px, .y = py + s.scroll.offset };
}

fn listOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ListState, n);
    return s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
}
fn listOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(ListState, n);
    return s.input.onScroll(ev, &s.scroll, s.opts.wheel_speed, setScrollOffset, n);
}
fn listScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    return stateOf(ListState, n).scroll.info();
}
fn listScrollSetOffset(n: *Node, value: f32) void {
    _ = setScrollOffset(n, value);
}
fn listDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(ListState, n));
}
const list_vtable = ui.node.VTable{
    .measure = listMeasure,
    .layout = listLayout,
    .paint = listPaint,
    .deinit = listDeinit,
    .on_pointer = listOnPointer,
    .on_scroll = listOnScroll,
    .scroll_info = listScrollInfo,
    .scroll_set_offset = listScrollSetOffset,
    .pre_children_paint = listPreChildrenPaint,
    .post_children_paint = listPostChildrenPaint,
    .map_paint_rect = listMapPaintRect,
    .pre_children_hit = listPreChildrenHit,
};

pub fn listView(allocator: std.mem.Allocator, opts: ListViewOptions) !*Node {
    const node = try Node.create(allocator, &list_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ListState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- scroll API (programmatic + Scrollbar) ---

pub fn scrollOffset(n: *Node) f32 {
    return stateOf(ListState, n).scroll.offset;
}

/// Set the scroll offset (clamped). Shifts the virtualization window.
/// Returns true if the offset changed.
pub fn setScrollOffset(n: *Node, value: f32) bool {
    const s = stateOf(ListState, n);
    if (!s.scroll.setOffset(value)) return false;
    if (s.scroll.viewport > 0) {
        const range = scroll_mod.visibleRange(s.opts.item_count, strideOf(s), s.scroll.viewport, s.scroll.offset, s.opts.margin);
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    n.markDirty();
    return true;
}

pub fn scrollBy(n: *Node, dy: f32) void {
    _ = setScrollOffset(n, stateOf(ListState, n).scroll.offset + dy);
}

pub fn maxScrollOffset(n: *Node) f32 {
    return stateOf(ListState, n).scroll.maxOffset();
}

// --- tests ---

const red: Color = 0xFF0000FF;
const green: Color = 0x00FF00FF;
const blue: Color = 0x0000FFFF;

fn testItem(userdata: ?*anyopaque, index: usize) *Node {
    _ = userdata;
    const colors = [_]Color{ red, green, blue };
    // Deliberately no error path: OOM is fatal (Node.add convention).
    return golden.solidBox(std.testing.allocator, 100, 48, colors[index % 3]) catch @panic("klaxon: out of memory");
}

const test_factory = ItemFactory{ .fn_ptr = testItem, .userdata = null };

fn testList(count: usize) !*Node {
    return listView(std.testing.allocator, .{
        .item_count = count,
        .factory = test_factory,
        .item_height = 48,
    });
}

test "listView: virtualizes — 10k items keep ~7 children alive" {
    const list = try testList(10_000);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // viewport 200 / stride 48 → 5 intersecting + 2 margin = 7 items
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), stateOf(ListState, list).first);
    // scroll deep: the window follows (5 intersecting + 2 margin each side = 9)
    _ = setScrollOffset(list, 48 * 5000);
    try std.testing.expectEqual(@as(usize, 4998), stateOf(ListState, list).first); // floor(5000) - 2
    try std.testing.expectEqual(@as(usize, 9), list.children.items.len);
    // clamp at the end: first = 10000 - 7
    _ = setScrollOffset(list, 48 * 100_000);
    try std.testing.expectEqual(@as(usize, 10_000 - 7), stateOf(ListState, list).first);
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
}

test "listView: children lay out at content positions (translated at paint)" {
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(f32, 0), list.children.items[0].bounds.y);
    try std.testing.expectEqual(@as(f32, 48), list.children.items[1].bounds.y);
    try std.testing.expectEqual(@as(f32, 96), list.children.items[2].bounds.y);
    try std.testing.expectEqual(@as(f32, 48), list.children.items[0].bounds.h);
}

test "listView: scroll API clamps and reports" {
    const list = try testList(10); // content 480
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 }); // max offset 280
    try std.testing.expectEqual(@as(f32, 280), maxScrollOffset(list));
    scrollBy(list, 100);
    try std.testing.expectEqual(@as(f32, 100), scrollOffset(list));
    scrollBy(list, 10_000);
    try std.testing.expectEqual(@as(f32, 280), scrollOffset(list));
    _ = setScrollOffset(list, -50);
    try std.testing.expectEqual(@as(f32, 0), scrollOffset(list));
    // scroll_info for the Scrollbar
    const info = list.vtable.scroll_info.?(list);
    try std.testing.expect(info.canScroll());
    try std.testing.expectEqual(@as(f32, 480), info.content);
    try std.testing.expectEqual(@as(f32, 200), info.viewport);
}

test "listView: wheel scrolls, drag scrolls, hover does not" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // wheel down (delta_y = -1 → offset += 48)
    router.dispatchScroll(list, .{ .x = 50, .y = 50, .delta_y = -1 });
    try std.testing.expectEqual(@as(f32, 48), scrollOffset(list));
    // drag: down at y=100, move DOWN to y=130 → content follows → offset -= 30
    router.dispatchPointer(list, .{ .phase = .down, .x = 50, .y = 100 });
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 130 });
    try std.testing.expectEqual(@as(f32, 18), scrollOffset(list));
    router.dispatchPointer(list, .{ .phase = .up, .x = 50, .y = 130 });
    // hover move (no capture) → no scroll
    router.dispatchPointer(list, .{ .phase = .move, .x = 50, .y = 10 });
    try std.testing.expectEqual(@as(f32, 18), scrollOffset(list));
}

test "golden: listView paints only the visible window, clipped" {
    const bg: Color = 0x000000FF;
    const list = try testList(10); // 10 items of 48 = 480 content, viewport 100
    defer list.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 100);
    defer r.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    r.paint(list, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // items 0 (red) and 1 (green) fill the viewport; item 2+ clipped out
    try std.testing.expectEqual(red, f1.pixelAt(50, 10));
    try std.testing.expectEqual(green, f1.pixelAt(50, 60));
    try std.testing.expectEqual(@as(u64, 48 * 100), f1.countColor(red));
    try std.testing.expectEqual(@as(u64, 48 * 100), f1.countColor(green));
    try std.testing.expectEqual(@as(u64, 4 * 100), f1.countColor(blue)); // margin item 2 peeks 4px
    // scrolled by one item: green at top, blue below, item 3 (red) peeks 4px
    _ = setScrollOffset(list, 48);
    r.paint(list, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(green, f2.pixelAt(50, 10));
    try std.testing.expectEqual(blue, f2.pixelAt(50, 60));
    try std.testing.expectEqual(@as(u64, 4 * 100), f2.countColor(red)); // item 3, 4px
    try std.testing.expectEqual(@as(u64, 0), f2.countColorIn(.{ .x = 0, .y = 0, .w = 100, .h = 48 }, red)); // item 0 gone
}

test "listView: hit-testing lands on the item under the pointer" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const list = try testList(100);
    defer list.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    _ = setScrollOffset(list, 48 * 10); // offset 480 → window [8, 17)
    try std.testing.expectEqual(@as(usize, 8), stateOf(ListState, list).first);
    // pointer at viewport y=10 → content y = 10 + 480 = 490 → item 10 = children[2]
    const hit = list.hitTest(50, 10).?;
    try std.testing.expectEqual(list.children.items[2], hit);
    // scroll further: the hit follows the window
    _ = setScrollOffset(list, 48 * 20); // window [18, 27)
    try std.testing.expectEqual(@as(usize, 18), stateOf(ListState, list).first);
    const hit2 = list.hitTest(50, 10).?;
    try std.testing.expectEqual(list.children.items[2], hit2); // item 20
}

test "listView: 10k items render a frame fast (virtualized)" {
    const bg: Color = 0x000000FF;
    const list = try testList(10_000);
    defer list.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 200);
    defer r.deinit();
    list.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    var ts0: std.c.timespec = undefined;
    var ts1: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts0);
    r.paint(list, bg);
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts1);
    const elapsed_ns: i128 = (@as(i128, ts1.sec) - @as(i128, ts0.sec)) * 1_000_000_000 +
        (@as(i128, ts1.nsec) - @as(i128, ts0.nsec));
    const elapsed_ms: f32 = @as(f32, @floatFromInt(elapsed_ns)) / 1e6;
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // virtualized: ~7 children painted regardless of the 10k item count
    try std.testing.expectEqual(@as(usize, 7), list.children.items.len);
    try std.testing.expect(f.countNot(bg) > 0);
    // loose CI-safe bound: a virtualized frame is ~visible-items cost
    try std.testing.expect(elapsed_ms < 100);
}
