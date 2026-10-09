// TextField (Phase 2d.2 PR C2, M3E) — the Material 3 Expressive text field:
// filled and outlined variants, single-line, with a floating label, optional
// leading/trailing icons, placeholder, supporting text, error + disabled
// states, and real text entry (the P0 input.zig machinery: a null-terminated
// buffer, text_input/backspace/enter/escape, a caret at the text end).
//
// Spec: m3.material.io/components/text-fields + Compose TextField.kt /
// TextFieldImpl.kt / TextFieldDefaults.kt / Filled+OutlinedTextFieldTokens:
//   - container height 56 (single line, with or without label); horizontal
//     padding 16 (TextFieldPadding); with-label vertical padding 8
//   - label expanded (unfocused + empty): body_large, vertically centered;
//     minimized (focused OR has text): body_small — filled: at the top inside
//     (y = 8); outlined: the line box centered ON the top edge (the cutout),
//     x = 16 (start padding, not the icon offset), 4dp patch padding
//   - text: filled at y = 24 when (label && minimized), else centered (16);
//     outlined always centered (the cutout label does not push the text)
//   - icons 24dp at the edges, vertically centered; the text/label offset is
//     16 without an icon, 24+4 = 28 with one (horizontalIconPadding = 12)
//   - supporting text: below the container, x = 16, y = 56+4, body_small
//   - shapes: filled = top corners 4 / bottom 0 (CornerExtraSmallTop);
//     outlined = 4 all corners (CornerExtraSmall)
//   - filled active indicator: the bottom line, full width, 1dp (2dp focused)
//   - outlined stroke: 1dp (2dp focused), centered on the edge
//   - colors (priority disabled > error > focused > hover > base): the
//     Filled/OutlinedTextFieldTokens values (container SurfaceContainerHighest,
//     indicator OnSurfaceVariant/OnSurface/Primary, outline
//     Outline/OnSurface/Primary, content OnSurface*, error roles, disabled
//     OnSurface@0.38 + container OnSurface@0.04 / outline OnSurface@0.12)
//
// The widget is a LEAF: the label, placeholder, input text, caret, icons and
// supporting text are all painted by the widget itself (their colors and
// positions change with focus — children would need a recolor on every focus
// change; paint-time computation needs none).
//
// v1 deviations (documented, fixed later):
//   - Single-line only. The label float is instant (Compose animates a
//     labelProgress lerp — the motion lands with the animation phase). The
//     caret is static (no blink), always at the text end (no selection, no
//     click-to-position). The outlined cutout is a surface-colored patch over
//     the stroke (assumes a surface-toned background; a true path gap lands
//     with Phase 3). No prefix/suffix, no character counter. RTL mirrors the
//     chrome; the text run itself stays LTR (no bidi — same as text.zig).
//     The caret is 1dp wide.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
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

pub const TextFieldVariant = enum { filled, outlined };

/// The registry's live text buffer (null-terminated invariant: the sentinel
/// sits at items[len] / buf[len] in the spare capacity).
pub const TextBuf = [256]u8;

pub const TextFieldOptions = struct {
    variant: TextFieldVariant = .outlined,
    enabled: bool = true,
    @"error": bool = false,
    label: []const u8 = "",
    placeholder: []const u8 = "",
    /// The initial text (used when no live signal is given).
    initial: []const u8 = "",
    leading_icon: ?icon_w.IconName = null,
    trailing_icon: ?icon_w.IconName = null,
    supporting: []const u8 = "",
    theme: Theme = theme_mod.light,
};

// --- M3E tokens (TextFieldImpl.kt paddings + the *TextFieldTokens) ---
const container_h: f32 = 56;
const h_padding: f32 = 16; // TextFieldPadding
const top_pad_label: f32 = 8; // TextFieldWithLabelVerticalPadding
const icon_size: f32 = 24;
const icon_gap: f32 = 4; // h_padding - horizontalIconPadding (16 - 12)
const corner: f32 = 4; // CornerExtraSmall (top corners for the filled)
const outline_w: f32 = 1;
const outline_w_focus: f32 = 2;
const caret_w: f32 = 1;
const cutout_pad: f32 = 4; // AboveLabelHorizontalPadding
const supporting_top: f32 = 4; // SupportingTopPadding
/// The outlined cutout label's paint overflow above the bounds: half the
/// body_small line box (8) + the focused stroke half (1) + the AA margin.
const cutout_overflow: f32 = 10;

