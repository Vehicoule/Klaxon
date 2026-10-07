// Layout widgets (Phase 1b P0) — Row, Column, Stack, Grid, Padding, Center,
// Align, ConstrainedBox. Thin vtables over the ui core algorithms (ui/layout).
//
// Container semantics (Klaxon P0 contract):
//   - Fill containers (Padding, ConstrainedBox, Container): the child's bounds
//     are the inner rect — the child fills it. Wrap a child in Align/Center
//     to shrink or position it.
//   - Positioning containers (Align, Center, Stack): the child keeps its
//     measured size and is positioned by the alignment.
//   - Flex (Row/Column) and Grid: children are sized by the measure pass and
//     placed by the layout algorithm. Nothing is clipped (P0).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Axis = ui.layout.Axis;
const EdgeInsets = ui.layout.EdgeInsets;
const MainAlign = ui.layout.MainAlign;
const CrossAlign = ui.layout.CrossAlign;
const Alignment = ui.layout.Alignment;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

fn noopPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}

// --- Flex (Row / Column) ---

pub const FlexOptions = struct {
    gap: f32 = 0,
    padding: f32 = 0,
    main_align: MainAlign = .start,
    cross_align: CrossAlign = .stretch,
};

const FlexState = struct {
    axis: Axis,
    opts: FlexOptions,
};

fn flexMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(FlexState, n);
    return ui.layout.flexMeasure(n, c, s.axis, s.opts.gap, s.opts.padding);
}
fn flexLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(FlexState, n);
    ui.layout.flexLayout(n, bounds, s.axis, s.opts.gap, s.opts.padding, s.opts.main_align, s.opts.cross_align);
}
fn flexDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(FlexState, n));
}
const flex_vtable = ui.node.VTable{ .measure = flexMeasure, .layout = flexLayout, .paint = noopPaint, .deinit = flexDeinit };

fn flex(allocator: std.mem.Allocator, axis: Axis, opts: FlexOptions) !*Node {
    const node = try Node.create(allocator, &flex_vtable);
    const s = try allocator.create(FlexState);
    s.* = .{ .axis = axis, .opts = opts };
    node.state = s;
    return node;
}

pub fn row(allocator: std.mem.Allocator, opts: FlexOptions) !*Node {
    return flex(allocator, .horizontal, opts);
}

pub fn column(allocator: std.mem.Allocator, opts: FlexOptions) !*Node {
    return flex(allocator, .vertical, opts);
}

// --- Stack ---

pub const StackFit = enum { loose, expand };

pub const StackOptions = struct {
    fit: StackFit = .loose,
    alignment: Alignment = .top_left,
};

const StackState = struct { opts: StackOptions };

fn stackMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(StackState, n);
    const child_c = if (s.opts.fit == .expand) c else c.loosen();
    var size = Size{};
    for (n.children.items) |child| {
        const cs = child.measure(child_c);
        size.w = @max(size.w, cs.w);
        size.h = @max(size.h, cs.h);
    }
    return c.constrain(size);
}
fn stackLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(StackState, n);
    const child_c: Constraints = if (s.opts.fit == .expand)
        .{ .min_w = bounds.w, .max_w = bounds.w, .min_h = bounds.h, .max_h = bounds.h }
    else
        .{ .max_w = bounds.w, .max_h = bounds.h };
    for (n.children.items) |child| {
        const cs = child.measure(child_c);
        child.layout(s.opts.alignment.position(bounds, cs));
    }
}
fn stackDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(StackState, n));
}
const stack_vtable = ui.node.VTable{ .measure = stackMeasure, .layout = stackLayout, .paint = noopPaint, .deinit = stackDeinit };

