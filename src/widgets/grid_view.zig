// GridView (Phase 1f) — virtualized grid (fixed columns × fixed item height).
//
// Same virtualization mechanics as ListView (scroll_util.syncItemWindow over
// a row-aligned item window): the window is [first_row * columns,
// last_row * columns), so rows are never split. The factory index is
// row * columns + col.
//
// P0: fixed item height, fixed column count; fills the (bounded) viewport.
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

pub const GridViewOptions = struct {
    item_count: usize,
    factory: ItemFactory,
    cross_axis_count: usize = 2, // columns
    item_height: f32 = 48,
    gap: f32 = 0, // both axes (P0)
    margin_rows: usize = 1, // rows kept alive beyond the viewport (each side)
    wheel_speed: f32 = 48,
};

const GridState = struct {
    opts: GridViewOptions,
    scroll: scroll_mod.ScrollState = .{},
    input: scroll_util.ScrollInput = .{},
    first: usize = 0, // item index of children[0] (row-aligned)
};

fn strideOf(s: *const GridState) f32 {
    return s.opts.item_height + s.opts.gap;
}

fn rowsOf(s: *const GridState) usize {
    if (s.opts.item_count == 0) return 0;
    return (s.opts.item_count + s.opts.cross_axis_count - 1) / s.opts.cross_axis_count;
}

fn contentHeight(s: *const GridState) f32 {
    const rows = rowsOf(s);
    if (rows == 0) return 0;
    return @as(f32, @floatFromInt(rows)) * strideOf(s) - s.opts.gap;
}

fn columnWidth(s: *const GridState, viewport_w: f32) f32 {
    const cols: f32 = @floatFromInt(s.opts.cross_axis_count);
    return (viewport_w - (cols - 1) * s.opts.gap) / cols;
}

fn gridMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    return c.constrain(.{ .w = c.max_w, .h = c.max_h }); // fill the viewport
}

fn layoutItem(n: *Node, child: *Node, index: usize) void {
    const s = stateOf(GridState, n);
    const col: usize = index % s.opts.cross_axis_count;
    const row: usize = index / s.opts.cross_axis_count;
    const cw = columnWidth(s, n.bounds.w);
    child.layout(.{
        .x = n.bounds.x + @as(f32, @floatFromInt(col)) * (cw + s.opts.gap),
        .y = n.bounds.y + @as(f32, @floatFromInt(row)) * strideOf(s),
        .w = cw,
        .h = s.opts.item_height,
    });
}

fn gridLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(GridState, n);
    s.scroll.viewport = bounds.h;
    s.scroll.content = contentHeight(s);
    _ = s.scroll.setOffset(s.scroll.offset); // re-clamp after a resize
    if (s.scroll.viewport > 0 and s.opts.cross_axis_count > 0) {
        // Row-aligned window: convert the row range to an item range.
        const stride = strideOf(s);
        const row_range = scroll_mod.visibleRange(rowsOf(s), stride, s.scroll.viewport, s.scroll.offset, s.opts.margin_rows);
        const range = scroll_mod.Range{
            .first = row_range.first * s.opts.cross_axis_count,
            .last = @min(row_range.last * s.opts.cross_axis_count, s.opts.item_count),
        };
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    for (n.children.items, 0..) |child, i| layoutItem(n, child, s.first + i);
}

fn gridPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn gridPreChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(GridState, n);
    const b = n.bounds;
    ui.paint.clipRect(ctx, b.x, b.y, b.w, b.h);
    ui.paint.translate(ctx, 0, -s.scroll.offset);
}
fn gridPostChildrenPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    ui.paint.clipReset(ctx);
}
fn gridMapPaintRect(n: *Node, rect: Rect) Rect {
    const s = stateOf(GridState, n);
    return .{ .x = rect.x, .y = rect.y - s.scroll.offset, .w = rect.w, .h = rect.h };
}
fn gridPreChildrenHit(n: *Node, px: f32, py: f32) ui.node.HitPoint {
    const s = stateOf(GridState, n);
    return .{ .x = px, .y = py + s.scroll.offset };
}
fn gridOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(GridState, n);
    return s.input.onPointer(ev, &s.scroll, setScrollOffset, n);
}
fn gridOnScroll(n: *Node, ev: input.ScrollEvent) bool {
    const s = stateOf(GridState, n);
    return s.input.onScroll(ev, &s.scroll, s.opts.wheel_speed, setScrollOffset, n);
}
fn gridScrollInfo(n: *Node) scroll_mod.ScrollInfo {
    return stateOf(GridState, n).scroll.info();
}
fn gridScrollSetOffset(n: *Node, value: f32) void {
    _ = setScrollOffset(n, value);
}
fn gridDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(GridState, n));
}
const grid_vtable = ui.node.VTable{
    .measure = gridMeasure,
    .layout = gridLayout,
    .paint = gridPaint,
    .deinit = gridDeinit,
    .on_pointer = gridOnPointer,
    .on_scroll = gridOnScroll,
    .scroll_info = gridScrollInfo,
    .scroll_set_offset = gridScrollSetOffset,
    .pre_children_paint = gridPreChildrenPaint,
    .post_children_paint = gridPostChildrenPaint,
    .map_paint_rect = gridMapPaintRect,
    .pre_children_hit = gridPreChildrenHit,
};

