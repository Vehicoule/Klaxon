// M3E ExpansionPanel (Phase 4d P2) — a collapsible panel with a tappable
// header (title + chevron) that reveals its child content.
//
// Spec: docs/specs/m3e-specs-4d-p2-expansionpanel.md
// Sources: Compose Material3 ExpansionPanel (experimental), MWC
// expansion-panel, M3E token system.
//
// Tokens:
//   - container: SurfaceContainer, shape: CornerMedium (12dp)
//   - header: 48dp tall, tappable, title = TitleMedium + OnSurface,
//     chevron = 24dp OnSurfaceVariant (rotates 0° → 180°)
//   - divider: 1dp OutlineVariant between header and content (expanded)
//   - content: 16dp padding around the child
//   - state layer: hover 0.08 / pressed 0.12 over OnSurface (header)
//
// State: `expanded` is a two-way Signal(bool) — always live, round-trips.
// The child's visibility follows the signal (v1: instant, no animation).
//
// v1 deviations: instant expand/collapse; no disabled state; no accordion.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ExpansionPanelOptions = struct {
    theme: Theme = theme_mod.light,
    /// The header title.
    title: []const u8 = "Panel",
};

// --- M3E tokens ---

const panel_corner: f32 = 12; // CornerMedium
const header_h: f32 = 48;
const header_pad: f32 = 16;
const content_pad: f32 = 16;
const divider_h: f32 = 1;
const chevron_size: f32 = 24;

// --- State ---

const EPState = struct {
    opts: ExpansionPanelOptions,
    sig: ?*ui.state.Signal(bool),
    title_z: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    pressed: bool = false,
    hovered: bool = false,
};

fn stateOf(n: *Node) *EPState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isExpanded(s: *EPState) bool {
    return if (s.sig) |sig| sig.peek() else false;
}

/// Sync the child's visibility + layout with the expanded state.
fn syncExpanded(n: *Node, s: *EPState) void {
    const expanded = isExpanded(s);
    for (n.children.items) |child| {
        child.visible = expanded;
    }
    // Update a11y value.
    if (n.semantics) |sem| {
        sem.value = if (expanded) "expanded" else "collapsed";
    }
    n.markDirty();
    n.markLayoutDirty();
}

// --- Measure ---

fn epMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    // Header width: title + chevron + paddings.
    const t = s.opts.theme;
    const ts = t.type_scale.title_medium;
    const title_w = ui.paint.measureText(s.title_z[0..s.title_len :0], ts.size, ts.weight >= 500).width;
    const header_w = header_pad + title_w + 8 + chevron_size + header_pad;
    var w = @max(header_w, c.min_w);
    w = @min(w, c.max_w);
    // Clamp to at least the constraints.
    w = @max(w, c.min_w);

    // Height: header + (expanded ? divider + 2*content_pad + child_h : 0).
    var h = header_h;
    if (isExpanded(s) and n.children.items.len > 0) {
        const child = n.children.items[0];
        const child_c = Constraints{
            .min_w = @max(0, w - content_pad * 2),
            .max_w = @max(0, w - content_pad * 2),
            .min_h = 0,
            .max_h = c.max_h,
        };
        const child_sz = child.measure(child_c);
        h += divider_h + content_pad * 2 + child_sz.h;
    }
    h = @max(h, c.min_h);
    h = @min(h, c.max_h);

    return .{ .w = w, .h = h };
}

// --- Layout ---

fn epLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    if (isExpanded(s) and n.children.items.len > 0) {
        const child = n.children.items[0];
        const child_y = bounds.y + header_h + divider_h + content_pad;
        const child_w = @max(0, bounds.w - content_pad * 2);
        child.layout(.{
            .x = bounds.x + content_pad,
            .y = child_y,
            .w = child_w,
            .h = child.measure(.{ .max_w = child_w, .max_h = bounds.y + bounds.h - child_y }).h,
        });
    }
}

// --- Paint ---

fn epPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;

    // Panel background.
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, panel_corner, t.colors.surface_container);

    // Header state layer.
    if (s.pressed or s.hovered) {
        const alpha = if (s.pressed) t.state.pressed else t.state.hover;
        const layer = theme_mod.stateLayer(t.colors.surface_container, t.colors.on_surface, alpha);
        // Clip the state layer to the header's top half (rounded top corners).
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, header_h, panel_corner, layer);
    }

    // Title.
    const ts = t.type_scale.title_medium;
    const title_z = s.title_z[0..s.title_len :0];
    const title_x = b.x + header_pad;
    const title_y = b.y + (header_h - ts.line_height) / 2 + ts.line_height * 0.8;
    ui.paint.text(ctx, title_z, title_x, title_y, ts.size, ts.weight >= 500, t.colors.on_surface);

    // Chevron (▼ when collapsed, ▲ when expanded — v1: static glyph swap).
    const expanded = isExpanded(s);
    const chevron_glyph: [:0]const u8 = if (expanded) "\u{25B2}" else "\u{25BC}"; // ▲ / ▼
    const chev_metrics = ui.paint.measureText(chevron_glyph, chevron_size, false);
    const chev_x = b.x + b.w - header_pad - chev_metrics.width;
    const chev_y = b.y + (header_h - chev_metrics.height) / 2 + chev_metrics.height * 0.8;
    ui.paint.text(ctx, chevron_glyph, chev_x, chev_y, chevron_size, false, t.colors.on_surface_variant);

    // Divider (expanded only).
    if (expanded) {
        const div_y = b.y + header_h;
        ui.paint.fillRect(ctx, b.x, div_y, b.w, divider_h, t.colors.outline_variant);
    }
}

