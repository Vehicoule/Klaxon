// Demo widgets for the Phase 0 hello — thin vtables over the ui core algorithms.
// Replaced by the widget library (widgets/) and the gallery in Phase 1.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;

// --- Box (leaf): fixed size, filled rounded rect ---
pub const BoxState = struct {
    w: f32,
    h: f32,
    color: ui.paint.Color,
    radius: f32,
};

fn boxMeasure(n: *Node, c: Constraints) Size {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn boxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
fn boxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    kx.c.kx_fill_rrect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.radius, s.color);
}
fn boxDeinit(n: *Node) void {
    n.allocator.destroy(@as(*BoxState, @ptrCast(@alignCast(n.state.?))));
}
const box_vtable = ui.node.VTable{ .measure = boxMeasure, .layout = boxLayout, .paint = boxPaint, .deinit = boxDeinit };

pub fn box(allocator: std.mem.Allocator, w: f32, h: f32, color: ui.paint.Color, radius: f32) !*Node {
    const node = try Node.create(allocator, &box_vtable);
    const s = try allocator.create(BoxState);
    s.* = .{ .w = w, .h = h, .color = color, .radius = radius };
    node.state = s;
    return node;
}

// --- Label (leaf): single-line text ---
pub const LabelState = struct {
    text: [:0]const u8, // owned, null-terminated
    size: f32,
    color: ui.paint.Color,
};

fn labelMeasure(n: *Node, c: Constraints) Size {
    const s: *LabelState = @ptrCast(@alignCast(n.state.?));
    const m = ui.paint.measureText(s.text, s.size, false);
    return c.constrain(.{ .w = m.width, .h = m.height });
}
fn labelLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn labelPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *LabelState = @ptrCast(@alignCast(n.state.?));
    // Skia draws from the baseline: place it one ascent below the top.
    const m = ui.paint.measureText(s.text, s.size, false);
    kx.c.kx_draw_text(ctx, s.text, n.bounds.x, n.bounds.y + m.ascent, s.size, false, s.color);
}
fn labelDeinit(n: *Node) void {
    const s: *LabelState = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.text);
    n.allocator.destroy(s);
}
const label_vtable = ui.node.VTable{ .measure = labelMeasure, .layout = labelLayout, .paint = labelPaint, .deinit = labelDeinit };

pub fn label(allocator: std.mem.Allocator, text: []const u8, size: f32, color: ui.paint.Color) !*Node {
    const node = try Node.create(allocator, &label_vtable);
    const s = try allocator.create(LabelState);
    const buf = try allocator.alloc(u8, text.len + 1);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    s.* = .{ .text = buf[0..text.len :0], .size = size, .color = color };
    node.state = s;
    return node;
}

// --- Column (layout): vertical flex container with optional background ---
pub const ColumnState = struct {
    gap: f32,
    padding: f32,
    bg: ?*ui.state.Signal(u32) = null, // reactive background (Phase 1a)
};

fn columnMeasure(n: *Node, c: Constraints) Size {
    const s: *ColumnState = @ptrCast(@alignCast(n.state.?));
    return ui.layout.flexMeasure(n, c, .vertical, s.gap, s.padding);
}
fn columnLayout(n: *Node, bounds: Rect) void {
    const s: *ColumnState = @ptrCast(@alignCast(n.state.?));
    ui.layout.flexLayout(n, bounds, .vertical, s.gap, s.padding, .start, .stretch);
}
fn columnPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *ColumnState = @ptrCast(@alignCast(n.state.?));
    if (s.bg) |bg| {
        kx.c.kx_fill_rect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, bg.get());
    }
}
fn columnDeinit(n: *Node) void {
    n.allocator.destroy(@as(*ColumnState, @ptrCast(@alignCast(n.state.?))));
}
const column_vtable = ui.node.VTable{ .measure = columnMeasure, .layout = columnLayout, .paint = columnPaint, .deinit = columnDeinit };

pub fn column(allocator: std.mem.Allocator, gap: f32, padding: f32, bg: ?*ui.state.Signal(u32)) !*Node {
    const node = try Node.create(allocator, &column_vtable);
    const s = try allocator.create(ColumnState);
    s.* = .{ .gap = gap, .padding = padding, .bg = bg };
    node.state = s;
    return node;
}

// --- Demo tree ---

pub const Demo = struct {
    root: *Node,
    bg: *ui.state.Signal(u32), // owned; the root is bound to it

    pub fn deinit(demo: *Demo) void {
        demo.root.deinit();
        demo.bg.deinit();
    }
};

/// The Phase 0/1a showcase tree: Column[ Box, Label, Label, Box ] with a
/// reactive background (set() → subscribers fire → root.markDirty → re-render).
pub fn buildTree(allocator: std.mem.Allocator) !Demo {
    const bg = try ui.state.Signal(u32).init(allocator, 0x181828FF);
    const root = try column(allocator, 16, 24, bg);
    root.add(try box(allocator, 592, 96, 0x3B5BDBFF, 12));
    root.add(try label(allocator, "Hello from Klaxon", 28, 0xFFFFFFFF));
    root.add(try label(allocator, "rendered by the Skia widget tree", 16, 0xFFAAAAAA));
    root.add(try box(allocator, 592, 48, 0x282838FF, 8));
    ui.state.bindNode(root, bg);
    return .{ .root = root, .bg = bg };
}

test "flex measure: column sums child heights + gap" {
    const root = try column(std.testing.allocator, 10, 0, null);
    defer root.deinit();
    root.add(try box(std.testing.allocator, 100, 50, 0xFF000000, 0));
    root.add(try box(std.testing.allocator, 100, 30, 0xFF000000, 0));
    const size = root.measure(.{});
    try std.testing.expectEqual(@as(f32, 90), size.h); // 50 + 10 + 30
    try std.testing.expectEqual(@as(f32, 100), size.w);
}

test "node bind: signal set marks the node dirty" {
    const sig = try ui.state.Signal(u32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const b = try box(std.testing.allocator, 10, 10, 0xFF000000, 0);
    defer b.deinit();
    ui.state.bindNode(b, sig);
    b.dirty = false;
    sig.set(1);
    try std.testing.expect(b.dirty);
}

test "flex layout: children stack with gap, stretched cross-axis" {
    const root = try column(std.testing.allocator, 10, 0, null);
    defer root.deinit();
    const a = try box(std.testing.allocator, 100, 50, 0xFF000000, 0);
    const b = try box(std.testing.allocator, 100, 30, 0xFF000000, 0);
    root.add(a);
    root.add(b);
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 300 });
    try std.testing.expectEqual(@as(f32, 0), a.bounds.y);
    try std.testing.expectEqual(@as(f32, 50), a.bounds.h);
    try std.testing.expectEqual(@as(f32, 60), b.bounds.y); // 50 + gap 10
    try std.testing.expectEqual(@as(f32, 30), b.bounds.h);
    try std.testing.expectEqual(@as(f32, 200), a.bounds.w); // stretched cross
}