const TextFieldState = struct {
    buf: std.array_list.Managed(u8), // kept null-terminated: items[len] == 0
    label: [:0]const u8, // owned
    placeholder: [:0]const u8, // owned
    supporting: [:0]const u8, // owned
    opts: TextFieldOptions,
    /// Live text mirror (registry/designer): the widget sets it on edit; an
    /// external set replaces the buffer (two-way).
    sig: ?*ui.state.Signal(TextBuf) = null,
    on_changed: ?Callback = null,
    on_submitted: ?Callback = null,
    hovered: bool = false,

    fn text(s: *TextFieldState) [:0]const u8 {
        // Sentinel slice via the many-item pointer (see input.zig).
        return s.buf.items.ptr[0..s.buf.items.len :0];
    }
};

fn stateOf(n: *Node) *TextFieldState {
    return @ptrCast(@alignCast(n.state.?));
}

/// Write the null sentinel at items[len] (the P0 TextField helper).
fn setSentinel(buf: *std.array_list.Managed(u8)) void {
    buf.items.len += 1;
    buf.items[buf.items.len - 1] = 0;
    buf.items.len -= 1;
}

/// A TextBuf from a string (truncated to capacity - 1, null-terminated).
pub fn bufFromText(str: []const u8) TextBuf {
    var buf = std.mem.zeroes(TextBuf);
    const n = @min(str.len, buf.len - 1);
    @memcpy(buf[0..n], str[0..n]);
    return buf;
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn hasLabel(s: *TextFieldState) bool {
    return s.label.len > 0;
}
fn hasSupporting(s: *TextFieldState) bool {
    return s.supporting.len > 0;
}
/// The label floats when the field is focused or holds text.
fn isMinimized(s: *TextFieldState, focused: bool) bool {
    return focused or s.buf.items.len > 0;
}
/// The horizontal offset of the text/label from the start edge.
fn leftOffset(s: *TextFieldState) f32 {
    return if (s.opts.leading_icon != null) icon_size + icon_gap else h_padding;
}
fn rightOffset(s: *TextFieldState) f32 {
    return if (s.opts.trailing_icon != null) icon_size + icon_gap else h_padding;
}

fn bodyLarge(t: Theme) theme_mod.TypeStyle {
    return t.type_scale.body_large;
}
fn bodySmall(t: Theme) theme_mod.TypeStyle {
    return t.type_scale.body_small;
}

/// The label's line box (expanded: body_large centered; minimized:
/// body_small at the top inside (filled) or straddling the top edge
/// (outlined cutout)). RTL-mirrored. null when there is no label.
pub fn labelRect(n: *Node) ?Rect {
    const s = stateOf(n);
    if (!hasLabel(s)) return null;
    const t = s.opts.theme;
    const b = n.bounds;
    const focused = input.isFocused(n);
    const rtl = ui.i18n.direction() == .rtl;
    const minimized = isMinimized(s, focused);
    const style = if (minimized) bodySmall(t) else bodyLarge(t);
    const w = ui.paint.measureText(s.label, style.size, false).width;
    var x: f32 = undefined;
    var y: f32 = undefined;
    if (minimized) {
        x = if (s.opts.variant == .outlined) b.x + h_padding else b.x + leftOffset(s);
        y = if (s.opts.variant == .outlined) b.y - style.line_height / 2 else b.y + top_pad_label;
    } else {
        x = b.x + leftOffset(s);
        y = b.y + (container_h - style.line_height) / 2;
    }
    if (rtl) x = b.x + b.w - (x - b.x) - w;
    return .{ .x = x, .y = y, .w = w, .h = style.line_height };
}

/// The input text's line box (the LTR anchor; the width is the content's).
/// The text sits below the floated label in the filled variant, centered
/// otherwise. Paint mirrors the anchor (with the run width) in RTL.
pub fn textRect(n: *Node) Rect {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const focused = input.isFocused(n);
    const line_h = bodyLarge(t).line_height;
    const y = if (s.opts.variant == .filled and hasLabel(s) and isMinimized(s, focused))
        b.y + top_pad_label + bodySmall(t).line_height
    else
        b.y + (container_h - line_h) / 2;
    return .{ .x = b.x + leftOffset(s), .y = y, .w = 0, .h = line_h };
}

/// The resolved colors for the current state (priority: disabled > error >
/// focused > hover > base — the *TextFieldTokens roles).
const FieldColors = struct {
    container: Color, // filled only (0 = transparent)
    indicator: Color, // the filled bottom line
    indicator_h: f32,
    outline: Color, // outlined only (0 = none)
    outline_w: f32,
    input: Color,
    label_expanded: Color,
    label_min: Color,
    placeholder: Color,
    icon_lead: Color,
    icon_trail: Color,
    supporting: Color,
    caret: Color,
    cutout: Color, // the outlined cutout patch = the surface behind the field
};

fn currentColors(s: *TextFieldState, focused: bool) FieldColors {
    const cs = s.opts.theme.colors;
    const filled = s.opts.variant == .filled;
    if (!s.opts.enabled) {
        const dis = ui.paint.withAlphaScaled(cs.on_surface, 0.38);
        return .{
            .container = if (filled) ui.paint.withAlphaScaled(cs.on_surface, 0.04) else 0,
            .indicator = ui.paint.withAlphaScaled(cs.on_surface, 0.38),
            .indicator_h = 1,
            .outline = if (!filled) ui.paint.withAlphaScaled(cs.on_surface, 0.12) else 0,
            .outline_w = 1,
            .input = dis,
            .label_expanded = dis,
            .label_min = dis,
            .placeholder = dis,
            .icon_lead = dis,
            .icon_trail = dis,
            .supporting = dis,
            .caret = dis,
            .cutout = cs.surface,
        };
    }
    if (s.opts.@"error") {
        return .{
            .container = if (filled) cs.surface_container_highest else 0,
            .indicator = cs.@"error",
            .indicator_h = if (focused) outline_w_focus else outline_w,
            .outline = if (!filled) cs.@"error" else 0,
            .outline_w = if (focused) outline_w_focus else outline_w,
            .input = cs.on_surface,
            .label_expanded = cs.@"error",
            .label_min = cs.@"error",
            .placeholder = cs.on_surface_variant,
            .icon_lead = cs.on_surface_variant, // ErrorLeadingIconColor = OnSurfaceVariant
            .icon_trail = cs.@"error",
            .supporting = cs.@"error",
            .caret = cs.@"error",
            .cutout = cs.surface,
        };
    }
    const hovered = s.hovered and !focused;
    return .{
        .container = if (filled) cs.surface_container_highest else 0,
        .indicator = if (focused) cs.primary else if (hovered) cs.on_surface else cs.on_surface_variant,
        .indicator_h = if (focused) outline_w_focus else outline_w,
        .outline = if (!filled) (if (focused) cs.primary else if (hovered) cs.on_surface else cs.outline) else 0,
        .outline_w = if (focused) outline_w_focus else outline_w,
        .input = cs.on_surface,
        .label_expanded = if (hovered) cs.on_surface else cs.on_surface_variant,
        .label_min = if (focused) cs.primary else cs.on_surface_variant,
        .placeholder = cs.on_surface_variant,
        .icon_lead = cs.on_surface_variant,
        .icon_trail = cs.on_surface_variant,
        .supporting = cs.on_surface_variant,
        .caret = cs.primary,
        .cutout = cs.surface,
    };
}

fn textFieldMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const str = if (s.buf.items.len > 0) s.text() else s.placeholder;
    const m = ui.paint.measureText(str, bodyLarge(t).size, false);
    const label_w = if (hasLabel(s)) ui.paint.measureText(s.label, bodyLarge(t).size, false).width else 0;
    const w = leftOffset(s) + @max(m.width, label_w) + rightOffset(s);
    const h = container_h + (if (hasSupporting(s)) supporting_top + bodySmall(t).line_height else 0);
    return c.constrain(.{ .w = w, .h = h });
}

