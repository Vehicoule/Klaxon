// ListItem (Phase 2d.3 PR D1, M3E) — the Material 3 Expressive list item:
// one / two / three lines, with an optional leading icon, overline, headline,
// supporting text, trailing icon or trailing text; selected + disabled
// states; clickable (state layer).
//
// Spec: m3.material.io/components/lists + Compose ListItem.kt + ListTokens:
//   - heights: one-line 56, two-line 72, three-line 88 (min heights — the
//     content is vertically centered; vertical padding 8, 12 for three-line)
//   - horizontal: start/end padding 16; the leading icon (24dp) at x=16,
//     16dp to the text (LeadingContentEndPadding); the trailing icon (24dp)
//     or trailing text 16dp from the end (ItemTrailingSpace),
//     TrailingContentStartPadding 16
//   - text column (stacked, no extra gaps — the line heights carry the
//     spacing): overline (label_small), headline (body_large), supporting
//     (body_medium)
//   - colors: headline OnSurface, supporting/overline/trailing-text
//     OnSurfaceVariant, icons OnSurfaceVariant; selected → the container
//     SecondaryContainer and every content color OnSecondaryContainer;
//     disabled → content OnSurface@0.38 (selected+disabled → the container
//     OnSurface@0.38)
//   - container: Surface (Level0); the clickable state layer = on_surface @
//     hover 0.08 / focus 0.10 / pressed 0.12 over the container
//   - shape: CornerNone (flat — the M3E hover/press morph to CornerLarge
//     lands with the Phase 3 motion)
//
// The widget is a LEAF (like the M3E text field): all of its chrome is
// painted by the widget itself (the colors/positions change with the
// selected state — paint-time computation needs no child recolor).
//
// v1 deviations (documented, fixed later):
//   - No M3E shape morph (CornerNone flat); no avatar/image/video leading
//     content (icon only); no segmented/reveal list variants; no text
//     wrapping (each line is a single run). RTL mirrors the chrome; the text
//     runs stay LTR (no bidi — same as text.zig).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ListItemLines = enum { one, two, three };

pub const ListItemOptions = struct {
    headline: []const u8 = "",
    supporting: []const u8 = "",
    overline: []const u8 = "",
    leading_icon: ?icon_w.IconName = null,
    trailing_icon: ?icon_w.IconName = null,
    /// A short trailing label (label_small, end side).
    trailing_text: []const u8 = "",
    lines: ListItemLines = .one,
    enabled: bool = true,
    /// The selected state (fixed when no signal is given — selection is
    /// EXTERNAL state: the click fires on_click, it does not flip).
    selected: bool = false,
    theme: Theme = theme_mod.light,
};

/// M3E tokens (ListTokens + ListItem.kt paddings).
const h_padding: f32 = 16; // ListItemStart/EndPadding
const icon_size: f32 = 24;
const icon_gap: f32 = 16; // LeadingContentEndPadding / TrailingContentStartPadding
const trailing_space: f32 = 16; // ItemTrailingSpace

const ListItemState = struct {
    headline: [:0]const u8, // owned
    supporting: [:0]const u8, // owned
    overline: [:0]const u8, // owned
    trailing_text: [:0]const u8, // owned
    opts: ListItemOptions,
    /// The selected state (read-only visual — the click does not flip it).
    sig: ?*ui.state.Signal(bool) = null,
    on_click: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
};

fn stateOf(n: *Node) *ListItemState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn isSelected(s: *ListItemState) bool {
    return if (s.sig) |sig| sig.peek() else s.opts.selected;
}

fn isClickable(s: *ListItemState) bool {
    return s.on_click != null and s.opts.enabled;
}

/// The min height per the lines option (ListTokens).
fn minHeight(s: *ListItemState) f32 {
    return switch (s.opts.lines) {
        .one => 56,
        .two => 72,
        .three => 88,
    };
}

fn hasOverline(s: *ListItemState) bool {
    return s.overline.len > 0;
}
fn hasSupporting(s: *ListItemState) bool {
    return s.supporting.len > 0;
}

/// The text column's height (the present lines' line heights, no gaps).
fn contentHeight(s: *ListItemState, t: Theme) f32 {
    var h: f32 = t.type_scale.body_large.line_height; // the headline always
    if (hasOverline(s)) h += t.type_scale.label_small.line_height;
    if (hasSupporting(s)) h += t.type_scale.body_medium.line_height;
    return h;
}

/// The resolved colors for the current state (selected > disabled > base).
const ItemColors = struct { container: Color, headline: Color, supporting: Color, overline: Color, icon: Color, trailing_text: Color, on: Color };