pub fn stack(allocator: std.mem.Allocator, opts: StackOptions) !*Node {
    const node = try Node.create(allocator, &stack_vtable);
    const s = try allocator.create(StackState);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- Grid (equal tracks; children fill their cell) ---

pub const GridOptions = struct {
    columns: usize = 2,
    gap: f32 = 0,
    padding: f32 = 0,
};

const GridState = struct { opts: GridOptions };

// Scratch child sizes: stack buffer for <= 32 children, heap above (keeps
// allocs_per_frame = 0 for typical trees).

fn gridMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(GridState, n);
    const cols: usize = @max(1, s.opts.columns);
    const count = n.children.items.len;
    if (count == 0) return c.constrain(.{});
    const rows: usize = (count + cols - 1) / cols;
    const pad2 = s.opts.padding * 2;
    const gaps_w = s.opts.gap * @as(f32, @floatFromInt(cols - 1));
    const track_w = if (std.math.isFinite(c.max_w))
        @max(0, (c.max_w - pad2 - gaps_w) / @as(f32, @floatFromInt(cols)))
    else
        0; // unbounded: resolved from the widest child below

    var stack_buf: [32]Size = undefined;
    const sizes: []Size = if (count <= stack_buf.len)
        stack_buf[0..count]
    else
        n.allocator.alloc(Size, count) catch @panic("klaxon: out of memory");
    defer if (count > stack_buf.len) n.allocator.free(sizes);

    var max_child_w: f32 = 0;
    for (n.children.items, 0..) |child, i| {
        const child_c: Constraints = if (std.math.isFinite(c.max_w))
            .{ .min_w = track_w, .max_w = track_w }
        else
            .{};
        sizes[i] = child.measure(child_c);
        max_child_w = @max(max_child_w, sizes[i].w);
    }
    const tw = if (std.math.isFinite(c.max_w)) track_w else max_child_w;

    var stack_rows: [32]f32 = undefined;
    const row_h: []f32 = if (rows <= stack_rows.len)
        stack_rows[0..rows]
    else
        n.allocator.alloc(f32, rows) catch @panic("klaxon: out of memory");
    defer if (rows > stack_rows.len) n.allocator.free(row_h);
    for (row_h) |*h| h.* = 0;
    for (sizes, 0..) |cs, i| row_h[i / cols] = @max(row_h[i / cols], cs.h);

    var total_h: f32 = pad2;
    for (row_h, 0..) |h, ri| {
        total_h += h;
        if (ri + 1 < rows) total_h += s.opts.gap;
    }
    const w = tw * @as(f32, @floatFromInt(cols)) + gaps_w + pad2;
    return c.constrain(.{ .w = w, .h = total_h });
}

fn gridLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(GridState, n);
    const cols: usize = @max(1, s.opts.columns);
    const count = n.children.items.len;
    if (count == 0) return;
    const rows: usize = (count + cols - 1) / cols;
    const pad2 = s.opts.padding * 2;
    const gaps_w = s.opts.gap * @as(f32, @floatFromInt(cols - 1));
    const track_w = @max(0, (bounds.w - pad2 - gaps_w) / @as(f32, @floatFromInt(cols)));

    var stack_buf: [32]Size = undefined;
    const sizes: []Size = if (count <= stack_buf.len)
        stack_buf[0..count]
    else
        n.allocator.alloc(Size, count) catch @panic("klaxon: out of memory");
    defer if (count > stack_buf.len) n.allocator.free(sizes);
    for (n.children.items, 0..) |child, i| {
        sizes[i] = child.measure(.{ .min_w = track_w, .max_w = track_w });
    }

    var stack_rows: [32]f32 = undefined;
    const row_h: []f32 = if (rows <= stack_rows.len)
        stack_rows[0..rows]
    else
        n.allocator.alloc(f32, rows) catch @panic("klaxon: out of memory");
    defer if (rows > stack_rows.len) n.allocator.free(row_h);
    for (row_h) |*h| h.* = 0;
    for (sizes, 0..) |cs, i| row_h[i / cols] = @max(row_h[i / cols], cs.h);

    // Children fill their cell (tight track width x row height).
    var y = s.opts.padding;
    var cur_row: usize = 0;
    for (n.children.items, 0..) |child, i| {
        const row_idx = i / cols;
        const col_idx = i % cols;
        if (row_idx != cur_row) {
            y += row_h[cur_row] + s.opts.gap;
            cur_row = row_idx;
        }
        const x = s.opts.padding + @as(f32, @floatFromInt(col_idx)) * (track_w + s.opts.gap);
        child.layout(.{ .x = bounds.x + x, .y = bounds.y + y, .w = track_w, .h = row_h[row_idx] });
    }
}
fn gridDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(GridState, n));
}
const grid_vtable = ui.node.VTable{ .measure = gridMeasure, .layout = gridLayout, .paint = noopPaint, .deinit = gridDeinit };

