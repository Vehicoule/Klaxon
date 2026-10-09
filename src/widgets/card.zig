// Card (Phase 2d.3 PR D1, M3E) — the three Material 3 Expressive card
// variants: filled, elevated, outlined.
//
// Spec: m3.material.io/components/cards + Compose Card.kt +
// {Elevated,Filled,Outlined}CardTokens:
//   - shape: CornerMedium = 12dp, all corners (all variants)
//   - containers: filled = SurfaceContainerHighest; elevated =
//     SurfaceContainerLow; outlined = Surface + OutlineVariant 1dp stroke
//     (focus outline OnSurface)
//   - disabled: filled = SurfaceVariant@0.38; elevated = Surface@0.38;
//     outlined = Surface + OnSurface@0.12 stroke
//   - content color: OnSurface; clickable card = a state layer of on_surface
//     @ hover 0.08 / focus 0.10 / pressed 0.12 over the container
//   - layout: a Surface wrapping a Column — the M3 spec has NO intrinsic
//     padding (apps add their own); this widget exposes a `padding` option
//     (default 16) + `gap` (default 0); children stretch to the inner width
//
// The card is a CONTAINER: its children are document data (they keep their
// own semantics; a child's own click handler wins the hit test first).
//
// v1 deviations (documented, fixed later):
//   - Flat colors (no elevation shadows — Phase 3: hover/press/drag change
//     the elevation, not the color).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const CardVariant = enum { filled, elevated, outlined };

pub const CardOptions = struct {
    variant: CardVariant = .filled,
    enabled: bool = true,
    /// The content inset (the M3 spec has no intrinsic card padding — this is
    /// the app's content padding).
    padding: ui.layout.EdgeInsets = ui.layout.EdgeInsets.all(16),
    /// The vertical gap between children (the content column's gap).
    gap: f32 = 0,
    theme: Theme = theme_mod.light,
};

/// M3E tokens: CornerMedium radius; the outlined stroke width.
const card_radius: f32 = 12; // CornerMedium
const outline_w: f32 = 1;

const CardState = struct {
    opts: CardOptions,
    on_click: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — see PointerEvent.raw_x/raw_y).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *CardState {
    return @ptrCast(@alignCast(n.state.?));
}

fn isClickable(s: *CardState) bool {
    return s.on_click != null and s.opts.enabled;
}

fn cardMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const inner = c.deflateEdge(s.opts.padding);
    var w: f32 = 0;
    var h: f32 = s.opts.padding.vSum();
    var first = true;
    for (n.children.items) |child| {
        const cs = child.measure(inner);
        w = @max(w, cs.w);
        if (!first) h += s.opts.gap;
        h += cs.h;
        first = false;
    }
    return c.constrain(.{ .w = w + s.opts.padding.hSum(), .h = h });
}

fn cardLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const inner_x = bounds.x + s.opts.padding.left;
    const inner_w = @max(0, bounds.w - s.opts.padding.hSum());
    var y = bounds.y + s.opts.padding.top;
    for (n.children.items) |child| {
        const cs = child.measure(.{ .max_w = inner_w, .max_h = bounds.h });
        child.layout(.{ .x = inner_x, .y = y, .w = inner_w, .h = cs.h }); // stretch cross-axis
        y += cs.h + s.opts.gap;
    }
}

fn cardPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const cs = s.opts.theme.colors;
    const container: Color = if (!s.opts.enabled)
        switch (s.opts.variant) {
            .filled => ui.paint.withAlphaScaled(cs.surface_variant, 0.38),
            .elevated => ui.paint.withAlphaScaled(cs.surface, 0.38),
            .outlined => cs.surface,
        }
    else switch (s.opts.variant) {
        .filled => cs.surface_container_highest,
        .elevated => cs.surface_container_low,
        .outlined => cs.surface,
    };
    if (container & 0xFF != 0) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, card_radius, container);
    }
    // the state layer (clickable, enabled): on_surface over the container
    if (isClickable(s)) {
        const alpha: f32 = if (s.pressed)
            s.opts.theme.state.pressed
        else if (input.isFocused(n))
            s.opts.theme.state.focus
        else if (s.hovered)
            s.opts.theme.state.hover
        else
            0;
        if (alpha > 0) {
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, card_radius, theme_mod.stateLayer(container, cs.on_surface, alpha));
        }
    }
    // the outline (outlined variant)
    if (s.opts.variant == .outlined) {
        const oc: Color = if (!s.opts.enabled)
            ui.paint.withAlphaScaled(cs.on_surface, 0.12)
        else if (input.isFocused(n))
            cs.on_surface // FocusOutlineColor
        else
            cs.outline_variant;
        ui.paint.strokeRRect(ctx, b.x, b.y, b.w, b.h, card_radius, outline_w, oc);
    }
}

