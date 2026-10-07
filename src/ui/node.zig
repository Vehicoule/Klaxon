// Node — retained widget tree with dirty flags (ADR-0004).
// Zig has no GC: the tree is retained and mutated in place. Dirty flags drive
// the frame loop — a clean tree renders 0 frames (0 wakeups at idle).
const std = @import("std");
const kx = @import("../kx.zig");
const paint_mod = @import("paint.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const scroll_mod = @import("scroll.zig");

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

/// Bounding box of two rects (the swept region of a monotonic translation).
pub fn rectUnion(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

pub const VTable = struct {
    measure: *const fn (node: *Node, c: Constraints) Size,
    layout: *const fn (node: *Node, bounds: Rect) void,
    paint: *const fn (node: *Node, ctx: *kx.Ctx) void,
    deinit: ?*const fn (node: *Node) void = null,
    /// Pointer input (Phase 1c, dispatched by ui/input.zig). Returns true if
    /// handled — bubbling to the parent stops.
    on_pointer: ?*const fn (node: *Node, ev: input_mod.PointerEvent) bool = null,
    /// Keyboard input (Phase 1c) — delivered to the focused node's chain.
    on_key: ?*const fn (node: *Node, ev: input_mod.KeyEvent) bool = null,
    /// Scroll (wheel) input (Phase 1f) — bubbles up until a scrollable
    /// reports it handled.
    on_scroll: ?*const fn (node: *Node, ev: input_mod.ScrollEvent) bool = null,
    /// Scrollable interface (Phase 1f): the Scrollbar drives any scrollable
    /// through these hooks — no direct widget-to-widget dependency.
    scroll_info: ?*const fn (node: *Node) scroll_mod.ScrollInfo = null,
    scroll_set_offset: ?*const fn (node: *Node, offset: f32) void = null,
    /// Paint-time wrapper around the children's paint (Phase 1e): called
    /// after this node's own paint, before the children's — e.g. save +
    /// translate for an animated offset. Must be balanced with
    /// post_children_paint (the canvas state is restored right after).
    pre_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    post_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    /// Map a rect from this node's child space into its parent space — the
    /// inverse of the paint transform (pre_children_paint). Dirty marks
    /// under a transformed ancestor land at the child's VISIBLE position.
    map_paint_rect: ?*const fn (node: *Node, rect: Rect) Rect = null,
    /// Effective hit-test rect (defaults to bounds). Transformed widgets
    /// return where their children actually paint.
    hit_bounds: ?*const fn (node: *Node) Rect = null,
    /// Map a point from this node's space into its children's coordinate
    /// space (matches the paint transform, inverted). Hit-testing through a
    /// transformed subtree lands on the visual position.
    pre_children_hit: ?*const fn (node: *Node, px: f32, py: f32) HitPoint = null,
};

/// A point in a transformed coordinate space (hit-testing, Phase 1e).
pub const HitPoint = struct { x: f32, y: f32 };

pub const Node = struct {
    allocator: std.mem.Allocator,
    parent: ?*Node = null,
    children: std.array_list.Managed(*Node),
    bounds: Rect = .{},
    dirty: bool = true,
    layout_dirty: bool = true,
    visible: bool = true, // invisible subtrees are neither painted nor hit-tested
    vtable: *const VTable,
    state: ?*anyopaque = null,
    // Dirty-rect (Phase 1e): the root accumulates the damaged region — the
    // union of every dirty mark's rect — and the host repaints the tree
    // clipped to it (the surface is retained between frames).
    damage: Rect = .{},
    damage_valid: bool = false,

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

    fn markDirtyUp(node: *Node) void {
        var n = node;
        while (true) {
            n.dirty = true;
            const p = n.parent orelse return;
            n = p;
        }
    }

    fn unionDamage(root: *Node, rect: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        root.damage = if (root.damage_valid) rectUnion(root.damage, rect) else rect;
        root.damage_valid = true;
    }

    /// Map a rect (given in the node's parent space) up to the root, applying
    /// every transformed ancestor's map_paint_rect, and union it into the
    /// root's damage accumulator.
    fn damageRectUp(node: *Node, rect: Rect) void {
        var r = rect;
        var n = node;
        while (n.parent) |p| {
            if (p.vtable.map_paint_rect) |m| r = m(p, r);
            n = p;
        }
        unionDamage(n, r);
    }

    /// Mark this node (and its ancestors) dirty. The node's own bounds —
    /// mapped to its visible position through any transformed ancestors —
    /// are unioned into the root's damage region.
    pub fn markDirty(node: *Node) void {
        markDirtyUp(node);
        damageRectUp(node, node.bounds);
    }

    /// Mark dirty + record an explicit damaged rect (given in the node's
    /// parent space) — e.g. an animated offset sweeping old → new position:
    /// the union of both regions.
    pub fn markDirtyRect(node: *Node, rect: Rect) void {
        markDirtyUp(node);
        damageRectUp(node, rect);
    }

    /// Clear the root's damage accumulator (called by the host after painting).
    pub fn clearDamage(node: *Node) void {
        node.damage = .{};
        node.damage_valid = false;
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

    /// Paint the subtree and clear dirty flags. The whole tree paints every
    /// frame; the host clips to the damage region (dirty-rect, Phase 1e) and
    /// the vtable's pre/post_children_paint hooks wrap the children's paint
    /// in a canvas transform (animated offsets/scales).
    pub fn paint(node: *Node, ctx: *kx.Ctx) void {
        if (!node.visible) return;
        node.vtable.paint(node, ctx);
        if (node.vtable.pre_children_paint) |pre| pre(node, ctx);
        for (node.children.items) |child| child.paint(ctx);
        if (node.vtable.post_children_paint) |post| post(node, ctx);
        node.dirty = false;
    }

    /// Deepest visible node containing the point (children are painted last,
    /// on top). Transformed subtrees (animated offset/scale) hit-test at
    /// their VISUAL position: hit_bounds + pre_children_hit mirror the paint
    /// transform.
    pub fn hitTest(node: *Node, px: f32, py: f32) ?*Node {
        if (!node.visible) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (node.children.items[i].hitTest(cx, cy)) |hit| return hit;
        }
        return node;
    }

    /// A hit-test result: the node + the point in the HIT NODE's parent
    /// space (transformed subtrees map viewport coordinates through their
    /// ancestors).
    pub const MappedHit = struct { node: *Node, x: f32, y: f32 };

    /// Hit-test that also returns the point in the hit node's parent space —
    /// the router delivers pointer events with those local coordinates so
    /// scrolled/transformed controls receive events at their visual position.
    pub fn hitTestMapped(node: *Node, px: f32, py: f32) ?MappedHit {
        if (!node.visible) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (node.children.items[i].hitTestMapped(cx, cy)) |hit| return hit;
        }
        return .{ .node = node, .x = px, .y = py };
    }

    /// Map a window-space point into `node`'s parent space: applies every
    /// strict ancestor's pre_children_hit, root-first. Used to deliver
    /// pointer events with local coordinates to captured nodes (Phase 1f).
    pub fn mapPointToParentSpace(node: *Node, px: f32, py: f32) HitPoint {
        var chain: [64]*Node = undefined;
        var depth: usize = 0;
        var n = node.parent;
        while (n) |p| : (n = p.parent) {
            if (depth < chain.len) {
                chain[depth] = p;
                depth += 1;
            }
        }
        var x = px;
        var y = py;
        while (depth > 0) {
            depth -= 1;
            const a = chain[depth];
            if (a.vtable.pre_children_hit) |pre| {
                const p = pre(a, x, y);
                x = p.x;
                y = p.y;
            }
        }
        return .{ .x = x, .y = y };
    }

    pub fn deinit(node: *Node) void {
        // Drop router references (capture/hover/focus/popup) BEFORE anything
        // is freed — virtualized lists destroy captured items on scroll.
        input_mod.releaseNode(node);
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

test "markDirty accumulates the damage region at the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(10, 10);
    root.add(child);
    child.layout(.{ .x = 20, .y = 30, .w = 10, .h = 10 });
    root.dirty = false;
    root.clearDamage();
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 20), root.damage.x);
    try std.testing.expectEqual(@as(f32, 30), root.damage.y);
    try std.testing.expectEqual(@as(f32, 10), root.damage.w);
    try std.testing.expectEqual(@as(f32, 10), root.damage.h);
    // a second mark unions into the region (0,0,30,40)
    child.markDirtyRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(f32, 0), root.damage.x);
    try std.testing.expectEqual(@as(f32, 0), root.damage.y);
    try std.testing.expectEqual(@as(f32, 30), root.damage.w);
    try std.testing.expectEqual(@as(f32, 40), root.damage.h);
    // empty rects (pre-layout) never corrupt the region
    root.clearDamage();
    child.markDirtyRect(.{});
    try std.testing.expect(!root.damage_valid);
}