pub fn grid(allocator: std.mem.Allocator, opts: GridOptions) !*Node {
    const node = try Node.create(allocator, &grid_vtable);
    const s = try allocator.create(GridState);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- Padding (fill container) ---

const PaddingState = struct { insets: EdgeInsets };

fn paddingMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(PaddingState, n);
    const inner = c.deflateEdge(s.insets);
    var size = Size{};
    if (n.children.items.len > 0) {
        const cs = n.children.items[0].measure(inner);
        size = .{ .w = cs.w + s.insets.hSum(), .h = cs.h + s.insets.vSum() };
    }
    return c.constrain(size);
}
fn paddingLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(PaddingState, n);
    if (n.children.items.len == 0) return;
    // Fill semantics: the child's bounds are the inner rect.
    n.children.items[0].layout(.{
        .x = bounds.x + s.insets.left,
        .y = bounds.y + s.insets.top,
        .w = @max(0, bounds.w - s.insets.hSum()),
        .h = @max(0, bounds.h - s.insets.vSum()),
    });
}
fn paddingDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(PaddingState, n));
}
const padding_vtable = ui.node.VTable{ .measure = paddingMeasure, .layout = paddingLayout, .paint = noopPaint, .deinit = paddingDeinit };

pub fn padding(allocator: std.mem.Allocator, insets: EdgeInsets) !*Node {
    const node = try Node.create(allocator, &padding_vtable);
    const s = try allocator.create(PaddingState);
    s.* = .{ .insets = insets };
    node.state = s;
    return node;
}

// --- Align / Center (positioning container) ---

pub const AlignOptions = struct { alignment: Alignment = .center };

const AlignState = struct { opts: AlignOptions };

fn alignMeasure(n: *Node, c: Constraints) Size {
    var size = Size{};
    if (n.children.items.len > 0) {
        const cs = n.children.items[0].measure(c.loosen());
        size = .{
            .w = if (std.math.isFinite(c.max_w)) c.max_w else cs.w,
            .h = if (std.math.isFinite(c.max_h)) c.max_h else cs.h,
        };
    }
    return c.constrain(size);
}
fn alignLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(AlignState, n);
    if (n.children.items.len == 0) return;
    const child = n.children.items[0];
    const cs = child.measure(.{ .max_w = bounds.w, .max_h = bounds.h });
    child.layout(s.opts.alignment.position(bounds, cs));
}
fn alignDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(AlignState, n));
}
const align_vtable = ui.node.VTable{ .measure = alignMeasure, .layout = alignLayout, .paint = noopPaint, .deinit = alignDeinit };

/// Align (named alignTo — `align` is a Zig keyword).
pub fn alignTo(allocator: std.mem.Allocator, opts: AlignOptions) !*Node {
    const node = try Node.create(allocator, &align_vtable);
    const s = try allocator.create(AlignState);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

/// Center — Align with Alignment.center.
pub fn center(allocator: std.mem.Allocator) !*Node {
    return alignTo(allocator, .{ .alignment = .center });
}

// --- ConstrainedBox (fill container with additional constraints) ---

pub const ConstrainedBoxOptions = struct {
    min_w: f32 = 0,
    min_h: f32 = 0,
    max_w: f32 = std.math.inf(f32),
    max_h: f32 = std.math.inf(f32),
};

const ConstrainedBoxState = struct { opts: ConstrainedBoxOptions };

fn constrainedBoxMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ConstrainedBoxState, n);
    const add: Constraints = .{
        .min_w = s.opts.min_w,
        .max_w = s.opts.max_w,
        .min_h = s.opts.min_h,
        .max_h = s.opts.max_h,
    };
    const child_c = c.enforcedBy(add);
    var size = Size{};
    if (n.children.items.len > 0) size = n.children.items[0].measure(child_c);
    return c.constrain(size);
}
fn constrainedBoxLayout(n: *Node, bounds: Rect) void {
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(bounds); // fill semantics
}
fn constrainedBoxDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(ConstrainedBoxState, n));
}
const constrained_box_vtable = ui.node.VTable{ .measure = constrainedBoxMeasure, .layout = constrainedBoxLayout, .paint = noopPaint, .deinit = constrainedBoxDeinit };

pub fn constrainedBox(allocator: std.mem.Allocator, opts: ConstrainedBoxOptions) !*Node {
    const node = try Node.create(allocator, &constrained_box_vtable);
    const s = try allocator.create(ConstrainedBoxState);
    s.* = .{ .opts = opts };
    node.state = s;
    return node;
}

// --- tests ---

test "row measure sums child widths + gap, cross is the max" {
    const root = try row(std.testing.allocator, .{ .gap = 10 });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 30, 10, 0xFF000000));
    root.add(try golden.solidBox(std.testing.allocator, 20, 40, 0xFF000000));
    const size = root.measure(.{});
    try std.testing.expectEqual(@as(f32, 60), size.w); // 30 + 10 + 20
    try std.testing.expectEqual(@as(f32, 40), size.h);
}