fn cardOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!isClickable(s)) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was_pressed = s.pressed;
            s.pressed = false;
            n.markDirty();
            if (was_pressed and n.bounds.contains(ev.x, ev.y)) {
                if (s.on_click) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .move => {
            // a drag past the touch slop cancels the press (a scroll); the
            // move is NOT claimed so it keeps bubbling to scrollables
            if (s.pressed) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = false;
                    n.markDirty();
                }
            }
            return false;
        },
        .outside_down => {
            s.pressed = false;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = true;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = false;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}

/// Keyboard activation: Enter/Space press the focused card.
fn cardOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!isClickable(s)) return false;
    if (ev.kind != .key_down) return false;
    switch (ev.key) {
        .enter, .space => {
            if (s.on_click) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        else => {},
    }
    return false;
}

fn cardDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(n));
}

const card_vtable = ui.node.VTable{
    .measure = cardMeasure,
    .layout = cardLayout,
    .paint = cardPaint,
    .deinit = cardDeinit,
    .on_pointer = cardOnPointer,
    .on_key = cardOnKey,
};

/// An M3E card. `on_click` = null → a plain container (role .group);
/// non-null → clickable (role .button, state layer, Enter/Space). Children
/// are document data: they stretch to the inner width and stack vertically.
pub fn card(allocator: std.mem.Allocator, on_click: ?Callback, opts: CardOptions) !*Node {
    const node = try Node.create(allocator, &card_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(CardState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .on_click = on_click };
    node.state = s;
    if (on_click != null) {
        ui.semantics.attach(node, .{
            .role = .button,
            .focusable = opts.enabled,
            .disabled = !opts.enabled,
            .actions = ui.semantics.Actions.initOne(.activate),
        }); // Phase 2c
    } else {
        ui.semantics.attach(node, .{ .role = .group }); // Phase 2c
    }
    return node;
}

// --- tests ---

fn clickCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "card: measures the children column + padding; stretches children to the inner width" {
    const a = std.testing.allocator;
    const c = try card(a, null, .{ .padding = ui.layout.EdgeInsets.all(16), .gap = 4 });
    defer c.deinit();
    c.add(try golden.solidBox(a, 100, 20, 0xFF0000FF));
    c.add(try golden.solidBox(a, 50, 20, 0x00FF00FF));
    const m = c.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 100 + 32), m.w); // max child + 16*2
    try std.testing.expectEqual(@as(f32, 20 + 4 + 20 + 32), m.h); // children + gap + padding
    c.layout(.{ .x = 10, .y = 20, .w = m.w, .h = m.h });
    // children stack with the gap, at the padded origin
    try std.testing.expectEqual(@as(f32, 10 + 16), c.children.items[0].bounds.x);
    try std.testing.expectEqual(@as(f32, 20 + 16), c.children.items[0].bounds.y);
    try std.testing.expectEqual(@as(f32, 20 + 16 + 20 + 4), c.children.items[1].bounds.y);
    // a wider layout stretches the children to the inner width
    c.layout(.{ .x = 10, .y = 20, .w = 200, .h = m.h });
    try std.testing.expectEqual(@as(f32, 200 - 32), c.children.items[0].bounds.w);
    try std.testing.expectEqual(@as(f32, 200 - 32), c.children.items[1].bounds.w);
}

