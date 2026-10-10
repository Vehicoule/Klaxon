// Inspector — widget tree + property view debug panel (Phase 4a.2).
// A debug panel painted on the right side of the window when enabled:
// a scrollable tree view of the widget tree (top) and a property view
// of the selected node (bottom, 180px). The selected node's bounds are
// highlighted with a cyan stroke on the canvas. Toggled with F11
// (host.zig) or the --inspector flag (main.zig) — independent of F12
// (the DevTools FPS overlay). When disabled the host skips paint entirely
// (zero interference with the normal render path and the golden tests).
const std = @import("std");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const node_mod = @import("ui/node.zig");
const semantics_mod = @import("ui/semantics.zig");
const golden = @import("golden.zig");

const Node = node_mod.Node;
const Rect = node_mod.Rect;
const Color = u32;

// Panel layout (pixels, origin top-left). Right-anchored, full height.
const PANEL_W: f32 = 300;
const HEADER_H: f32 = 24;
const ROW_H: f32 = 16;
const INDENT: f32 = 12;
const CHEVRON_W: f32 = 12;
const PROPS_H: f32 = 180;
const PAD: f32 = 8;
const PROP_KEY_W: f32 = 70; // fixed key column width in the property view

// 0xRRGGBBAA (matches kx_skia.h).
const PANEL_BG: u32 = 0x000000CC;
const PANEL_BORDER: u32 = 0xFFFFFF1A;
const TEXT: u32 = 0xFFFFFFFF;
const TEXT_DIM: u32 = 0xAAAAAAFF;
const ROW_SEL: u32 = 0x1C7ED680;
const DIVIDER: u32 = 0xFFFFFF33;
const HIGHLIGHT: u32 = 0x00E5FFCC; // cyan semi-transparent

/// One flattened tree row (a visible node + its depth).
pub const Row = struct { node: *Node, depth: u8 };