fn textFieldLayout(n: *Node, bounds: Rect) void {
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

fn textFieldPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const t = s.opts.theme;
    const focused = input.isFocused(n) and s.opts.enabled;
    const fc = currentColors(s, focused);
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;

    // --- container ---
    if (s.opts.variant == .filled) {
        if (fc.container & 0xFF != 0) {
            // CornerExtraSmallTop: rounded top corners, square bottom
            ui.paint.fillRRectCorners(ctx, b.x, b.y, b.w, container_h, corner, corner, 0, 0, fc.container);
        }
        // the active indicator: the bottom line, full width
        if (fc.indicator & 0xFF != 0) {
            ui.paint.fillRect(ctx, b.x, b.y + container_h - fc.indicator_h, b.w, fc.indicator_h, fc.indicator);
        }
    } else {
        if (fc.outline & 0xFF != 0) {
            ui.paint.strokeRRect(ctx, b.x, b.y, b.w, container_h, corner, fc.outline_w, fc.outline);
        }
        // the cutout: a surface-colored patch over the stroke behind the
        // minimized label (v1: assumes a surface-toned background)
        if (fc.outline & 0xFF != 0 and hasLabel(s) and isMinimized(s, focused)) {
            const lr = labelRect(n).?;
            const patch_x = mx(b.x, b.w, lr.x - cutout_pad, lr.w + cutout_pad * 2, rtl);
            ui.paint.fillRect(ctx, patch_x, b.y - fc.outline_w / 2 - 0.5, lr.w + cutout_pad * 2, fc.outline_w + 1, fc.cutout);
        }
    }

    // --- icons (24dp at the edges, vertically centered) ---
    const icon_y = b.y + (container_h - icon_size) / 2;
    if (s.opts.leading_icon) |iname| {
        const ix = mx(b.x, b.w, b.x, icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_lead);
    }
    if (s.opts.trailing_icon) |iname| {
        const ix = mx(b.x, b.w, b.x + b.w - icon_size, icon_size, rtl);
        paintIcon(ctx, iname, ix, icon_y, fc.icon_trail);
    }

    // --- text content (clipped to the area between the icons) ---
    const tr = textRect(n);
    const clip_x = b.x + @min(leftOffset(s), rightOffset(s));
    const clip_w = b.w - leftOffset(s) - rightOffset(s);
    ui.paint.clipRect(ctx, clip_x, b.y, clip_w, container_h);
    if (s.buf.items.len > 0) {
        const style = bodyLarge(t);
        const m = ui.paint.measureText(s.text(), style.size, false);
        const tx = mx(b.x, b.w, tr.x, m.width, rtl);
        ui.paint.text(ctx, s.text(), tx, tr.y + m.ascent, style.size, false, fc.input);
        if (focused) {
            // the caret at the end of the text
            ui.paint.fillRect(ctx, tx + m.width, tr.y, caret_w, m.height, fc.caret);
        }
    } else if (focused or !hasLabel(s) or isMinimized(s, focused)) {
        // the placeholder shows when empty (hidden under the expanded label)
        if (s.placeholder.len > 0) {
            const style = bodyLarge(t);
            const m = ui.paint.measureText(s.placeholder, style.size, false);
            const tx = mx(b.x, b.w, tr.x, m.width, rtl);
            ui.paint.text(ctx, s.placeholder, tx, tr.y + m.ascent, style.size, false, fc.placeholder);
        }
        if (focused) {
            // the caret at the start (empty text)
            ui.paint.fillRect(ctx, tr.x, tr.y, caret_w, bodyLarge(t).line_height, fc.caret);
        }
    }
    ui.paint.clipReset(ctx);

    // --- label ---
    if (hasLabel(s)) {
        const lr = labelRect(n).?;
        const minimized = isMinimized(s, focused);
        const style = if (minimized) bodySmall(t) else bodyLarge(t);
        const m = ui.paint.measureText(s.label, style.size, false);
        ui.paint.text(ctx, s.label, lr.x, lr.y + m.ascent, style.size, false, if (minimized) fc.label_min else fc.label_expanded);
    }

    // --- supporting text (below the container) ---
    if (hasSupporting(s)) {
        const style = bodySmall(t);
        const m = ui.paint.measureText(s.supporting, style.size, false);
        const sx = mx(b.x, b.w, b.x + h_padding, m.width, rtl);
        ui.paint.text(ctx, s.supporting, sx, b.y + container_h + supporting_top + m.ascent, style.size, false, fc.supporting);
    }
}

