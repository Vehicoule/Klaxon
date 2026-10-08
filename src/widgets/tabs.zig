// Tabs widget (Phase 2d.1, M3E batch 1) — primary top tab row.
//
// Spec: m3.material.io/components/tabs (M3E) + Compose
// PrimaryNavigationTabTokens:
//   - container height 48 (label only) / 64 (icon + label), color surface,
//   - tabs split the width into equal sections, content vertically centered,
//   - divider: 1dp, surface_variant, inside the container height at the bottom,
//   - active indicator: 3dp high pill, primary, inset 2dp on each side of the
//     tab (minimum length 24), sitting on the divider,
//   - state layer color = the selected content color (primary active /
//     on_surface_variant inactive — Compose Tab ripple),
//   - active icon/label = primary (app-supplied), inactive = on_surface_variant.
//
// The indicator GLIDES between tabs with the theme's default spring (M3E
// motion); without a timeline it snaps. The selection is a Signal(usize)
// owned by the app. Items get a `.tab` semantic (checked follows the
// selection; Enter/Space activates, arrows move the selection).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const anim = ui.anim;
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

/// M3E measurement tokens: indicator inset 2dp per side, minimum length 24.
const indicator_inset: f32 = 2;
const indicator_min_w: f32 = 24;

pub const TabsOptions = struct {
    theme: Theme = theme_mod.light,
    height: f32 = 64, // M3E: 48 label-only / 64 icon+label
    indicator_height: f32 = 3, // primary active indicator height
    divider_height: f32 = 1, // bottom divider (inside the container height)
    label: []const u8 = "Tabs", // semantic label (borrowed)
};

const TabsState = struct {
    sig: *ui.state.Signal(usize),
    opts: TabsOptions,
    hovered: ?usize = null,
    pressed: ?usize = null,
    /// Per-tab layout cache: the cell rects (hit-testing) and the content
    /// sizes (centering).
    cells: std.array_list.Managed(Rect),
    content_sizes: std.array_list.Managed(Size),
    semantics_attached: bool = false,
    // Animated indicator (x/w of the active tab's indicator).
    indicator_x: f32 = 0,
    indicator_w: f32 = 0,
    anim_to_x: f32 = 0, // current animation target (identity of the target)
    anim_to_w: f32 = 0,
    laid_out: bool = false,
    anim_channel: u8 = 0, // channel marker (stable address): one indicator animation
};

fn stateOf(n: *Node) *TabsState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The tab (child index) under a window-space point, or null.
fn tabAtPoint(n: *Node, s: *TabsState, raw_x: f32, raw_y: f32) ?usize {
    const p = Node.mapPointToParentSpace(n, raw_x, raw_y);
    for (s.cells.items, 0..) |cell, i| {
        if (cell.contains(p.x, p.y)) return i;
    }
    return null;
}

/// Attach (or update) the `.tab` semantic on every tab — the label/hint of
/// an existing descriptor is preserved.
fn syncTabSemantics(n: *Node, s: *TabsState) void {
    const sel = s.sig.peek();
    for (n.children.items, 0..) |child, i| {
        const checked = i == sel;
        if (child.semantics) |sem| {
            sem.role = .tab;
            sem.focusable = true;
            sem.checked = checked;
            sem.actions = ui.semantics.Actions.initOne(.activate);
        } else {
            ui.semantics.attach(child, .{ .role = .tab, .focusable = true, .checked = checked, .actions = ui.semantics.Actions.initOne(.activate) });
        }
    }
}

/// The child index containing the focused node (keyboard activation).
fn focusedTab(n: *Node) ?usize {
    const router = input.current() orelse return null;
    const f = router.focused orelse return null;
    var cur: ?*Node = f;
    while (cur) |c| : (cur = c.parent) {
        if (c == n) return null;
        for (n.children.items, 0..) |child, i| {
            if (child == c) return i;
        }
    }
    return null;
}

fn indicatorUpdateCb(userdata: ?*anyopaque, v: anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    s.indicator_x = v[0];
    s.indicator_w = v[1];
    n.markDirty();
}