/// Which zone of the panel a point falls into.
pub const Zone = enum { none, tree, props };

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    selected: ?*Node = null,
    sel_index: usize = 0,
    /// Flattened tree rows — rebuilt on every paint (O(n), fine for debug).
    rows: std.array_list.Managed(Row),
    /// Expand overrides (default = expanded). Keyed by node pointer.
    expanded: std.AutoHashMap(*Node, bool),
    scroll_y: f32 = 0,
    /// The tree panel has keyboard focus (arrows navigate, Escape releases).
    tree_focus: bool = false,
    // Last paint dimensions (for scrollToVisible inside handleKey, which
    // has no window-size parameter).
    last_w: c_int = 0,
    last_h: c_int = 0,

    pub fn init(allocator: std.mem.Allocator) !Inspector {
        return .{
            .allocator = allocator,
            .rows = std.array_list.Managed(Row).init(allocator),
            .expanded = std.AutoHashMap(*Node, bool).init(allocator),
        };
    }

    pub fn deinit(insp: *Inspector) void {
        insp.rows.deinit();
        insp.expanded.deinit();
    }

    pub fn toggle(insp: *Inspector) void {
        insp.enabled = !insp.enabled;
    }

    /// Rebuild the flattened tree (DFS, visible nodes only, depth-tracked).
    /// If the selected node is no longer in the tree, the selection is
    /// dropped; otherwise sel_index is re-synced to the selected node's row
    /// (rows above it may have appeared or vanished since the last rebuild).
    /// Public: the host calls this BEFORE paintHighlight so a selected node
    /// destroyed since the last frame (e.g. a virtualized list scrolled) never
    /// reaches the highlight paint (use-after-free).
    pub fn rebuildRows(insp: *Inspector, root: *Node) void {
        insp.rows.clearRetainingCapacity();
        rebuildRowsInner(insp, root, 0);
        // Drop the selection if the node vanished from the tree; otherwise
        // re-sync sel_index to its row (the walk order may have shifted).
        if (insp.selected) |sel| {
            var found = false;
            for (insp.rows.items, 0..) |row, i| {
                if (row.node == sel) {
                    found = true;
                    insp.sel_index = i;
                    break;
                }
            }
            if (!found) insp.selected = null;
        }
        // Clamp the selection index into range.
        if (insp.rows.items.len > 0) {
            insp.sel_index = @min(insp.sel_index, insp.rows.items.len - 1);
        } else {
            insp.sel_index = 0;
        }
    }

    fn rebuildRowsInner(insp: *Inspector, node: *Node, depth: u8) void {
        if (!node.visible) return;
        insp.rows.append(.{ .node = node, .depth = depth }) catch @panic("klaxon: out of memory");
        const is_expanded = insp.expanded.get(node) orelse true;
        if (is_expanded) {
            for (node.children.items) |child| {
                rebuildRowsInner(insp, child, depth + 1);
            }
        }
    }

    /// Select a node (syncs sel_index to its row). Null clears the selection.
    pub fn select(insp: *Inspector, node: ?*Node) void {
        insp.selected = node;
        if (node) |n| {
            for (insp.rows.items, 0..) |row, i| {
                if (row.node == n) {
                    insp.sel_index = i;
                    return;
                }
            }
        }
    }

    /// Which zone of the panel contains the point (window coords).
    pub fn hitZone(insp: *const Inspector, x: f32, y: f32, w: c_int, h: c_int) Zone {
        _ = insp;
        const px = @as(f32, @floatFromInt(w)) - PANEL_W;
        const ph = @as(f32, @floatFromInt(h));
        if (x < px or x >= px + PANEL_W or y < 0 or y >= ph) return .none;
        if (y >= ph - PROPS_H) return .props;
        return .tree; // header + tree rows (both consumed, header is a no-op)
    }

    /// The scrollable tree area (below the header, above the property view),
    /// in window coordinates.
    fn treeRect(w: c_int, h: c_int) Rect {
        const pw = @as(f32, @floatFromInt(w));
        const ph = @as(f32, @floatFromInt(h));
        return .{
            .x = pw - PANEL_W,
            .y = HEADER_H,
            .w = PANEL_W,
            .h = ph - HEADER_H - PROPS_H,
        };
    }

    /// Handle a click inside the panel (tree zone: select/expand; props: no-op).
    pub fn clickAt(insp: *Inspector, root: *Node, x: f32, y: f32, w: c_int, h: c_int) void {
        const zone = insp.hitZone(x, y, w, h);
        if (zone != .tree) return; // props zone: consumed, nothing in v1
        // hitZone's .tree also covers the header: a click there (or below the
        // tree area) must not hit a row — with scroll_y > 0 the header would
        // otherwise resolve to a valid row index.
        const tree = treeRect(w, h);
        if (y < tree.y or y >= tree.y + tree.h) return;
        insp.tree_focus = true;
        insp.rebuildRows(root); // rows must be fresh for the click hit-test
        const px = @as(f32, @floatFromInt(w)) - PANEL_W;
        const local_y = y - HEADER_H + insp.scroll_y;
        if (local_y < 0) return;
        const row_idx = @as(usize, @intFromFloat(local_y / ROW_H));
        if (row_idx >= insp.rows.items.len) return;
        const row = insp.rows.items[row_idx];
        // Chevron click → toggle expand (only if the node has children).
        const chevron_x = px + PAD + @as(f32, @floatFromInt(row.depth)) * INDENT;
        const label_x = chevron_x + CHEVRON_W;
        if (x >= chevron_x and x < label_x and row.node.children.items.len > 0) {
            const is_expanded = insp.expanded.get(row.node) orelse true;
            insp.expanded.put(row.node, !is_expanded) catch @panic("klaxon: out of memory");
            insp.rebuildRows(root);
        } else {
            insp.select(row.node);
        }
    }

    /// Pick the deepest node at a canvas point (passive selection, no modal).
    pub fn pickAt(insp: *Inspector, root: *Node, x: f32, y: f32) void {
        insp.rebuildRows(root); // ensure rows are fresh for select() to sync
        insp.select(root.hitTest(x, y));
        insp.tree_focus = false;
    }

    /// Scroll the tree view by `dy` wheel clicks (clamped to [0, maxScroll]).
    /// Positive dy scrolls the content down (scroll_y grows) — the same
    /// convention as the widget scrollables. SDL3 reports wheel.y < 0 for a
    /// wheel-down, so the host negates the event value at the call site.
    pub fn scrollBy(insp: *Inspector, dy: f32, w: c_int, h: c_int) void {
        _ = w;
        const ph = @as(f32, @floatFromInt(h));
        const tree_h = ph - HEADER_H - PROPS_H;
        const content_h = @as(f32, @floatFromInt(insp.rows.items.len)) * ROW_H;
        const max_scroll = @max(0, content_h - tree_h);
        insp.scroll_y = std.math.clamp(insp.scroll_y + dy * ROW_H, 0, max_scroll);
    }

    /// Keyboard navigation (tree_focus = true). Returns true if consumed.
    /// Key is the raw SDL keycode (SDLK_*).
    pub fn handleKey(insp: *Inspector, key: u32) bool {
        switch (key) {
            sdl.c.SDLK_ESCAPE => {
                insp.tree_focus = false;
                return true;
            },
            sdl.c.SDLK_UP => {
                if (insp.rows.items.len == 0) return false;
                if (insp.sel_index > 0) insp.sel_index -= 1;
                insp.selected = insp.rows.items[insp.sel_index].node;
                insp.scrollToVisible();
                return true;
            },
            sdl.c.SDLK_DOWN => {
                if (insp.rows.items.len == 0) return false;
                if (insp.sel_index < insp.rows.items.len - 1) insp.sel_index += 1;
                insp.selected = insp.rows.items[insp.sel_index].node;
                insp.scrollToVisible();
                return true;
            },
            sdl.c.SDLK_RIGHT => {
                if (insp.rows.items.len == 0) return false;
                const row = insp.rows.items[insp.sel_index];
                const is_expanded = insp.expanded.get(row.node) orelse true;
                if (!is_expanded) {
                    // Collapsed → expand.
                    insp.expanded.put(row.node, true) catch @panic("klaxon: out of memory");
                } else if (row.node.children.items.len > 0) {
                    // Expanded → select the first visible child (next row).
                    if (insp.sel_index + 1 < insp.rows.items.len) {
                        insp.sel_index += 1;
                        insp.selected = insp.rows.items[insp.sel_index].node;
                        insp.scrollToVisible();
                    }
                }
                return true;
            },
            sdl.c.SDLK_LEFT => {
                if (insp.rows.items.len == 0) return false;
                const row = insp.rows.items[insp.sel_index];
                const is_expanded = insp.expanded.get(row.node) orelse true;
                if (is_expanded and row.node.children.items.len > 0) {
                    // Expanded → collapse.
                    insp.expanded.put(row.node, false) catch @panic("klaxon: out of memory");
                } else {
                    // Collapsed (or leaf) → select the parent (previous row
                    // with a smaller depth).
                    var i = insp.sel_index;
                    while (i > 0) {
                        i -= 1;
                        if (insp.rows.items[i].depth < row.depth) {
                            insp.sel_index = i;
                            insp.selected = insp.rows.items[i].node;
                            insp.scrollToVisible();
                            break;
                        }
                    }
                }
                return true;
            },
            sdl.c.SDLK_RETURN, sdl.c.SDLK_SPACE => {
                if (insp.rows.items.len == 0) return false;
                const row = insp.rows.items[insp.sel_index];
                if (row.node.children.items.len > 0) {
                    const is_expanded = insp.expanded.get(row.node) orelse true;
                    insp.expanded.put(row.node, !is_expanded) catch @panic("klaxon: out of memory");
                }
                return true;
            },
            else => return false,
        }
    }

    /// Keep the selected row visible (scrolls the tree view if needed).
    fn scrollToVisible(insp: *Inspector) void {
        if (insp.last_h == 0) return;
        const ph = @as(f32, @floatFromInt(insp.last_h));
        const tree_h = ph - HEADER_H - PROPS_H;
        const row_top = @as(f32, @floatFromInt(insp.sel_index)) * ROW_H;
        const row_bottom = row_top + ROW_H;
        if (row_top < insp.scroll_y) {
            insp.scroll_y = row_top;
        } else if (row_bottom > insp.scroll_y + tree_h) {
            insp.scroll_y = row_bottom - tree_h;
        }
    }

    /// Paint the cyan bounds highlight around the selected node (on canvas).
    pub fn paintHighlight(insp: *const Inspector, ctx: *kx.Ctx) void {
        const n = insp.selected orelse return;
        const r = n.mapRectToRoot(n.bounds);
        kx.c.kx_stroke_rrect(ctx, r.x - 1, r.y - 1, r.w + 2, r.h + 2, 0, 2, HIGHLIGHT);
    }

    /// Paint the inspector panel (right side, full height). No-op when disabled.
    pub fn paint(insp: *Inspector, ctx: *kx.Ctx, root: *Node, w: c_int, h: c_int) void {
        if (!insp.enabled) return;
        insp.last_w = w;
        insp.last_h = h;
        insp.rebuildRows(root);

        const px = @as(f32, @floatFromInt(w)) - PANEL_W;
        const ph = @as(f32, @floatFromInt(h));

        // Panel background + border.
        kx.c.kx_fill_rrect(ctx, px, 0, PANEL_W, ph, 0, PANEL_BG);
        kx.c.kx_stroke_rrect(ctx, px, 0, PANEL_W, ph, 0, 1, PANEL_BORDER);

        // Header.
        kx.c.kx_draw_text(ctx, "Inspector (F11)", px + PAD, 16, 11, TEXT);
        kx.c.kx_fill_rect(ctx, px, HEADER_H, PANEL_W, 1, DIVIDER);

        // Tree area (clipped, scrollable).
        const tree_h = ph - HEADER_H - PROPS_H;
        kx.c.kx_clip_rect(ctx, px, HEADER_H, PANEL_W, tree_h);
        var i: usize = 0;
        while (i < insp.rows.items.len) : (i += 1) {
            const row = insp.rows.items[i];
            const row_y = HEADER_H + @as(f32, @floatFromInt(i)) * ROW_H - insp.scroll_y;
            // Skip rows outside the visible tree area.
            if (row_y + ROW_H <= HEADER_H or row_y >= HEADER_H + tree_h) continue;
            // Selection background.
            if (i == insp.sel_index) {
                kx.c.kx_fill_rect(ctx, px, row_y, PANEL_W, ROW_H, ROW_SEL);
            }
            // Chevron (ASCII only: > collapsed, v expanded).
            const chevron_x = px + PAD + @as(f32, @floatFromInt(row.depth)) * INDENT;
            if (row.node.children.items.len > 0) {
                const is_expanded = insp.expanded.get(row.node) orelse true;
                if (is_expanded) {
                    kx.c.kx_draw_text(ctx, "v", chevron_x, row_y + 12, 10, TEXT_DIM);
                } else {
                    kx.c.kx_draw_text(ctx, ">", chevron_x, row_y + 12, 10, TEXT_DIM);
                }
            }
            // Node name (copied into a sentinel-terminated buffer for kx).
            const label_x = chevron_x + CHEVRON_W;
            var name_buf: [128]u8 = undefined;
            const name = nodeName(row.node, &name_buf);
            kx.c.kx_draw_text(ctx, name, label_x, row_y + 12, 10, TEXT);
            // " (internal)" suffix (dim).
            if (row.node.internal) {
                const name_w = kx.c.kx_measure_text(name, 10, false).width;
                kx.c.kx_draw_text(ctx, " (internal)", label_x + name_w, row_y + 12, 10, TEXT_DIM);
            }
        }
        kx.c.kx_clip_reset(ctx);

        // Divider above the property view.
        const props_y = ph - PROPS_H;
        kx.c.kx_fill_rect(ctx, px, props_y, PANEL_W, 1, DIVIDER);

        // Property view.
        if (insp.selected) |sel| {
            paintProps(ctx, sel, px, props_y);
        } else {
            kx.c.kx_draw_text(ctx, "no selection", px + PAD, props_y + 16, 10, TEXT_DIM);
        }
    }
};