fn textFieldOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.phase) {
        .down => {
            input.requestFocus(n);
            n.markDirty(); // the label float / caret / colors follow focus
            return true;
        },
        .up => return true,
        .move => return false, // a drag is a scroll, not a field interaction
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

/// An edit happened: re-layout (the measured width is content-driven),
/// repaint, sync the a11y value, mirror the signal, fire the callback.
fn applyEdit(n: *Node, s: *TextFieldState) void {
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows edits
    ui.semantics.notifyControlChanged(n); // a11y: the control's value changed
    if (s.sig) |sig| sig.set(bufFromText(s.buf.items)); // the live mirror
    if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
}

fn textFieldOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    switch (ev.kind) {
        .text_input => {
            s.buf.ensureTotalCapacity(s.buf.items.len + ev.text.len + 1) catch @panic("klaxon: out of memory");
            s.buf.appendSlice(ev.text) catch @panic("klaxon: out of memory");
            setSentinel(&s.buf);
            applyEdit(n, s);
            return true;
        },
        .key_down => switch (ev.key) {
            .backspace => {
                // Delete the last UTF-8 codepoint (continuation bytes first).
                while (s.buf.items.len > 0) {
                    const last = s.buf.items[s.buf.items.len - 1];
                    s.buf.items.len -= 1;
                    if ((last & 0xC0) != 0x80) break;
                }
                setSentinel(&s.buf);
                applyEdit(n, s);
                return true;
            },
            .enter => {
                if (s.on_submitted) |cb| cb.fn_ptr(cb.userdata);
                return true;
            },
            .escape => {
                input.requestFocus(null);
                n.markDirty();
                return true;
            },
            else => {},
        },
    }
    return false;
}

