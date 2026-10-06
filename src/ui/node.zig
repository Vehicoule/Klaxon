// Node — retained widget tree with dirty flags (ADR-0004).
// Zig has no GC: the tree is retained and mutated in place. Dirty flags drive
// the frame loop — a clean tree renders 0 frames (0 wakeups at idle).
const std = @import("std");
const kx = @import("../kx.zig");
const paint_mod = @import("paint.zig");
const layout_mod = @import("layout.zig");

pub const Paint = paint_mod.Paint;
pub const Constraints = layout_mod.Constraints;
pub const Size = layout_mod.Size;
pub const Axis = layout_mod.Axis;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }

    pub fn main(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.w,
            .vertical => r.h,
        };
    }

    pub fn cross(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.h,
            .vertical => r.w,
        };
    }
};

pub const VTable = struct {
    measure: *const fn (node: *Node, c: Constraints) Size,
    layout: *const fn (node: *Node, bounds: Rect) void,
    paint: *const fn (node: *Node, ctx: *kx.Ctx) void,
    deinit: ?*const fn (node: *Node) void = null,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    parent: ?*Node = null,
    children: std.array_list.Managed(*Node),
    bounds: Rect = .{},
    dirty: bool = true,
    layout_dirty: bool = true,
    vtable: *const VTable,
    state: ?*anyopaque = null,

    pub fn create(allocator: std.mem.Allocator, vtable: *const VTable) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .allocator = allocator,
            .children = std.array_list.Managed(*Node).init(allocator),
            .vtable = vtable,
        };
        return node;
    }

    /// Append a child. OOM while building the tree is fatal (same as Flutter).
    pub fn add(node: *Node, child: *Node) void {
        child.parent = node;
        node.children.append(child) catch @panic("klaxon: out of memory");
        node.markLayoutDirty();
        node.markDirty();
    }

    pub fn markDirty(node: *Node) void {
        node.dirty = true;
        if (node.parent) |p| p.markDirty();
    }

    pub fn markLayoutDirty(node: *Node) void {
        node.layout_dirty = true;
        if (node.parent) |p| p.markLayoutDirty();
    }

    pub fn measure(node: *Node, c: Constraints) Size {
        return node.vtable.measure(node, c);
    }

    pub fn layout(node: *Node, bounds: Rect) void {
        node.bounds = bounds;
        node.layout_dirty = false;
        node.vtable.layout(node, bounds);
    }

    /// Paint the subtree and clear dirty flags. Phase 0 paints the whole tree;
    /// dirty-rect (paint only dirty subtrees) lands with animations in Phase 1e.
    pub fn paint(node: *Node, ctx: *kx.Ctx) void {
        node.vtable.paint(node, ctx);
        for (node.children.items) |child| child.paint(ctx);
        node.dirty = false;
    }

    /// Deepest node containing the point (children are painted last, on top).
    pub fn hitTest(node: *Node, px: f32, py: f32) ?*Node {
        if (!node.bounds.contains(px, py)) return null;
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (node.children.items[i].hitTest(px, py)) |hit| return hit;
        }
        return node;
    }

    pub fn deinit(node: *Node) void {
        for (node.children.items) |child| child.deinit();
        node.children.deinit();
        if (node.vtable.deinit) |d| d(node);
        node.allocator.destroy(node);
    }
};

// --- tests (stub leaf widget) ---

const TestState = struct { w: f32, h: f32 };

fn testMeasure(n: *Node, c: Constraints) Size {
    const s: *TestState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn testLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn testPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn testDeinit(n: *Node) void {
    std.testing.allocator.destroy(@as(*TestState, @ptrCast(@alignCast(n.state.?))));
}
const test_vtable = VTable{ .measure = testMeasure, .layout = testLayout, .paint = testPaint, .deinit = testDeinit };

fn testNode(w: f32, h: f32) !*Node {
    const node = try Node.create(std.testing.allocator, &test_vtable);
    const s = try std.testing.allocator.create(TestState);
    s.* = .{ .w = w, .h = h };
    node.state = s;
    return node;
}

test "markDirty propagates up to the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(10, 10);
    root.add(child);
    root.dirty = false;
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(child.dirty);
}

test "hitTest returns the deepest node containing the point" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try std.testing.expectEqual(child, root.hitTest(20, 20).?);
    try std.testing.expectEqual(root, root.hitTest(80, 80).?);
    try std.testing.expect(root.hitTest(200, 200) == null);
}