/// Display name for a node: semantics label, else role tag, else "node".
/// The label is copied into `buf` (a fixed 128-byte sentinel-terminated
/// buffer) so the result is always a [:0]const u8 for kx_draw_text.
fn nodeName(node: *Node, buf: *[128]u8) [:0]const u8 {
    if (node.semantics) |sem| {
        if (sem.label.len > 0) {
            return std.fmt.bufPrintSentinel(buf, "{s}", .{sem.label}, 0) catch "?";
        }
        if (sem.role != .none) return @tagName(sem.role);
    }
    return "node";
}

/// Paint one "key: value" line (key dim, value white, fixed key column).
fn drawProp(ctx: *kx.Ctx, key: [:0]const u8, value: [:0]const u8, px: f32, y: f32) void {
    kx.c.kx_draw_text(ctx, key, px + PAD, y, 10, TEXT_DIM);
    kx.c.kx_draw_text(ctx, value, px + PAD + PROP_KEY_W, y, 10, TEXT);
}

/// Paint the property view lines for the selected node.
fn paintProps(ctx: *kx.Ctx, node: *Node, px: f32, props_y: f32) void {
    var buf: [128]u8 = undefined;
    var y = props_y + 14;
    const line_h: f32 = 14;

    if (node.semantics) |sem| {
        drawProp(ctx, "name", @tagName(sem.role), px, y);
        y += line_h;
        if (sem.label.len > 0) {
            const label_val = std.fmt.bufPrintSentinel(&buf, "{s}", .{sem.label}, 0) catch "?";
            drawProp(ctx, "label", label_val, px, y);
            y += line_h;
        }
        if (sem.value.len > 0) {
            const value_val = std.fmt.bufPrintSentinel(&buf, "{s}", .{sem.value}, 0) catch "?";
            drawProp(ctx, "value", value_val, px, y);
            y += line_h;
        }
        if (sem.checked) |c| {
            drawProp(ctx, "checked", if (c) "true" else "false", px, y);
            y += line_h;
        }
        if (sem.disabled) {
            drawProp(ctx, "disabled", "true", px, y);
            y += line_h;
        }
        if (sem.focusable) {
            drawProp(ctx, "focusable", "true", px, y);
            y += line_h;
        }
    }
    // Bounds (mapped to root space).
    const r = node.mapRectToRoot(node.bounds);
    const bounds_val = std.fmt.bufPrintSentinel(&buf, "{d:.0},{d:.0} {d:.0}x{d:.0}", .{ r.x, r.y, r.w, r.h }, 0) catch "?";
    drawProp(ctx, "bounds", bounds_val, px, y);
    y += line_h;
    // Children count.
    const children_val = std.fmt.bufPrintSentinel(&buf, "{d}", .{node.children.items.len}, 0) catch "?";
    drawProp(ctx, "children", children_val, px, y);
    y += line_h;
    // Visible.
    drawProp(ctx, "visible", if (node.visible) "true" else "false", px, y);
    y += line_h;
    // Dirty.
    drawProp(ctx, "dirty", if (node.dirty) "true" else "false", px, y);
    y += line_h;
    // Pointer (hex).
    const ptr_val = std.fmt.bufPrintSentinel(&buf, "0x{x}", .{@intFromPtr(node)}, 0) catch "?";
    drawProp(ctx, "ptr", ptr_val, px, y);
}