pub fn gridView(allocator: std.mem.Allocator, opts: GridViewOptions) !*Node {
    var o = opts;
    if (o.cross_axis_count == 0) o.cross_axis_count = 1; // normalize (rowsOf divides)
    const node = try Node.create(allocator, &grid_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(GridState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = o };
    node.state = s;
    return node;
}

// --- scroll API (programmatic + Scrollbar) ---

pub fn scrollOffset(n: *Node) f32 {
    return stateOf(GridState, n).scroll.offset;
}

pub fn setScrollOffset(n: *Node, value: f32) bool {
    const s = stateOf(GridState, n);
    if (!s.scroll.setOffset(value)) return false;
    if (s.scroll.viewport > 0 and s.opts.cross_axis_count > 0) {
        const stride = strideOf(s);
        const row_range = scroll_mod.visibleRange(rowsOf(s), stride, s.scroll.viewport, s.scroll.offset, s.opts.margin_rows);
        const range = scroll_mod.Range{
            .first = row_range.first * s.opts.cross_axis_count,
            .last = @min(row_range.last * s.opts.cross_axis_count, s.opts.item_count),
        };
        scroll_util.syncItemWindow(n, &s.first, s.opts.factory, range, layoutItem);
    }
    n.markDirty();
    return true;
}

pub fn scrollBy(n: *Node, dy: f32) void {
    _ = setScrollOffset(n, stateOf(GridState, n).scroll.offset + dy);
}

// --- tests ---

const red: Color = 0xFF0000FF;
const green: Color = 0x00FF00FF;
const blue: Color = 0x0000FFFF;

fn testItem(userdata: ?*anyopaque, index: usize) *Node {
    _ = userdata;
    const colors = [_]Color{ red, green, blue };
    return golden.solidBox(std.testing.allocator, 48, 48, colors[index % 3]) catch @panic("klaxon: out of memory");
}

test "gridView: virtualizes by rows — 1000 items keep a few rows alive" {
    const grid = try gridView(std.testing.allocator, .{
        .item_count = 1000,
        .factory = .{ .fn_ptr = testItem, .userdata = null },
        .cross_axis_count = 4,
        .item_height = 48,
    });
    defer grid.deinit();
    grid.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    // 100px viewport / 48 stride → 3 rows intersect + 1 margin = 4 rows × 4
    try std.testing.expectEqual(@as(usize, 16), grid.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), stateOf(GridState, grid).first);
    // scroll 10 rows deep: the window follows (5 rows × 4 = 20 alive)
    _ = setScrollOffset(grid, 48 * 10);
    try std.testing.expectEqual(@as(usize, 36), stateOf(GridState, grid).first); // row 9 × 4
    try std.testing.expectEqual(@as(usize, 20), grid.children.items.len);
}

test "gridView: items lay out in columns within a row" {
    const grid = try gridView(std.testing.allocator, .{
        .item_count = 100,
        .factory = .{ .fn_ptr = testItem, .userdata = null },
        .cross_axis_count = 2,
        .item_height = 48,
    });
    defer grid.deinit();
    grid.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // 2 columns of 50 in a 100px viewport: item 0 at (0,0), item 1 at (50,0)
    try std.testing.expectEqual(@as(f32, 0), grid.children.items[0].bounds.x);
    try std.testing.expectEqual(@as(f32, 0), grid.children.items[0].bounds.y);
    try std.testing.expectEqual(@as(f32, 50), grid.children.items[1].bounds.x);
    try std.testing.expectEqual(@as(f32, 0), grid.children.items[1].bounds.y);
    // item 2 starts the second row
    try std.testing.expectEqual(@as(f32, 0), grid.children.items[2].bounds.x);
    try std.testing.expectEqual(@as(f32, 48), grid.children.items[2].bounds.y);
}

test "gridView: zero columns normalize to one (no division by zero)" {
    const grid = try gridView(std.testing.allocator, .{
        .item_count = 10,
        .factory = .{ .fn_ptr = testItem, .userdata = null },
        .cross_axis_count = 0,
        .item_height = 48,
    });
    defer grid.deinit();
    grid.layout(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try std.testing.expectEqual(@as(usize, 1), stateOf(GridState, grid).opts.cross_axis_count);
    try std.testing.expect(grid.children.items.len > 0);
    try std.testing.expectEqual(@as(f32, 48), grid.children.items[1].bounds.y); // 1 column
}

test "golden: gridView paints the visible cells, clipped" {
    const bg: Color = 0x000000FF;
    const grid = try gridView(std.testing.allocator, .{
        .item_count = 100,
        .factory = .{ .fn_ptr = testItem, .userdata = null },
        .cross_axis_count = 2,
        .item_height = 48,
    });
    defer grid.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 100);
    defer r.deinit();
    grid.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    r.paint(grid, bg);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // cells: (0,0)=red (50,0)=green / (0,48)=blue (50,48)=red — 2x2 visible,
    // plus the next row (green, blue) peeking 4px at the bottom
    try std.testing.expectEqual(red, f.pixelAt(10, 10));
    try std.testing.expectEqual(green, f.pixelAt(60, 10));
    try std.testing.expectEqual(blue, f.pixelAt(10, 60));
    try std.testing.expectEqual(red, f.pixelAt(60, 60));
    try std.testing.expectEqual(@as(u64, 2 * 50 * 48), f.countColor(red)); // items 0, 3
    try std.testing.expectEqual(@as(u64, 50 * 48 + 50 * 4), f.countColor(green)); // items 1, 4
    try std.testing.expectEqual(@as(u64, 50 * 48 + 50 * 4), f.countColor(blue)); // items 2, 5
}