/// An external signal set (the designer): replace the buffer when the text
/// differs (the widget's own sets round-trip as no-ops — Signal.set dedups).
fn textFieldSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const incoming = s.sig.?.peek();
    const inc_len = std.mem.indexOfScalar(u8, &incoming, 0) orelse incoming.len;
    if (std.mem.eql(u8, s.buf.items, incoming[0..inc_len])) return;
    s.buf.clearRetainingCapacity();
    s.buf.appendSlice(incoming[0..inc_len]) catch @panic("klaxon: out of memory");
    setSentinel(&s.buf);
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows external edits
}

fn textFieldDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = textFieldSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.free(s.placeholder);
    n.allocator.free(s.supporting);
    s.buf.deinit();
    n.allocator.destroy(s);
}

const text_field_vtable = ui.node.VTable{
    .measure = textFieldMeasure,
    .layout = textFieldLayout,
    .paint = textFieldPaint,
    .deinit = textFieldDeinit,
    .on_pointer = textFieldOnPointer,
    .on_key = textFieldOnKey,
};

/// An M3E text field. `sig` = null → the text starts at `opts.initial`;
/// non-null → the text mirrors the signal both ways. `on_changed` fires on
/// every edit; `on_submitted` on Enter. The field is a leaf: it owns its text
/// buffer and paints all of its chrome.
pub fn textField(allocator: std.mem.Allocator, sig: ?*ui.state.Signal(TextBuf), on_changed: ?Callback, on_submitted: ?Callback, opts: TextFieldOptions) !*Node {
    const node = try Node.create(allocator, &text_field_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(TextFieldState);
    errdefer allocator.destroy(s);
    const label = try dupeZ(allocator, opts.label);
    errdefer allocator.free(label);
    const placeholder = try dupeZ(allocator, opts.placeholder);
    errdefer allocator.free(placeholder);
    const supporting = try dupeZ(allocator, opts.supporting);
    errdefer allocator.free(supporting);
    s.* = .{
        .buf = std.array_list.Managed(u8).init(allocator),
        .label = label,
        .placeholder = placeholder,
        .supporting = supporting,
        .opts = opts,
        .sig = sig,
        .on_changed = on_changed,
        .on_submitted = on_submitted,
    };
    errdefer {
        allocator.free(s.label);
        allocator.free(s.placeholder);
        allocator.free(s.supporting);
        s.buf.deinit();
    }
    const initial: []const u8 = if (sig) |sg| blk: {
        const v = sg.peek();
        break :blk v[0..(std.mem.indexOfScalar(u8, &v, 0) orelse v.len)];
    } else opts.initial;
    s.buf.ensureTotalCapacity(initial.len + 1) catch @panic("klaxon: out of memory");
    if (initial.len > 0) {
        s.buf.appendSlice(initial) catch @panic("klaxon: out of memory");
    }
    setSentinel(&s.buf); // null-terminates the (possibly empty) buffer
    node.state = s;
    ui.semantics.attach(node, .{
        .role = .text_field,
        .label = if (s.label.len > 0) s.label else s.placeholder,
        .hint = s.placeholder,
        .value = s.text(),
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
    }); // Phase 2c
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = textFieldSyncCb, .userdata = node } }); // external edits land in the buffer
    }
    // The outlined cutout label paints above the bounds (half its line box +
    // the stroke margin): markDirty must damage that overflow too.
    if (opts.variant == .outlined and opts.label.len > 0) {
        node.damage_overflow = .{ .top = cutout_overflow };
    }
    return node;
}