// --- tests (stub leaf widget, same pattern as node.zig) ---

const TestState = struct { w: f32, h: f32 };

fn testMeasure(n: *Node, c: node_mod.Constraints) node_mod.Size {
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
const test_vtable = node_mod.VTable{ .measure = testMeasure, .layout = testLayout, .paint = testPaint, .deinit = testDeinit };

fn testNode(w: f32, h: f32) !*Node {
    const node = try Node.create(std.testing.allocator, &test_vtable);
    const s = try std.testing.allocator.create(TestState);
    s.* = .{ .w = w, .h = h };
    node.state = s;
    return node;
}

fn testInspector() !Inspector {
    return Inspector.init(std.testing.allocator);
}

test "toggle flips enabled" {
    var insp = try testInspector();
    defer insp.deinit();
    try std.testing.expect(!insp.enabled);
    insp.toggle();
    try std.testing.expect(insp.enabled);
    insp.toggle();
    try std.testing.expect(!insp.enabled);
}

test "rebuild flattens the tree with depths" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    a.add(b);
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 3), insp.rows.items.len);
    try std.testing.expectEqual(root, insp.rows.items[0].node);
    try std.testing.expectEqual(@as(u8, 0), insp.rows.items[0].depth);
    try std.testing.expectEqual(a, insp.rows.items[1].node);
    try std.testing.expectEqual(@as(u8, 1), insp.rows.items[1].depth);
    try std.testing.expectEqual(b, insp.rows.items[2].node);
    try std.testing.expectEqual(@as(u8, 2), insp.rows.items[2].depth);
}