fn currentColors(s: *ListItemState) ItemColors {
    const cs = s.opts.theme.colors;
    const sel = isSelected(s);
    if (!s.opts.enabled) {
        const dis = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
        return .{
            .container = if (sel) ui.paint.withAlphaScaled(cs.on_surface, 0.38) else cs.surface,
            .headline = dis,
            .supporting = dis,
            .overline = dis,
            .icon = dis,
            .trailing_text = dis,
            .on = dis,
        };
    }
    return .{
        .container = if (sel) cs.secondary_container else cs.surface,
        .headline = if (sel) cs.on_secondary_container else cs.on_surface,
        .supporting = if (sel) cs.on_secondary_container else cs.on_surface_variant,
        .overline = if (sel) cs.on_secondary_container else cs.on_surface_variant,
        .icon = if (sel) cs.on_secondary_container else cs.on_surface_variant,
        .trailing_text = if (sel) cs.on_secondary_container else cs.on_surface_variant,
        .on = cs.on_surface,
    };
}

fn listItemMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    var text_w: f32 = 0;
    if (s.headline.len > 0) text_w = @max(text_w, ui.paint.measureText(s.headline, t.type_scale.body_large.size, false).width);
    if (hasSupporting(s)) text_w = @max(text_w, ui.paint.measureText(s.supporting, t.type_scale.body_medium.size, false).width);
    if (hasOverline(s)) text_w = @max(text_w, ui.paint.measureText(s.overline, t.type_scale.label_small.size, false).width);
    var w = h_padding + text_w + h_padding;
    if (s.opts.leading_icon != null) w += icon_size + icon_gap;
    if (s.opts.trailing_icon != null) w += icon_gap + icon_size + trailing_space;
    if (s.trailing_text.len > 0) {
        const tw = ui.paint.measureText(s.trailing_text, t.type_scale.label_small.size, false).width;
        w += icon_gap + tw + trailing_space;
    }
    return c.constrain(.{ .w = w, .h = @max(minHeight(s), contentHeight(s, t)) });
}

fn listItemLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: everything is positioned at paint time
}

/// Paint an icon glyph centered in a 24x24 box.
fn paintIcon(ctx: *kx.Ctx, name: ?icon_w.IconName, x: f32, y: f32, color: Color) void {
    const iname = name orelse return;
    if (color & 0xFF == 0) return;
    var gbuf: [4]u8 = .{ 0, 0, 0, 0 };
    const glen = std.unicode.utf8Encode(icon_w.codepoint(iname), &gbuf) catch return;
    const glyph: [:0]const u8 = gbuf[0..glen :0];
    const m = ui.paint.measureText(glyph, icon_size, false);
    const gx = x + (icon_size - m.width) / 2;
    const baseline = y + (icon_size - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, glyph, gx, baseline, icon_size, false, color);
}

fn listItemPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const t = s.opts.theme;
    const fc = currentColors(s);
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;

    // --- container ---
    if (fc.container & 0xFF != 0) {
        ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, fc.container);
    }
    // the state layer (clickable, enabled): on_surface over the container
    if (isClickable(s)) {
        const alpha: f32 = if (s.pressed)
            t.state.pressed
        else if (input.isFocused(n))
            t.state.focus
        else if (s.hovered)
            t.state.hover
        else
            0;
        if (alpha > 0) {
            ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, theme_mod.stateLayer(fc.container, fc.on, alpha));
        }
    }

    // --- the text column (centered vertically) ---
    const content_h = contentHeight(s, t);
    var y = b.y + (b.h - content_h) / 2;
    const text_x = mx(b.x, b.w, b.x + h_padding + (if (s.opts.leading_icon != null) icon_size + icon_gap else 0), 0, rtl);
    if (hasOverline(s)) {
        const style = t.type_scale.label_small;
        const m = ui.paint.measureText(s.overline, style.size, false);
        ui.paint.text(ctx, s.overline, mx(b.x, b.w, text_x, m.width, rtl), y + m.ascent, style.size, false, fc.overline);
        y += style.line_height;
    }
    {
        const style = t.type_scale.body_large;
        const m = ui.paint.measureText(s.headline, style.size, false);
        ui.paint.text(ctx, s.headline, mx(b.x, b.w, text_x, m.width, rtl), y + m.ascent, style.size, false, fc.headline);
        y += style.line_height;
    }
    if (hasSupporting(s)) {
        const style = t.type_scale.body_medium;
        const m = ui.paint.measureText(s.supporting, style.size, false);
        ui.paint.text(ctx, s.supporting, mx(b.x, b.w, text_x, m.width, rtl), y + m.ascent, style.size, false, fc.supporting);
    }

    // --- leading icon (start side, vertically centered) ---
    if (s.opts.leading_icon) |iname| {
        const ix = mx(b.x, b.w, b.x + h_padding, icon_size, rtl);
        paintIcon(ctx, iname, ix, b.y + (b.h - icon_size) / 2, fc.icon);
    }
    // --- trailing icon or trailing text (end side, vertically centered) ---
    if (s.opts.trailing_icon) |iname| {
        const ix = mx(b.x, b.w, b.x + b.w - trailing_space - icon_size, icon_size, rtl);
        paintIcon(ctx, iname, ix, b.y + (b.h - icon_size) / 2, fc.icon);
    }
    if (s.trailing_text.len > 0) {
        const style = t.type_scale.label_small;
        const m = ui.paint.measureText(s.trailing_text, style.size, false);
        const ty = b.y + (b.h - m.height) / 2 + m.ascent;
        const tx = mx(b.x, b.w, b.x + b.w - trailing_space - m.width, m.width, rtl);
        ui.paint.text(ctx, s.trailing_text, tx, ty, style.size, false, fc.trailing_text);
    }
}