/// Glide the indicator to a new target (theme default spring); without a
/// timeline the indicator snaps.
fn animateIndicator(n: *Node, s: *TabsState, to_x: f32, to_w: f32) void {
    s.anim_to_x = to_x;
    s.anim_to_w = to_w;
    const from: anim.Vec4 = .{ s.indicator_x, s.indicator_w, 0, 0 };
    if (anim.timeline()) |tl| {
        _ = tl.play(.{
            .kind = anim.Animation.springAnim(from, .{ to_x, to_w, 0, 0 }, s.opts.theme.motion.springs.default_spring, .{ 0, 0, 0, 0 }),
            .from = from,
            .channel = @ptrCast(&s.anim_channel),
            .on_update = .{ .fn_ptr = indicatorUpdateCb, .userdata = n },
        });
    } else {
        s.indicator_x = to_x;
        s.indicator_w = to_w;
    }
}

fn tabsMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const count: f32 = @floatFromInt(n.children.items.len);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else count * 90;
    return c.constrain(.{ .w = w, .h = s.opts.height });
}

fn tabsLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const count = n.children.items.len;
    if (count == 0) return;
    const tab_w = bounds.w / @as(f32, @floatFromInt(count));
    if (s.cells.items.len != count) {
        s.cells.clearRetainingCapacity();
        s.content_sizes.clearRetainingCapacity();
        for (0..count) |_| {
            s.cells.append(.{}) catch @panic("klaxon: out of memory");
            s.content_sizes.append(.{}) catch @panic("klaxon: out of memory");
        }
    }
    const loose: Constraints = .{ .max_w = tab_w, .max_h = bounds.h };
    for (n.children.items, 0..) |child, i| {
        const cs = child.measure(loose);
        const x = bounds.x + @as(f32, @floatFromInt(i)) * tab_w;
        s.cells.items[i] = .{ .x = x, .y = bounds.y, .w = tab_w, .h = bounds.h };
        s.content_sizes.items[i] = cs;
        child.layout(.{
            .x = x + (tab_w - cs.w) / 2,
            .y = bounds.y + (bounds.h - cs.h) / 2,
            .w = cs.w,
            .h = cs.h,
        });
    }
    if (!s.semantics_attached) {
        s.semantics_attached = true;
        syncTabSemantics(n, s);
    }
    // The indicator target: the selected tab's cell, inset 2dp per side.
    const sel = @min(s.sig.peek(), count - 1);
    const cell = s.cells.items[sel];
    const target_w = @max(indicator_min_w, cell.w - indicator_inset * 2);
    const target_x = cell.x + (cell.w - target_w) / 2;
    if (!s.laid_out) {
        // First layout: the indicator appears directly under the selection.
        s.indicator_x = target_x;
        s.indicator_w = target_w;
        s.anim_to_x = target_x;
        s.anim_to_w = target_w;
        s.laid_out = true;
    } else if (target_x != s.anim_to_x or target_w != s.anim_to_w) {
        animateIndicator(n, s, target_x, target_w);
    }
}

fn tabsPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, t.colors.surface);
    const sel = s.sig.peek();
    for (s.cells.items, 0..) |cell, i| {
        const hovered = s.hovered != null and s.hovered.? == i;
        const pressed = s.pressed != null and s.pressed.? == i;
        if (hovered or pressed) {
            const alpha = if (pressed) t.state.pressed else t.state.hover;
            // State layer color = the selected content color (Compose Tab).
            const on = if (i == sel) t.colors.primary else t.colors.on_surface_variant;
            ui.paint.fillRect(ctx, cell.x, cell.y, cell.w, cell.h, theme_mod.stateLayer(t.colors.surface, on, alpha));
        }
    }
    // Divider (inside the container height, at the bottom).
    const dh = s.opts.divider_height;
    ui.paint.fillRect(ctx, b.x, b.y + b.h - dh, b.w, dh, t.colors.surface_variant);
    // Active indicator (pill, on the divider).
    const ih = s.opts.indicator_height;
    ui.paint.fillRRect(ctx, s.indicator_x, b.y + b.h - dh - ih, s.indicator_w, ih, ih / 2, t.colors.primary);
}