test "row main_align center distributes free space" {
    const root = try row(std.testing.allocator, .{ .main_align = .center, .cross_align = .start });
    defer root.deinit();
    const a = try golden.solidBox(std.testing.allocator, 20, 10, 0xFF000000);
    const b = try golden.solidBox(std.testing.allocator, 20, 10, 0xFF000000);
    root.add(a);
    root.add(b);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 30), a.bounds.x); // natural 40, free 60 → start 30
    try std.testing.expectEqual(@as(f32, 50), b.bounds.x);
}

test "row space_between spreads children across the free space" {
    const root = try row(std.testing.allocator, .{ .main_align = .space_between, .cross_align = .start });
    defer root.deinit();
    const a = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    const b = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    const c = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    root.add(a);
    root.add(b);
    root.add(c);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 0), a.bounds.x);
    try std.testing.expectEqual(@as(f32, 45), b.bounds.x); // extra gap = (100-30)/2 = 35
    try std.testing.expectEqual(@as(f32, 90), c.bounds.x);
}

test "column cross_align center keeps the natural width, centered" {
    const root = try column(std.testing.allocator, .{ .cross_align = .center });
    defer root.deinit();
    const a = try golden.solidBox(std.testing.allocator, 20, 10, 0xFF000000);
    root.add(a);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 40), a.bounds.x); // (100-20)/2
    try std.testing.expectEqual(@as(f32, 20), a.bounds.w);
    try std.testing.expectEqual(@as(f32, 10), a.bounds.h);
}

test "stack sizes to the largest child and centers it" {
    const root = try stack(std.testing.allocator, .{ .alignment = .center });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 40, 30, 0xFF000000));
    const small = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    root.add(small);
    const size = root.measure(.{ .max_w = 100, .max_h = 100 });
    try std.testing.expectEqual(@as(f32, 40), size.w);
    try std.testing.expectEqual(@as(f32, 30), size.h);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 45), small.bounds.x); // (100-10)/2
    try std.testing.expectEqual(@as(f32, 45), small.bounds.y);
}

test "stack expand fit stretches children to the stack size" {
    const root = try stack(std.testing.allocator, .{ .fit = .expand, .alignment = .top_left });
    defer root.deinit();
    const a = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    root.add(a);
    root.layout(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    try std.testing.expectEqual(@as(f32, 64), a.bounds.w);
    try std.testing.expectEqual(@as(f32, 64), a.bounds.h);
}

test "grid lays out 2x2 cells with per-row heights (children fill cells)" {
    const root = try grid(std.testing.allocator, .{ .columns = 2, .gap = 4 });
    defer root.deinit();
    const a = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    const b = try golden.solidBox(std.testing.allocator, 10, 30, 0xFF000000);
    const c = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    const d = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    root.add(a);
    root.add(b);
    root.add(c);
    root.add(d);
    root.layout(.{ .x = 0, .y = 0, .w = 104, .h = 200 });
    // track_w = (104 - 4) / 2 = 50
    try std.testing.expectEqual(@as(f32, 0), a.bounds.x);
    try std.testing.expectEqual(@as(f32, 54), b.bounds.x); // 50 + gap 4
    try std.testing.expectEqual(@as(f32, 50), a.bounds.w);
    try std.testing.expectEqual(@as(f32, 30), a.bounds.h); // row 0 height = max(10, 30)
    try std.testing.expectEqual(@as(f32, 34), c.bounds.y); // 30 + gap 4
    try std.testing.expectEqual(@as(f32, 10), c.bounds.h); // row 1 height
    try std.testing.expectEqual(@as(f32, 50), d.bounds.w);
}

test "grid measure resolves track width from bounded constraints" {
    const root = try grid(std.testing.allocator, .{ .columns = 2, .gap = 4 });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000));
    root.add(try golden.solidBox(std.testing.allocator, 10, 20, 0xFF000000));
    const size = root.measure(.{ .max_w = 104, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 104), size.w); // 2 tracks + gap
    try std.testing.expectEqual(@as(f32, 20), size.h); // one row, tallest child
}