fn listItemOnPointer(n: *Node, ev: input.PointerEvent) bool {
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
            // a drag past the touch slop cancels the press (a scroll)
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

/// Keyboard activation: Enter/Space press the focused list item.
fn listItemOnKey(n: *Node, ev: input.KeyEvent) bool {
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

/// The selected state changed externally: repaint + sync the a11y checked.
fn listItemSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (n.semantics) |sem| sem.checked = isSelected(s);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

fn listItemDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = listItemSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.free(s.headline);
    n.allocator.free(s.supporting);
    n.allocator.free(s.overline);
    n.allocator.free(s.trailing_text);
    n.allocator.destroy(s);
}

const list_item_vtable = ui.node.VTable{
    .measure = listItemMeasure,
    .layout = listItemLayout,
    .paint = listItemPaint,
    .deinit = listItemDeinit,
    .on_pointer = listItemOnPointer,
    .on_key = listItemOnKey,
};

/// An M3E list item. `sig` = null → the selected state is `opts.selected`
/// (fixed); non-null → the signal drives it (selection is external — the
/// click fires on_click, it does not flip). The widget is a leaf: it owns its
/// strings and paints all of its chrome.
pub fn listItem(allocator: std.mem.Allocator, sig: ?*ui.state.Signal(bool), on_click: ?Callback, opts: ListItemOptions) !*Node {
    const node = try Node.create(allocator, &list_item_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(ListItemState);
    errdefer allocator.destroy(s);
    const headline = try dupeZ(allocator, opts.headline);
    errdefer allocator.free(headline);
    const supporting = try dupeZ(allocator, opts.supporting);
    errdefer allocator.free(supporting);
    const overline = try dupeZ(allocator, opts.overline);
    errdefer allocator.free(overline);
    const trailing_text = try dupeZ(allocator, opts.trailing_text);
    errdefer allocator.free(trailing_text);
    s.* = .{
        .headline = headline,
        .supporting = supporting,
        .overline = overline,
        .trailing_text = trailing_text,
        .opts = opts,
        .sig = sig,
        .on_click = on_click,
    };
    errdefer {
        allocator.free(s.headline);
        allocator.free(s.supporting);
        allocator.free(s.overline);
        allocator.free(s.trailing_text);
    }
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .list_item,
        .label = s.headline,
        .focusable = opts.enabled and on_click != null,
        .disabled = !opts.enabled,
        .checked = isSelected(s),
    }); // Phase 2c
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = listItemSyncCb, .userdata = node } }); // the selected state follows the signal
    }
    return node;
}

// --- tests ---

