// M3E Tree (Phase 4d P2) — an expandable tree view.
//
// Spec: docs/specs/m3e-specs-4d-p2-tree.md
//
// Tokens:
//   - container: Surface, row height: 48dp, indent: 24dp/level
//   - chevron: 24dp OnSurfaceVariant (▼/▶)
//   - label: BodyMedium / OnSurface
//   - hover (tappable): OnSurface @ 0.08
//   - selected: SecondaryContainer fill
//
// v1 deviations: no keyboard nav, no lazy loading, no drag-drop, no icons.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const TreeNode = struct {
    label: []const u8,
    children: ?[]const TreeNode = null,
};

pub const TreeOptions = struct {
    theme: Theme = theme_mod.light,
    tappable: bool = false,
};

// --- Tokens ---
const row_h: f32 = 48;
const indent: f32 = 24;
const chevron_size: f32 = 24;
const label_pad: f32 = 8;

// --- State ---

const TreeState = struct {
    opts: TreeOptions,
    root: TreeNodeDef, // owned tree
    on_select: ?Callback = null,
    hovered: i32 = -1, // flat visible index
    selected: i32 = -1,
};

const TreeNodeDef = struct {
    label: [:0]u8, // owned
    children: std.array_list.Managed(TreeNodeDef),
    expanded: bool = true,
};

fn stateOf(n: *Node) *TreeState {
    return @ptrCast(@alignCast(n.state.?));
}

/// A visible tree node entry (flat list for measure/paint/input).
const VisibleNode = struct {
    node: *TreeNodeDef,
    depth: usize,
};

/// Count visible nodes (expanded subtrees only). Returns the flat list
/// of visible nodes with their depths.
fn collectVisible(s: *TreeState, allocator: std.mem.Allocator) !std.array_list.Managed(VisibleNode) {
    var list = std.array_list.Managed(VisibleNode).init(allocator);
    try collectNode(&s.root, 0, &list);
    return list;
}

fn collectNode(node: *TreeNodeDef, depth: usize, list: *std.array_list.Managed(VisibleNode)) !void {
    try list.append(.{ .node = node, .depth = depth });
    if (node.expanded) {
        for (node.children.items) |*child| {
            try collectNode(child, depth + 1, list);
        }
    }
}

// --- Measure ---

fn treeMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const bs = t.type_scale.body_medium;
    var max_w: f32 = 0;
    var count: usize = 0;
    // Walk visible nodes to compute max width + count.
    var stack = std.array_list.Managed(VisibleNode).init(n.allocator);
    defer stack.deinit();
    stack.append(.{ .node = &s.root, .depth = 0 }) catch {};
    while (stack.items.len > 0) {
        const item = stack.pop().?;
        const w = indent * @as(f32, @floatFromInt(item.depth)) + chevron_size + label_pad + ui.paint.measureText(item.node.label, bs.size, false).width + 16;
        max_w = @max(max_w, w);
        count += 1;
        if (item.node.expanded) {
            var i = item.node.children.items.len;
            while (i > 0) {
                i -= 1;
                stack.append(.{ .node = &item.node.children.items[i], .depth = item.depth + 1 }) catch {};
            }
        }
    }
    const h = @as(f32, @floatFromInt(count)) * row_h;
    return .{
        .w = @max(c.min_w, @min(c.max_w, max_w)),
        .h = @max(c.min_h, @min(c.max_h, h)),
    };
}

fn treeLayout(_: *Node, _: Rect) void {}

// --- Paint ---

fn treePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const bs = t.type_scale.body_medium;

    var list = collectVisible(s, n.allocator) catch return;
    defer list.deinit();

    var y = b.y;
    for (list.items, 0..) |item, vi| {
        const row_y = y;
        // Hover / selected background.
        if (s.opts.tappable and s.hovered == @as(i32, @intCast(vi))) {
            const layer = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.hover);
            ui.paint.fillRect(ctx, b.x, row_y, b.w, row_h, layer);
        }
        if (s.selected == @as(i32, @intCast(vi))) {
            ui.paint.fillRect(ctx, b.x, row_y, b.w, row_h, t.colors.secondary_container);
        }

        const node = item.node;
        const has_children = node.children.items.len > 0;
        const x0 = b.x + indent * @as(f32, @floatFromInt(item.depth));

        // Chevron.
        if (has_children) {
            const chev: [:0]const u8 = if (node.expanded) "\u{25BC}" else "\u{25B6}"; // ▼ / ▶
            const cm = ui.paint.measureText(chev, chevron_size, false);
            ui.paint.text(ctx, chev, x0, row_y + (row_h - cm.height) / 2 + cm.height * 0.8, chevron_size, false, t.colors.on_surface_variant);
        }

        // Label.
        const lx = x0 + chevron_size + label_pad;
        const lm = ui.paint.measureText(node.label, bs.size, false);
        const ly = row_y + (row_h - lm.height) / 2 + lm.height * 0.8;
        const label_color = if (s.selected == @as(i32, @intCast(vi))) t.colors.on_secondary_container else t.colors.on_surface;
        ui.paint.text(ctx, node.label, lx, ly, bs.size, false, label_color);

        y += row_h;
    }
}