test "invisible subtrees are skipped" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const hidden = try testNode(10, 10);
    const child = try testNode(10, 10);
    root.add(hidden);
    hidden.add(child);
    hidden.visible = false;
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 1), insp.rows.items.len);
    try std.testing.expectEqual(root, insp.rows.items[0].node);
}

test "collapse hides descendants / expand restores them" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    a.add(b);
    // Default: expanded (3 rows).
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 3), insp.rows.items.len);
    // Collapse `a` → only root + a (2 rows).
    try insp.expanded.put(a, false);
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 2), insp.rows.items.len);
    try std.testing.expectEqual(a, insp.rows.items[1].node);
    // Expand again → 3 rows.
    try insp.expanded.put(a, true);
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 3), insp.rows.items.len);
}

test "rebuild re-syncs sel_index when rows above the selection change" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    root.add(b);
    insp.rebuildRows(root);
    insp.select(b); // row 2
    try std.testing.expectEqual(@as(usize, 2), insp.sel_index);
    // Remove `a` (a row above the selection): `b` shifts from row 2 to row 1.
    _ = root.remove(a);
    a.deinit(); // caller owns the detached child
    insp.rebuildRows(root);
    try std.testing.expectEqual(b, insp.selected.?);
    try std.testing.expectEqual(@as(usize, 1), insp.sel_index);
    try std.testing.expectEqual(b, insp.rows.items[insp.sel_index].node);
}