fn tabsOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            s.pressed = tabAtPoint(n, s, ev.raw_x, ev.raw_y);
            if (s.pressed != null) {
                n.markDirty();
                return true;
            }
            return false;
        },
        .up => {
            const up_tab = tabAtPoint(n, s, ev.raw_x, ev.raw_y);
            const was = s.pressed;
            s.pressed = null;
            n.markDirty();
            if (was != null) {
                if (up_tab != null and up_tab.? == was.?) {
                    s.sig.set(up_tab.?);
                    n.markLayoutDirty(); // the indicator target moved
                }
                return true; // the press is consumed even when released outside
            }
            return false;
        },
        .enter => {
            s.hovered = tabAtPoint(n, s, ev.raw_x, ev.raw_y);
            n.markDirty();
            return true;
        },
        .leave => {
            if (s.hovered != null) {
                s.hovered = null;
                n.markDirty();
            }
            return true;
        },
        .move => return s.pressed != null,
        // Uncaptured hover over an unchanged deepest node: track the hovered
        // cell (the enter/leave pair only fires when the node changes).
        .hover_move => {
            const h = tabAtPoint(n, s, ev.raw_x, ev.raw_y);
            if (h != s.hovered) {
                s.hovered = h;
                n.markDirty();
            }
            return true;
        },
        else => return false,
    }
}

fn tabsOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (focusedTab(n)) |i| {
                s.sig.set(i);
                n.markLayoutDirty();
                return true;
            }
            return false;
        },
        .left => {
            const sel = s.sig.peek();
            if (sel > 0) {
                s.sig.set(sel - 1);
                n.markLayoutDirty();
                input.requestFocus(n.children.items[sel - 1]); // selection-follows-focus, both ways
                return true;
            }
            return false;
        },
        .right => {
            const sel = s.sig.peek();
            if (sel + 1 < n.children.items.len) {
                s.sig.set(sel + 1);
                n.markLayoutDirty();
                input.requestFocus(n.children.items[sel + 1]);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Selection changed: sync the tabs' checked state, repaint, announce.
fn tabsSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.semantics_attached) syncTabSemantics(n, s);
    n.markDirty();
    n.markLayoutDirty(); // the indicator target moved
    ui.semantics.notifyControlChanged(n); // a11y: the selection changed
}

fn tabsDeinit(n: *Node) void {
    const s = stateOf(n);
    if (anim.timeline()) |tl| tl.cancelChannel(@ptrCast(&s.anim_channel)); // the update cb points at this node
    s.sig.unsubscribe(.{ .callback = .{ .fn_ptr = tabsSyncCb, .userdata = n } });
    input.releaseNode(n);
    s.cells.deinit();
    s.content_sizes.deinit();
    n.allocator.destroy(s);
}

const tabs_vtable = ui.node.VTable{
    .measure = tabsMeasure,
    .layout = tabsLayout,
    .paint = tabsPaint,
    .deinit = tabsDeinit,
    .on_pointer = tabsOnPointer,
    .on_key = tabsOnKey,
};

/// Primary tab row (M3E). Children = the tabs (passive icon+label content);
/// the row owns selection, the gliding indicator, state layers and the
/// divider. `selected` is app-owned; the row subscribes and unsubscribes at
/// deinit.
pub fn tabs(allocator: std.mem.Allocator, selected: *ui.state.Signal(usize), opts: TabsOptions) !*Node {
    const node = try Node.create(allocator, &tabs_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TabsState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = selected, .opts = opts, .cells = .init(allocator), .content_sizes = .init(allocator) };
    node.state = s;
    ui.semantics.attach(node, .{ .role = .group, .label = opts.label }); // Phase 2c
    selected.subscribe(.{ .callback = .{ .fn_ptr = tabsSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

const text_w = @import("text.zig");

fn testTab(a: std.mem.Allocator, label: []const u8) !*Node {
    return text_w.text(a, label, .{ .size = 14, .color = 0x000000FF });
}

test "tabs: measure fills the width and reports the M3E height" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    const m = row.measure(.{ .max_w = 480, .max_h = 600 });
    try std.testing.expectEqual(@as(f32, 480), m.w);
    try std.testing.expectEqual(@as(f32, 64), m.h);
}

test "tabs: layout splits the width equally; the indicator snaps without a timeline" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    const s = stateOf(row);
    try std.testing.expectEqual(@as(usize, 2), s.cells.items.len);
    try std.testing.expectEqual(@as(f32, 0), s.cells.items[0].x);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[0].w);
    try std.testing.expectEqual(@as(f32, 200), s.cells.items[1].x);
    // first layout: the indicator sits under tab 0 (inset 2, width 196)
    try std.testing.expectEqual(@as(f32, 2), s.indicator_x);
    try std.testing.expectEqual(@as(f32, 196), s.indicator_w);
    // selection change + relayout: snap (no timeline installed)
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    try std.testing.expectEqual(@as(f32, 202), s.indicator_x);
    try std.testing.expectEqual(@as(f32, 196), s.indicator_w);
}

test "tabs: with a timeline the indicator glides (spring) to the target" {
    var tl = anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    anim.setCurrent(&tl);
    defer anim.setCurrent(null);
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    const s = stateOf(row);
    try std.testing.expectEqual(@as(f32, 2), s.indicator_x);
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 }); // launches the spring
    try std.testing.expect(tl.hasActive());
    tl.tick(0); // lazy start: the value is still `from`
    try std.testing.expectEqual(@as(f32, 2), s.indicator_x);
    tl.tick(50); // mid-flight: strictly between the two targets
    try std.testing.expect(s.indicator_x > 2 and s.indicator_x < 202);
    tl.tick(10_000); // settled: exactly on target
    try std.testing.expectEqual(@as(f32, 202), s.indicator_x);
    try std.testing.expectEqual(@as(f32, 196), s.indicator_w);
    try std.testing.expect(!tl.hasActive());
}