// --- Input ---

fn epPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;
    // Only the header is tappable.
    const in_header = ev.y >= b.y and ev.y <= b.y + header_h and ev.x >= b.x and ev.x <= b.x + b.w;
    if (!in_header) return false;

    switch (ev.phase) {
        .down => {
            s.pressed = true;
            n.markDirty();
            input.requestFocus(n);
            return true;
        },
        .up => {
            if (s.pressed) {
                s.pressed = false;
                n.markDirty();
                toggle(s, n);
            }
            return true;
        },
        .move => {
            const inside = in_header;
            if (inside != s.hovered) {
                s.hovered = inside;
                n.markDirty();
            }
            return true;
        },
        .outside_down => {
            if (s.pressed) {
                s.pressed = false;
                n.markDirty();
            }
            return false;
        },
        else => return false,
    }
}

fn epKey(n: *Node, ev: input.KeyEvent) bool {
    if (ev.kind != .key_down) return false;
    const s = stateOf(n);
    switch (ev.key) {
        .enter, .space => {
            toggle(s, n);
            return true;
        },
        else => return false,
    }
}

fn toggle(s: *EPState, n: *Node) void {
    const new_val = !isExpanded(s);
    if (s.sig) |sig| sig.set(new_val);
    syncExpanded(n, s);
    if (n.semantics) |_| ui.semantics.notifyControlChanged(n);
}

/// External signal sync callback.
fn epSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    syncExpanded(n, stateOf(n));
}

// --- Deinit ---

fn epDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = epSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

// --- VTable ---

const ep_vtable = ui.node.VTable{
    .measure = epMeasure,
    .layout = epLayout,
    .paint = epPaint,
    .on_pointer = epPointer,
    .on_key = epKey,
    .deinit = epDeinit,
};

// --- Factory ---

/// Create an M3E expansion panel.
///
/// `expanded` — a live Signal(bool) driving the panel state.
/// `child` — the content node (visible when expanded). The panel takes
/// ownership (it is added as a child).
/// `opts` — title, theme.
pub fn expansionPanel(
    allocator: std.mem.Allocator,
    expanded: ?*ui.state.Signal(bool),
    child: ?*Node,
    opts: ExpansionPanelOptions,
) !*Node {
    const node = try Node.create(allocator, &ep_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(EPState);
    errdefer allocator.destroy(s);

    s.* = .{ .opts = opts, .sig = expanded };

    // Copy the title (null-terminated).
    const copy_len = @min(opts.title.len, 127);
    @memcpy(s.title_z[0..copy_len], opts.title[0..copy_len]);
    s.title_z[copy_len] = 0;
    s.title_len = copy_len;

    node.state = @ptrCast(s);

    // Attach the child.
    if (child) |c| {
        node.add(c);
    }

    // Subscribe to external signal changes.
    if (expanded) |sig| {
        sig.subscribe(.{ .callback = .{ .fn_ptr = epSyncCb, .userdata = node } });
    }
    syncExpanded(node, s);

    ui.semantics.attach(node, .{
        .role = .button,
        .label = s.title_z[0..copy_len],
        .value = if (isExpanded(s)) "expanded" else "collapsed",
        .focusable = true,
    });

    return node;
}

// --- Tests ---

test "expansion_panel: collapsed measure = header only" {
    const a = std.testing.allocator;
    const text_w = @import("text.zig");
    const child = try text_w.text(a, "Content", .{ .size = 14 });
    const n = try expansionPanel(a, null, child, .{ .title = "Test" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 400, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(header_h, sz.h, 0.001);
}

test "expansion_panel: expanded measure includes the child" {
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(bool).init(a, true);
    defer sig.deinit();
    const text_w = @import("text.zig");
    const child = try text_w.text(a, "Content here", .{ .size = 14 });
    const n = try expansionPanel(a, sig, child, .{ .title = "Test" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 400, .max_h = 2000 });
    // header + divider + 2*content_pad + child height (text line).
    try std.testing.expect(sz.h > header_h + divider_h + content_pad * 2);
}

test "expansion_panel: click toggles the signal" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const a = std.testing.allocator;
    const n = try expansionPanel(a, sig, null, .{ .title = "Test" });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 300, .h = 48 });
    try std.testing.expectEqual(false, sig.peek());
    // Click the header.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 150, .y = 24, .raw_x = 150, .raw_y = 24 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 150, .y = 24, .raw_x = 150, .raw_y = 24 });
    try std.testing.expectEqual(true, sig.peek());
}

test "expansion_panel: semantics — role button, value follows state" {
    const a = std.testing.allocator;
    const n = try expansionPanel(a, null, null, .{ .title = "My Panel" });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.button, n.semantics.?.role);
    try std.testing.expectEqualStrings("My Panel", n.semantics.?.label);
    try std.testing.expectEqualStrings("collapsed", n.semantics.?.value);
}

test "golden: the collapsed panel paints SurfaceContainer + title + chevron" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try expansionPanel(a, null, null, .{ .title = "Hello", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 340, 80);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 300, .h = 48 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Panel fill at a corner inside the rounded rect.
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(35, 35));
    // Outside the panel (corner): background.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // Title ink (OnSurface) in the header area.
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 30, .w = 100, .h = 20 }, t.colors.on_surface) > 0);
}