/// Current text field text — borrowed from the widget's buffer (valid until
/// the next edit or deinit).
pub fn text(n: *Node) [:0]const u8 {
    return stateOf(n).text();
}

/// Replace the text (the gallery restores entries across theme rebuilds).
pub fn setText(n: *Node, str: []const u8) void {
    const s = stateOf(n);
    s.buf.clearRetainingCapacity();
    s.buf.appendSlice(str) catch @panic("klaxon: out of memory");
    setSentinel(&s.buf);
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text();
    ui.semantics.notifyControlChanged(n);
    if (s.sig) |sig| sig.set(bufFromText(s.buf.items));
}

// --- tests ---

fn editCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "text_field: measures 56 tall (+20 with supporting text), content width + paddings" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .placeholder = "you@example.com", .theme = t });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(container_h, m.h);
    const pw = ui.paint.measureText("you@example.com", 16, false).width;
    const lw = ui.paint.measureText("Email", 16, false).width;
    try std.testing.expectApproxEqAbs(h_padding * 2 + @max(pw, lw), m.w, 0.001);
    // with supporting text: + 4 (top padding) + 16 (body_small line)
    const s = try textField(std.testing.allocator, null, null, null, .{ .supporting = "Helper", .theme = t });
    defer s.deinit();
    try std.testing.expectEqual(container_h + supporting_top + 16, s.measure(.{ .max_w = 2000, .max_h = 2000 }).h);
    // icons widen the field: 24 + 4 per side
    const ic = try textField(std.testing.allocator, null, null, null, .{ .leading_icon = .search, .trailing_icon = .close, .initial = "Hi", .theme = t });
    defer ic.deinit();
    const tw = ui.paint.measureText("Hi", 16, false).width;
    try std.testing.expectApproxEqAbs((icon_size + icon_gap) * 2 + tw, ic.measure(.{ .max_w = 2000, .max_h = 2000 }).w, 0.001);
}