test "select syncs sel_index" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    root.add(b);
    insp.rebuildRows(root);
    insp.select(b);
    try std.testing.expectEqual(b, insp.selected.?);
    try std.testing.expectEqual(@as(usize, 2), insp.sel_index);
    insp.select(null);
    try std.testing.expect(insp.selected == null);
}

test "keyboard: up/down clamp at both ends" {
    var insp = try testInspector();
    defer insp.deinit();
    insp.last_h = 480;
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    root.add(b);
    insp.rebuildRows(root);
    insp.sel_index = 0;
    insp.selected = root;
    // Up at the top: clamps (stays at 0).
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_UP));
    try std.testing.expectEqual(@as(usize, 0), insp.sel_index);
    try std.testing.expectEqual(root, insp.selected.?);
    // Down → 1.
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_DOWN));
    try std.testing.expectEqual(@as(usize, 1), insp.sel_index);
    try std.testing.expectEqual(a, insp.selected.?);
    // Down → 2.
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_DOWN));
    try std.testing.expectEqual(@as(usize, 2), insp.sel_index);
    try std.testing.expectEqual(b, insp.selected.?);
    // Down at the bottom: clamps (stays at 2).
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_DOWN));
    try std.testing.expectEqual(@as(usize, 2), insp.sel_index);
    try std.testing.expectEqual(b, insp.selected.?);
}

test "keyboard: left collapses, right expands" {
    var insp = try testInspector();
    defer insp.deinit();
    insp.last_h = 480;
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    a.add(b);
    insp.rebuildRows(root);
    // Select `a` (index 1).
    insp.sel_index = 1;
    insp.selected = a;
    // Left on expanded `a` → collapse (the expanded map flips, no rebuild here).
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_LEFT));
    try std.testing.expectEqual(false, insp.expanded.get(a).?);
    // Rebuild to see the effect: b is now hidden.
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 2), insp.rows.items.len);
    // Right on collapsed `a` → expand.
    insp.sel_index = 1;
    insp.selected = a;
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_RIGHT));
    try std.testing.expectEqual(true, insp.expanded.get(a).?);
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 3), insp.rows.items.len);
}

test "keyboard: enter/space toggle expand" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    root.add(a);
    insp.rebuildRows(root);
    insp.sel_index = 1;
    insp.selected = a;
    // Enter toggles expand on `a` (which has no children → no-op on the map,
    // but the key is still consumed).
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_RETURN));
    // Give `a` a child, then Enter collapses it.
    const b = try testNode(10, 10);
    a.add(b);
    insp.rebuildRows(root);
    try std.testing.expectEqual(@as(usize, 3), insp.rows.items.len);
    insp.sel_index = 1;
    insp.selected = a;
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_RETURN));
    try std.testing.expectEqual(false, insp.expanded.get(a).?);
    // Space toggles back.
    try std.testing.expect(insp.handleKey(sdl.c.SDLK_SPACE));
    try std.testing.expectEqual(true, insp.expanded.get(a).?);
}