test "tabs: items get .tab semantics with checked following the selection" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    try std.testing.expect(row.children.items[0].semantics.?.checked.?);
    try std.testing.expect(!row.children.items[1].semantics.?.checked.?);
    sel.set(1);
    try std.testing.expect(!row.children.items[0].semantics.?.checked.?);
    try std.testing.expect(row.children.items[1].semantics.?.checked.?);
}

test "tabs: click selects the tab under the pointer" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    var router = input.InputRouter{};
    router.dispatchPointer(row, .{ .phase = .down, .x = 300, .y = 32 });
    router.dispatchPointer(row, .{ .phase = .up, .x = 300, .y = 32 });
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
}

test "tabs: arrows move the selection AND the focus; hover tracks across cells" {
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{});
    defer row.deinit();
    const a = try testTab(std.testing.allocator, "One");
    const b = try testTab(std.testing.allocator, "Two");
    row.add(a);
    row.add(b);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // focus followed the selection: Enter activates the NEW tab
    input.requestFocus(a);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .right }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    try std.testing.expect(router.focused == b);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(usize, 1), sel.peek());
    // hover_move: y=4 is inside the row but above the centered content —
    // moving between such spots keeps the same deepest node (the row).
    const s = stateOf(row);
    router.dispatchPointer(row, .{ .phase = .move, .x = 50, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 0), s.hovered);
    router.dispatchPointer(row, .{ .phase = .move, .x = 250, .y = 4 });
    try std.testing.expectEqual(@as(?usize, 1), s.hovered);
}

test "golden: tabs paint the surface, the divider and the primary indicator" {
    const t = theme_mod.light;
    const sel = try ui.state.Signal(usize).init(std.testing.allocator, 0);
    defer sel.deinit();
    const row = try tabs(std.testing.allocator, sel, .{ .theme = t });
    defer row.deinit();
    row.add(try testTab(std.testing.allocator, "One"));
    row.add(try testTab(std.testing.allocator, "Two"));
    var r = try golden.Renderer.init(std.testing.allocator, 400, 64);
    defer r.deinit();
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    r.paint(row, 0x000000FF);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // container
    try std.testing.expect(f1.countColor(t.colors.surface) > 400 * 64 - 3000);
    // divider: the bottom 1dp row is surface_variant
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 63, .w = 400, .h = 1 }, t.colors.surface_variant) == 400);
    // indicator under tab 0 only
    try std.testing.expect(f1.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 64 }, t.colors.primary) > 100);
    try std.testing.expect(f1.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 64 }, t.colors.primary) == 0);
    // select tab 1 (no timeline: snap on relayout)
    sel.set(1);
    row.layout(.{ .x = 0, .y = 0, .w = 400, .h = 64 });
    r.paint(row, 0x000000FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColorIn(.{ .x = 0, .y = 0, .w = 200, .h = 64 }, t.colors.primary) == 0);
    try std.testing.expect(f2.countColorIn(.{ .x = 200, .y = 0, .w = 200, .h = 64 }, t.colors.primary) > 100);
}