test "text_field: the label floats on focus (expanded centered → minimized)" {
    // outlined: minimized = the line box straddling the top edge (the cutout)
    const o = try textField(std.testing.allocator, null, null, null, .{ .label = "Email" });
    defer o.deinit();
    o.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    var lr = labelRect(o).?;
    try std.testing.expectEqual(@as(f32, 16), lr.y); // (56-24)/2, expanded
    try std.testing.expectEqual(@as(f32, 24), lr.h); // body_large line
    try std.testing.expectEqual(@as(f32, 16), lr.x);
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(o);
    lr = labelRect(o).?;
    try std.testing.expectEqual(@as(f32, -8), lr.y); // 16/2 above the top edge
    try std.testing.expectEqual(@as(f32, 16), lr.h); // body_small line
    try std.testing.expectEqual(@as(f32, 16), lr.x); // the cutout aligns to the start padding
    router.focus(null);
    // filled: minimized = at the top INSIDE the field
    const f = try textField(std.testing.allocator, null, null, null, .{ .variant = .filled, .label = "Email", .initial = "x" });
    defer f.deinit();
    f.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    // has text → minimized even unfocused
    lr = labelRect(f).?;
    try std.testing.expectEqual(@as(f32, 8), lr.y); // top_pad_label
    try std.testing.expectEqual(@as(f32, 16), lr.x);
    // a leading icon offsets the expanded label too
    const ic = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .leading_icon = .search });
    defer ic.deinit();
    ic.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    try std.testing.expectEqual(icon_size + icon_gap, labelRect(ic).?.x);
    // no label → no label rect
    const nl = try textField(std.testing.allocator, null, null, null, .{});
    defer nl.deinit();
    try std.testing.expect(labelRect(nl) == null);
}

test "text_field: click focuses; typing appends; backspace/enter/escape; disabled swallows" {
    var changed: u32 = 0;
    var submitted: u32 = 0;
    const cb = Callback{ .fn_ptr = editCounterCb, .userdata = &changed };
    const sub = Callback{ .fn_ptr = editCounterCb, .userdata = &submitted };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try textField(std.testing.allocator, null, cb, sub, .{ .label = "Name" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    try std.testing.expect(!input.isFocused(b));
    // click → focus
    router.dispatchPointer(b, .{ .phase = .down, .x = 130, .y = 28 });
    try std.testing.expect(input.isFocused(b));
    // type
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Hi" });
    try std.testing.expectEqualStrings("Hi", text(b));
    try std.testing.expectEqual(@as(u32, 1), changed);
    try std.testing.expectEqualStrings("Hi", b.semantics.?.value); // a11y follows
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    try std.testing.expectEqualStrings("Hi!", text(b));
    // backspace deletes the last codepoint
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("Hi", text(b));
    try std.testing.expectEqual(@as(u32, 3), changed);
    // enter submits (no newline — single line)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), submitted);
    try std.testing.expectEqualStrings("Hi", text(b));
    // escape blurs
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!input.isFocused(b));
    // the label stays floated while the field holds text (minimized = focused
    // OR has text)
    try std.testing.expectEqual(@as(f32, -8), labelRect(b).?.y);
    // disabled: no focus, no edits
    const dis = try textField(std.testing.allocator, null, cb, sub, .{ .enabled = false, .initial = "Locked" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    router.dispatchPointer(dis, .{ .phase = .down, .x = 130, .y = 28 });
    try std.testing.expect(!input.isFocused(dis));
    try std.testing.expectEqualStrings("Locked", text(dis));
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "text_field: the signal mirrors the text both ways" {
    const sig = try ui.state.Signal(TextBuf).init(std.testing.allocator, bufFromText("Ada"));
    defer sig.deinit();
    const b = try textField(std.testing.allocator, sig, null, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    try std.testing.expectEqualStrings("Ada", text(b)); // initialized from the signal
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.dispatchPointer(b, .{ .phase = .down, .x = 130, .y = 28 });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const v = sig.peek();
    try std.testing.expectEqualStrings("Ada!", v[0..(std.mem.indexOfScalar(u8, &v, 0).?)]); // the widget sets the signal
    // an external set replaces the buffer
    sig.set(bufFromText("Bob"));
    try std.testing.expectEqualStrings("Bob", text(b));
    try std.testing.expectEqualStrings("Bob", b.semantics.?.value);
}

test "text_field: RTL mirrors the chrome (the label moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .leading_icon = .search });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 260, .h = 56 });
    const lr = labelRect(b).?;
    const lw = ui.paint.measureText("Email", 16, false).width;
    // mirrored: the label's END is at the end-side icon offset (the leading
    // icon moved to the end side)
    try std.testing.expectEqual(@as(f32, 260 - (icon_size + icon_gap) - lw), lr.x);
    const tr = textRect(b);
    try std.testing.expectEqual(icon_size + icon_gap, tr.x); // the LTR anchor (paint mirrors it)
}

test "golden: RTL paints the input text at the end side" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const m = ui.paint.measureText("Hi", 16, false);
    // the run is end-aligned: ink at the right side, none where LTR paints
    try std.testing.expect(f.countNotIn(.{ .x = 36, .y = 28, .w = m.width, .h = 24 }, 0xFFFFFFFF) == 0);
    try std.testing.expect(f.countNotIn(.{ .x = 280 - m.width, .y = 28, .w = m.width, .h = 24 }, 0xFFFFFFFF) > 0);
}

test "golden: outlined field strokes the 1dp outline, transparent inside, expanded label" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border, mid-edge (half-pixel aligned): outline
    try std.testing.expectEqual(t.colors.outline, f.pixelAt(150, 12));
    // inside, right of the label: transparent → the background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(150, 40));
    // the expanded label ink (on_surface_variant) in the centered band
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 28, .w = 100, .h = 24 }, t.colors.on_surface_variant) > 0);
}