test "padding measures child + insets; layout gives the inner rect (fill)" {
    const root = try padding(std.testing.allocator, EdgeInsets.all(8));
    defer root.deinit();
    const child = try golden.solidBox(std.testing.allocator, 32, 32, 0xFF000000);
    root.add(child);
    const size = root.measure(.{ .max_w = 128, .max_h = 128 });
    try std.testing.expectEqual(@as(f32, 48), size.w);
    try std.testing.expectEqual(@as(f32, 48), size.h);
    root.layout(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    try std.testing.expectEqual(@as(f32, 8), child.bounds.x);
    try std.testing.expectEqual(@as(f32, 8), child.bounds.y);
    try std.testing.expectEqual(@as(f32, 48), child.bounds.w); // fills the inner rect
    try std.testing.expectEqual(@as(f32, 48), child.bounds.h);
}

test "align expands to bounded constraints and centers the child" {
    const root = try center(std.testing.allocator);
    defer root.deinit();
    const child = try golden.solidBox(std.testing.allocator, 20, 10, 0xFF000000);
    root.add(child);
    const size = root.measure(.{ .max_w = 100, .max_h = 50 });
    try std.testing.expectEqual(@as(f32, 100), size.w); // bounded → expand
    try std.testing.expectEqual(@as(f32, 50), size.h);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    try std.testing.expectEqual(@as(f32, 40), child.bounds.x);
    try std.testing.expectEqual(@as(f32, 20), child.bounds.y);
}

test "align sizes to the child when unbounded" {
    const root = try center(std.testing.allocator);
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 20, 10, 0xFF000000));
    const size = root.measure(.{});
    try std.testing.expectEqual(@as(f32, 20), size.w);
    try std.testing.expectEqual(@as(f32, 10), size.h);
}

test "constrained box enforces min/max on the child" {
    const root = try constrainedBox(std.testing.allocator, .{ .min_w = 50, .max_w = 80, .min_h = 20, .max_h = 40 });
    defer root.deinit();
    const child = try golden.solidBox(std.testing.allocator, 10, 10, 0xFF000000);
    root.add(child);
    const size = root.measure(.{ .max_w = 200, .max_h = 200 });
    try std.testing.expectEqual(@as(f32, 50), size.w); // child clamped up to min_w
    try std.testing.expectEqual(@as(f32, 20), size.h);
    root.layout(.{ .x = 0, .y = 0, .w = 50, .h = 20 });
    try std.testing.expectEqual(@as(f32, 50), child.bounds.w); // child fills the box
    try std.testing.expectEqual(@as(f32, 20), child.bounds.h);
}

test "golden: row paints children at exact positions" {
    const bg = 0x101010FF;
    const red = 0xFF0000FF;
    const blue = 0x0000FFFF;
    const root = try row(std.testing.allocator, .{ .gap = 8, .cross_align = .start });
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 40, 20, red));
    root.add(try golden.solidBox(std.testing.allocator, 40, 20, blue));
    var frame = try golden.render(std.testing.allocator, root, 128, 64, bg);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u64, 40 * 20), frame.countColor(red));
    try std.testing.expectEqual(@as(u64, 40 * 20), frame.countColor(blue));
    try std.testing.expectEqual(red, frame.pixelAt(5, 5));
    try std.testing.expectEqual(blue, frame.pixelAt(53, 5)); // 40 + gap 8 + 5
    try std.testing.expectEqual(bg, frame.pixelAt(44, 5)); // inside the gap
}

test "golden: padding insets the child (fill semantics)" {
    const bg = 0x101010FF;
    const green = 0x00FF00FF;
    const root = try padding(std.testing.allocator, EdgeInsets.all(8));
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 32, 32, green));
    var frame = try golden.render(std.testing.allocator, root, 64, 64, bg);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u64, 48 * 48), frame.countColor(green)); // fills the inner rect
    try std.testing.expectEqual(bg, frame.pixelAt(7, 7));
    try std.testing.expectEqual(green, frame.pixelAt(8, 8));
}

test "golden: center places the child at the exact center" {
    const bg = 0x101010FF;
    const green = 0x00FF00FF;
    const root = try center(std.testing.allocator);
    defer root.deinit();
    root.add(try golden.solidBox(std.testing.allocator, 20, 20, green));
    var frame = try golden.render(std.testing.allocator, root, 64, 64, bg);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u64, 400), frame.countColor(green));
    try std.testing.expectEqual(green, frame.pixelAt(32, 32));
    try std.testing.expectEqual(bg, frame.pixelAt(21, 21)); // just outside the child
    try std.testing.expectEqual(@as(u64, 400), frame.countColorIn(.{ .x = 22, .y = 22, .w = 20, .h = 20 }, green));
}