test "scroll direction: SDL wheel down (y < 0) scrolls the content down" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    for (0..20) |_| {
        root.add(try testNode(10, 10));
    }
    insp.rebuildRows(root);
    // The host negates SDL's wheel.y at the call site (SDL3: y > 0 = scroll
    // up, y < 0 = scroll down); scrollBy's positive dy grows scroll_y.
    const wheel_down: f32 = -1; // SDL_EVENT_MOUSE_WHEEL, scrolled down
    insp.scrollBy(-wheel_down, 640, 480);
    try std.testing.expectEqual(ROW_H, insp.scroll_y);
    const wheel_up: f32 = 1; // scrolled up
    insp.scrollBy(-wheel_up, 640, 480);
    try std.testing.expectEqual(@as(f32, 0), insp.scroll_y);
}

test "scroll clamps to [0, maxScroll]" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    // 20 children → 21 rows → content 336px; tree_h = 480-24-180 = 276.
    for (0..20) |_| {
        root.add(try testNode(10, 10));
    }
    insp.rebuildRows(root);
    const tree_h: f32 = 480 - HEADER_H - PROPS_H;
    const content_h = @as(f32, @floatFromInt(insp.rows.items.len)) * ROW_H;
    const max_scroll = content_h - tree_h;
    // Scroll down past the end → clamps to maxScroll.
    insp.scrollBy(100, 640, 480);
    try std.testing.expectEqual(max_scroll, insp.scroll_y);
    // Scroll up past the start → clamps to 0.
    insp.scrollBy(-100, 640, 480);
    try std.testing.expectEqual(@as(f32, 0), insp.scroll_y);
    // Scroll a bit → in range.
    insp.scrollBy(2, 640, 480);
    try std.testing.expectEqual(2 * ROW_H, insp.scroll_y);
}

test "hitZone classifies panel / tree / props / none" {
    var insp = try testInspector();
    defer insp.deinit();
    const w: c_int = 640;
    const h: c_int = 480;
    const px = @as(f32, @floatFromInt(w)) - PANEL_W; // 340
    // Outside the panel (canvas).
    try std.testing.expectEqual(Zone.none, insp.hitZone(100, 100, w, h));
    try std.testing.expectEqual(Zone.none, insp.hitZone(px - 1, 100, w, h));
    // Inside the panel, tree area (y < 480-180=300).
    try std.testing.expectEqual(Zone.tree, insp.hitZone(px + 10, 50, w, h));
    try std.testing.expectEqual(Zone.tree, insp.hitZone(px + 10, 299, w, h));
    // Inside the panel, props area (y >= 300).
    try std.testing.expectEqual(Zone.props, insp.hitZone(px + 10, 350, w, h));
    try std.testing.expectEqual(Zone.props, insp.hitZone(px + 10, 479, w, h));
    // Right edge: outside.
    try std.testing.expectEqual(Zone.none, insp.hitZone(@as(f32, @floatFromInt(w)), 100, w, h));
}

test "clickAt on chevron toggles expand, on label selects" {
    var insp = try testInspector();
    defer insp.deinit();
    const w: c_int = 640;
    const h: c_int = 480;
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    a.add(b);
    insp.enabled = true;
    const px = @as(f32, @floatFromInt(w)) - PANEL_W;
    // Rows: root(0), a(1), b(2). Row 1 (a) is at y = 24 + 16 = 40, height 16.
    // Chevron for `a` at x = px + 8 + 1*12 = px + 20, width 12.
    const chevron_x = px + PAD + INDENT;
    const row1_y = HEADER_H + ROW_H + ROW_H / 2; // middle of row 1
    // Click on the chevron → toggle expand (collapse `a`).
    insp.clickAt(root, chevron_x + 2, row1_y, w, h);
    try std.testing.expectEqual(false, insp.expanded.get(a).?);
    try std.testing.expect(insp.tree_focus);
    // Click on the label → select.
    const label_x = chevron_x + CHEVRON_W + 4;
    insp.clickAt(root, label_x, row1_y, w, h);
    try std.testing.expectEqual(a, insp.selected.?);
}

test "clickAt ignores the header zone (above the tree area)" {
    var insp = try testInspector();
    defer insp.deinit();
    const w: c_int = 640;
    const h: c_int = 480;
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    root.add(a);
    insp.enabled = true;
    insp.rebuildRows(root);
    const px = @as(f32, @floatFromInt(w)) - PANEL_W;
    // Click in the header (y < HEADER_H): no selection, no tree focus.
    insp.clickAt(root, px + 10, HEADER_H / 2, w, h);
    try std.testing.expect(insp.selected == null);
    try std.testing.expect(!insp.tree_focus);
    // Same with the tree scrolled: the header must not resolve to row 0.
    insp.scroll_y = 5 * ROW_H;
    insp.clickAt(root, px + 10, HEADER_H / 2, w, h);
    try std.testing.expect(insp.selected == null);
    try std.testing.expect(!insp.tree_focus);
    // Sanity: with the tree back at the top, a click on the first row
    // (depth 0, past the chevron) selects the root.
    insp.scroll_y = 0;
    insp.clickAt(root, px + 40, HEADER_H + ROW_H / 2, w, h);
    try std.testing.expectEqual(root, insp.selected.?);
}