test "golden: outlined focused field — 2dp primary outline + the cutout patch" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Email", .theme = t });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the focused outline: 2dp primary (band 11.5..13.5 → pixel 12 exact)
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(150, 12));
    // the cutout: no primary stroke in the patch's padding zone (left of the
    // label glyphs — the patch erased it); the stroke resumes right of the label
    const lw = ui.paint.measureText("Email", 12, false).width;
    try std.testing.expectEqual(@as(u64, 0), f.countColorIn(.{ .x = 32.5, .y = 12, .w = 3, .h = 1 }, t.colors.primary));
    try std.testing.expectEqual(t.colors.primary, f.pixelAt(200, 12));
    // the minimized label ink (primary, focused) straddles the top edge
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 4, .w = lw, .h = 18 }, t.colors.primary) > 0);
}

test "golden: filled field paints the container + the active indicator; focused doubles it" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .variant = .filled, .label = "Notes", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the container: surface_container_highest (inside, left of the label)
    try std.testing.expectEqual(t.colors.surface_container_highest, f.pixelAt(24, 30));
    // the square bottom corner: the indicator spans the full width
    try std.testing.expectEqual(t.colors.on_surface_variant, f.pixelAt(20, 67));
    // the rounded top corner: the exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 12));
    // focused: the indicator is 2dp primary
    var router = input.InputRouter{};
    input.setCurrent(&router);
    router.focus(b);
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(150, 66));
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(150, 67));
    input.setCurrent(null);
}

test "golden: error field paints the error outline + the error supporting text" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .@"error" = true, .label = "Username", .supporting = "Already taken", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 96);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 76 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the error outline
    try std.testing.expectEqual(t.colors.@"error", f.pixelAt(150, 12));
    // the supporting text ink (error) below the container
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 72, .w = 150, .h = 16 }, t.colors.@"error") > 0);
}

test "golden: disabled field paints the OnSurface@0.12 outline + @0.38 content" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .enabled = false, .label = "Email", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12.5, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the top border: on_surface @ 0.12 over white
    try golden.expectPixelApprox(f, 150, 12, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.12), 0xFFFFFFFF));
    // the label ink: on_surface @ 0.38 over white
    const dis_label = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), 0xFFFFFFFF);
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 28, .w = 100, .h = 24 }, dis_label) > 0);
}

test "golden: the caret paints at the end of the text when focused" {
    const t = theme_mod.light;
    const b = try textField(std.testing.allocator, null, null, null, .{ .label = "Name", .initial = "Hi", .theme = t });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    var r = try golden.Renderer.init(std.testing.allocator, 300, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 260, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const m = ui.paint.measureText("Hi", 16, false);
    const caret_x = 20 + 16 + m.width; // text_x + the text width
    const tr = textRect(b);
    // the caret band (primary ink) right after the text...
    try std.testing.expect(f.countNotIn(.{ .x = caret_x - 0.5, .y = tr.y + 2, .w = 2, .h = m.height - 4 }, 0xFFFFFFFF) > 0);
    // ...and nothing 4dp further right
    try std.testing.expectEqual(@as(u64, 0), f.countNotIn(.{ .x = caret_x + 4, .y = tr.y + 2, .w = 4, .h = m.height - 4 }, 0xFFFFFFFF));
}