test "card: click fires on_click; a drag past the slop cancels; disabled swallows; keyboard" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = clickCounterCb, .userdata = &count };
    const c = try card(std.testing.allocator, cb, .{});
    defer c.deinit();
    c.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    const on_pointer = c.vtable.on_pointer.?;
    _ = on_pointer(c, .{ .phase = .down, .x = 100, .y = 50, .raw_x = 100, .raw_y = 50 });
    _ = on_pointer(c, .{ .phase = .up, .x = 100, .y = 50, .raw_x = 100, .raw_y = 50 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // a drag past the slop cancels (a scroll, not a click)
    _ = on_pointer(c, .{ .phase = .down, .x = 100, .y = 50, .raw_x = 100, .raw_y = 50 });
    _ = on_pointer(c, .{ .phase = .move, .x = 100, .y = 80, .raw_x = 100, .raw_y = 80 });
    _ = on_pointer(c, .{ .phase = .up, .x = 100, .y = 50, .raw_x = 100, .raw_y = 50 });
    try std.testing.expectEqual(@as(u32, 1), count);
    // keyboard
    try std.testing.expect(c.vtable.on_key.?(c, .{ .kind = .key_down, .key = .enter }));
    try std.testing.expectEqual(@as(u32, 2), count);
    // a plain card (no on_click) handles no input
    const plain = try card(std.testing.allocator, null, .{});
    defer plain.deinit();
    plain.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try std.testing.expect(!plain.vtable.on_pointer.?(plain, .{ .phase = .down, .x = 100, .y = 50 }));
    // disabled swallows
    const dis = try card(std.testing.allocator, cb, .{ .enabled = false });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try std.testing.expect(!dis.vtable.on_pointer.?(dis, .{ .phase = .down, .x = 100, .y = 50 }));
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "card: semantics — clickable role button (focusable, activate); plain role group" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = clickCounterCb, .userdata = &count };
    const c = try card(std.testing.allocator, cb, .{});
    defer c.deinit();
    try std.testing.expectEqual(ui.semantics.Role.button, c.semantics.?.role);
    try std.testing.expect(c.semantics.?.focusable);
    try std.testing.expect(c.semantics.?.actions.contains(.activate));
    const plain = try card(std.testing.allocator, null, .{});
    defer plain.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, plain.semantics.?.role);
    try std.testing.expect(!plain.semantics.?.focusable);
    const dis = try card(std.testing.allocator, cb, .{ .enabled = false });
    defer dis.deinit();
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "golden: filled card paints the SurfaceContainerHighest container (rounded 12)" {
    const t = theme_mod.light;
    const c = try card(std.testing.allocator, null, .{ .variant = .filled, .theme = t });
    defer c.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 220, 120);
    defer r.deinit();
    c.layout(.{ .x = 20, .y = 20, .w = 180, .h = 80 });
    r.paint(c, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container fill, inside
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(110, 60));
    // the 12dp corner: the exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 20));
    // the edge mid-top: container (not background)
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(110, 20));
}

test "golden: outlined card strokes the OutlineVariant border over the Surface container" {
    const t = theme_mod.light;
    const c = try card(std.testing.allocator, null, .{ .variant = .outlined, .theme = t });
    defer c.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 220, 120);
    defer r.deinit();
    c.layout(.{ .x = 20, .y = 20.5, .w = 180, .h = 80 });
    r.paint(c, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge (half-pixel aligned): outline_variant
    try std.testing.expectEqual(t.colors.outline_variant, f.pixelAt(110, 20));
    // inside: the Surface container
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(110, 60));
}

test "golden: elevated card paints the SurfaceContainerLow container; disabled blends @0.38" {
    const t = theme_mod.light;
    const e = try card(std.testing.allocator, null, .{ .variant = .elevated, .theme = t });
    defer e.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 220, 120);
    defer r.deinit();
    e.layout(.{ .x = 20, .y = 20, .w = 180, .h = 80 });
    r.paint(e, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    try std.testing.expectEqual(t.colors.surface_container_low, f.pixelAt(110, 60));
    // disabled filled: surface_variant @ 0.38 over white
    const d = try card(std.testing.allocator, null, .{ .variant = .filled, .enabled = false, .theme = t });
    defer d.deinit();
    d.layout(.{ .x = 20, .y = 20, .w = 180, .h = 80 });
    r.paint(d, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try golden.expectPixelApprox(f2, 110, 60, golden.blendOver(ui.paint.withAlphaScaled(t.colors.surface_variant, 0.38), 0xFFFFFFFF));
}

test "golden: clickable card paints the on_surface state layer on hover" {
    const t = theme_mod.light;
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = clickCounterCb, .userdata = &count };
    const c = try card(std.testing.allocator, cb, .{ .variant = .filled, .theme = t });
    defer c.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 220, 120);
    defer r.deinit();
    c.layout(.{ .x = 20, .y = 20, .w = 180, .h = 80 });
    _ = c.vtable.on_pointer.?(c, .{ .phase = .enter, .x = 110, .y = 60 });
    r.paint(c, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // hover: on_surface @ 0.08 over surface_container_highest
    try golden.expectPixelApprox(f, 110, 60, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, t.state.hover), t.colors.surface_container_highest));
}