// --- Input ---

fn treePointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (ev.phase != .up) {
        if (ev.phase == .move and s.opts.tappable) {
            const b = n.bounds;
            if (ev.y >= b.y and ev.y <= b.y + n.measure(.{ .max_w = b.w, .max_h = 1e9 }).h) {
                const dy = ev.y - b.y;
                const vi = if (dy >= 0) @as(i32, @intFromFloat(dy / row_h)) else -1;
                if (vi != s.hovered) {
                    s.hovered = vi;
                    n.markDirty();
                }
            }
        }
        return false;
    }
    const b = n.bounds;
    const dy2 = ev.y - b.y;
    const vi = if (dy2 >= 0) @as(usize, @intFromFloat(dy2 / row_h)) else 0;
    var list = collectVisible(s, n.allocator) catch return false;
    defer list.deinit();
    if (vi >= list.items.len) return false;
    const item = list.items[vi];
    const x0 = b.x + indent * @as(f32, @floatFromInt(item.depth));
    // Chevron tap = toggle.
    if (item.node.children.items.len > 0 and ev.x >= x0 and ev.x <= x0 + chevron_size) {
        item.node.expanded = !item.node.expanded;
        n.markDirty();
        n.markLayoutDirty();
        return true;
    }
    // Label tap = select + toggle.
    if (s.opts.tappable) {
        s.selected = @intCast(vi);
        if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
    }
    if (item.node.children.items.len > 0) {
        item.node.expanded = !item.node.expanded;
        n.markDirty();
        n.markLayoutDirty();
    }
    return true;
}

// --- Deinit ---

fn freeNode(allocator: std.mem.Allocator, node: *TreeNodeDef) void {
    allocator.free(node.label);
    for (node.children.items) |*child| freeNode(allocator, child);
    node.children.deinit();
}

fn treeDeinit(n: *Node) void {
    const s = stateOf(n);
    freeNode(n.allocator, &s.root);
    n.allocator.destroy(s);
}

// --- VTable ---

const tree_vtable = ui.node.VTable{
    .measure = treeMeasure,
    .layout = treeLayout,
    .paint = treePaint,
    .on_pointer = treePointer,
    .deinit = treeDeinit,
};

// --- Factory ---

fn buildNodeDef(allocator: std.mem.Allocator, src: *const TreeNode) !TreeNodeDef {
    const buf = try allocator.alloc(u8, src.label.len + 1);
    @memcpy(buf[0..src.label.len], src.label);
    buf[src.label.len] = 0;
    var def = TreeNodeDef{
        .label = buf[0..src.label.len :0],
        .children = std.array_list.Managed(TreeNodeDef).init(allocator),
    };
    if (src.children) |children| {
        for (children) |*child| {
            try def.children.append(try buildNodeDef(allocator, child));
        }
    }
    return def;
}

pub fn tree(
    allocator: std.mem.Allocator,
    root: *const TreeNode,
    on_select: ?Callback,
    opts: TreeOptions,
) !*Node {
    const node = try Node.create(allocator, &tree_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(TreeState);
    errdefer allocator.destroy(s);

    s.* = .{
        .opts = opts,
        .root = try buildNodeDef(allocator, root),
        .on_select = on_select,
    };
    node.state = @ptrCast(s);

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Tree",
        .focusable = false,
    });

    return node;
}

// --- Tests ---

test "tree: measure counts visible nodes" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{ .{ .label = "Child1" }, .{ .label = "Child2", .children = &.{ .{ .label = "Grandchild" } } } },
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    // All expanded by default: Root + Child1 + Child2 + Grandchild = 4 rows.
    try std.testing.expectApproxEqAbs(row_h * 4, sz.h, 0.001);
}

test "tree: tap chevron toggles expanded" {
    const a = std.testing.allocator;
    const root = TreeNode{
        .label = "Root",
        .children = &.{.{ .label = "Child" }},
    };
    const n = try tree(a, &root, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = row_h * 2 });
    const s = stateOf(n);
    try std.testing.expect(s.root.expanded);
    try std.testing.expect(s.root.children.items[0].expanded);
    // Tap the root's chevron.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 12, .y = 24, .raw_x = 12, .raw_y = 24 });
    try std.testing.expect(!s.root.expanded); // toggled
}

test "golden: the tree paints the root label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const root = TreeNode{ .label = "RootNode" };
    const n = try tree(a, &root, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 80);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 180, .h = row_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Root label ink (OnSurface) in the row.
    try std.testing.expect(f.countColorIn(.{ .x = 10, .y = 20, .w = 180, .h = 20 }, t.colors.on_surface) > 0);
}