test "pickAt selects the deepest hit node" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    // Click on the child → selects the child.
    insp.pickAt(root, 20, 20);
    try std.testing.expectEqual(child, insp.selected.?);
    try std.testing.expect(!insp.tree_focus);
    // Click on the root (outside the child) → selects the root.
    insp.pickAt(root, 80, 80);
    try std.testing.expectEqual(root, insp.selected.?);
    // Click outside everything → clears the selection.
    insp.pickAt(root, 200, 200);
    try std.testing.expect(insp.selected == null);
}

test "selected node destroyed → rebuild drops the selection" {
    var insp = try testInspector();
    defer insp.deinit();
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    root.add(a);
    insp.rebuildRows(root);
    insp.select(a);
    try std.testing.expectEqual(a, insp.selected.?);
    // Remove `a` from the tree (the caller still owns it), rebuild → selection dropped.
    _ = root.remove(a);
    insp.rebuildRows(root);
    try std.testing.expect(insp.selected == null);
    a.deinit(); // caller owns the detached child
}

test "nodeName fallback chain (label > role > \"node\")" {
    const n = try testNode(10, 10);
    defer n.deinit();
    var buf: [128]u8 = undefined;
    // No semantics → "node".
    try std.testing.expectEqualStrings("node", nodeName(n, &buf));
    // Role only → tag name.
    semantics_mod.attach(n, .{ .role = .button });
    try std.testing.expectEqualStrings("button", nodeName(n, &buf));
    // Label wins over role.
    semantics_mod.attach(n, .{ .role = .button, .label = "OK" });
    try std.testing.expectEqualStrings("OK", nodeName(n, &buf));
}

test "golden: inspector paints panel + bounds highlight (exact pixels)" {
    const a = std.testing.allocator;
    // Transparent background: the panel's semi-transparent colors (PANEL_BG,
    // HIGHLIGHT) render EXACTLY over alpha-0 (src-over preserves src alpha
    // when dst alpha is 0), so countColor finds exact matches.
    const bg: Color = 0x00000000;
    var insp = try Inspector.init(a);
    defer insp.deinit();
    insp.enabled = true;

    var r = try golden.Renderer.init(a, 640, 480);
    defer r.deinit();

    const root = try golden.solidBox(a, 640, 480, bg);
    defer root.deinit();
    const box = try golden.solidBox(a, 40, 20, 0xFF0000FF);
    root.add(box);
    root.layout(.{ .x = 0, .y = 0, .w = 640, .h = 480 });
    box.layout(.{ .x = 40, .y = 20, .w = 40, .h = 20 });

    insp.select(box);

    // Enabled: panel + highlight painted.
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    root.paint(r.ctx);
    insp.paintHighlight(r.ctx);
    insp.paint(r.ctx, root, 640, 480);
    kx.c.kx_end_frame(r.ctx);
    var f1 = try r.readback(a);
    defer f1.deinit();
    try std.testing.expect(f1.countColor(PANEL_BG) > 0);
    try std.testing.expect(f1.countColor(HIGHLIGHT) > 0);

    // Disabled: paint is a no-op → no panel, no highlight. The host only
    // calls paintHighlight/paint when enabled, so the test mirrors that.
    insp.enabled = false;
    kx.c.kx_begin_frame(r.ctx);
    kx.c.kx_clear(r.ctx, bg);
    root.paint(r.ctx);
    if (insp.enabled) {
        insp.paintHighlight(r.ctx);
        insp.paint(r.ctx, root, 640, 480);
    }
    kx.c.kx_end_frame(r.ctx);
    var f2 = try r.readback(a);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u64, 0), f2.countColor(PANEL_BG));
    try std.testing.expectEqual(@as(u64, 0), f2.countColor(HIGHLIGHT));
}