fn clickCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "list_item: measures the per-lines min heights (56/72/88), content + paddings wide" {
    const t = theme_mod.light;
    const one = try listItem(std.testing.allocator, null, null, .{ .headline = "Title", .theme = t });
    defer one.deinit();
    try std.testing.expectEqual(@as(f32, 56), one.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    const two = try listItem(std.testing.allocator, null, null, .{ .headline = "Title", .supporting = "Sub", .lines = .two, .theme = t });
    defer two.deinit();
    try std.testing.expectEqual(@as(f32, 72), two.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    const three = try listItem(std.testing.allocator, null, null, .{ .headline = "Title", .supporting = "Sub", .overline = "Over", .lines = .three, .theme = t });
    defer three.deinit();
    try std.testing.expectEqual(@as(f32, 88), three.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    // width: 16 + headline + 16 (no icons)
    const hw = ui.paint.measureText("Title", 16, false).width;
    try std.testing.expectApproxEqAbs(h_padding * 2 + hw, one.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
    // with a leading + trailing icon: + 24 + 16 per side
    const ic = try listItem(std.testing.allocator, null, null, .{ .headline = "Title", .leading_icon = .star, .trailing_icon = .close, .theme = t });
    defer ic.deinit();
    try std.testing.expectApproxEqAbs(h_padding * 2 + hw + (icon_size + icon_gap) + (icon_gap + icon_size + trailing_space), ic.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
}

test "list_item: click fires on_click (selection is external); the signal drives the state" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = clickCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const li = try listItem(std.testing.allocator, sig, cb, .{ .headline = "Row" });
    defer li.deinit();
    li.layout(.{ .x = 0, .y = 0, .w = 300, .h = 56 });
    try std.testing.expectEqual(ui.semantics.Role.list_item, li.semantics.?.role);
    try std.testing.expectEqual(false, li.semantics.?.checked.?);
    // the click fires the callback but does NOT flip the selection
    _ = li.vtable.on_pointer.?(li, .{ .phase = .down, .x = 150, .y = 28, .raw_x = 150, .raw_y = 28 });
    _ = li.vtable.on_pointer.?(li, .{ .phase = .up, .x = 150, .y = 28, .raw_x = 150, .raw_y = 28 });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expect(!sig.peek());
    // the external signal drives the selected state + the a11y checked
    sig.set(true);
    try std.testing.expectEqual(true, li.semantics.?.checked.?);
    // keyboard
    try std.testing.expect(li.vtable.on_key.?(li, .{ .kind = .key_down, .key = .space }));
    try std.testing.expectEqual(@as(u32, 2), count);
    // a drag past the slop cancels
    _ = li.vtable.on_pointer.?(li, .{ .phase = .down, .x = 150, .y = 28, .raw_x = 150, .raw_y = 28 });
    _ = li.vtable.on_pointer.?(li, .{ .phase = .move, .x = 150, .y = 60, .raw_x = 150, .raw_y = 60 });
    _ = li.vtable.on_pointer.?(li, .{ .phase = .up, .x = 150, .y = 28, .raw_x = 150, .raw_y = 28 });
    try std.testing.expectEqual(@as(u32, 2), count);
    // disabled swallows
    const dis = try listItem(std.testing.allocator, null, cb, .{ .enabled = false, .headline = "x" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 300, .h = 56 });
    try std.testing.expect(!dis.vtable.on_pointer.?(dis, .{ .phase = .down, .x = 150, .y = 28 }));
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "golden: list item paints the Surface container + the headline ink (on_surface)" {
    const t = theme_mod.light;
    const li = try listItem(std.testing.allocator, null, null, .{ .headline = "Title", .theme = t });
    defer li.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 72);
    defer r.deinit();
    li.layout(.{ .x = 20, .y = 8, .w = 280, .h = 56 });
    r.paint(li, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: surface (the background is white — light surface is off-white)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(250, 36));
    // the headline ink (on_surface) in the text column
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 24, .w = 100, .h = 24 }, t.colors.on_surface) > 0);
}

test "golden: selected list item paints the SecondaryContainer + on_secondary content" {
    const t = theme_mod.light;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer sig.deinit();
    const li = try listItem(std.testing.allocator, sig, null, .{ .headline = "Title", .leading_icon = .star, .theme = t });
    defer li.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 72);
    defer r.deinit();
    li.layout(.{ .x = 20, .y = 8, .w = 280, .h = 56 });
    r.paint(li, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: secondary_container
    try std.testing.expectEqual(t.colors.secondary_container, f.pixelAt(250, 36));
    // the headline ink: on_secondary_container (not on_surface)
    try std.testing.expect(f.countColorIn(.{ .x = 76, .y = 24, .w = 100, .h = 24 }, t.colors.on_secondary_container) > 0);
    // the leading icon ink: on_secondary_container (the icon sits at x=36)
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 24, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}

test "golden: disabled list item paints the OnSurface@0.38 content over the Surface" {
    const t = theme_mod.light;
    const li = try listItem(std.testing.allocator, null, null, .{ .enabled = false, .headline = "Title", .theme = t });
    defer li.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 320, 72);
    defer r.deinit();
    li.layout(.{ .x = 20, .y = 8, .w = 280, .h = 56 });
    r.paint(li, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container stays surface
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(250, 36));
    // the headline ink: on_surface @ 0.38 over the surface
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.surface);
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 24, .w = 100, .h = 24 }, dis) > 0);
}
