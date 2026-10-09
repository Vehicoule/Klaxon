// SearchBar (Phase 2d.3 PR D4, M3E) — the Material 3 Expressive collapsed
// search bar: a 56dp SurfaceContainerHigh pill (CornerFull) with a leading
// search icon, a single-line text entry (body_large), a placeholder, and a
// trailing clear button shown while the text is non-empty. Real text entry
// (the P0 text-field machinery: a null-terminated buffer, text_input /
// backspace / enter / escape, a caret at the text end).
//
// Spec: m3.material.io/components/search-bar + Compose SearchBar.kt /
// TextFieldImpl.kt (the decorator layout) / SearchBarTokens:
//   - pill: height 56, CornerFull, SurfaceContainerHigh (focused too — the
//     inner text field's container color is Transparent; the pill is the
//     outer SearchBar container)
//   - width: sizeIn(min 360, max 720) — SearchBarMinWidth / MaxWidth
//   - layout (the TextFieldImpl decorator row + SearchBarIconOffsetX = 4):
//     the leading icon box is 48dp (minimumInteractiveComponentSize) at x=0
//     with the 24dp icon visual at 16..40 (centered 12 + 4 offset — "16dp
//     padding between icons and start/end"); the text starts at 48 + 4 = 52
//     (TextFieldPadding 16 - horizontalIconPadding 12); the trailing icon
//     box is 48dp at x=W-48 with the icon visual at W-40..W-16; the text
//     ends 4dp before the trailing box, 16dp from the edge without one
//   - text: body_large OnSurface; placeholder body_large OnSurfaceVariant;
//     caret 1dp Primary at the text end when focused
//   - trailing: a clear button (close icon, OnSurfaceVariant) iff the text
//     is non-empty; a click clears the text and keeps the focus
//   - state layers: OnSurface over the pill at hover 0.08 / pressed 0.12;
//     focus shows the caret only (v1 — the inset focus ring is a follow-up)
//   - disabled: content OnSurface @ 0.38, no focus/edits, container unchanged
//   - Enter fires on_submitted (imeAction = Search)
//
// The widget is a LEAF: the pill, icons, text, placeholder and caret are all
// painted by the widget itself (their colors/positions change with focus —
// paint-time computation needs no child recolor).
//
// v1 deviations (documented, fixed later):
//   - Collapsed pill only: the expanded full-screen view + suggestions
//     dropdown (SearchView), the avatar leading icon (30dp CornerFull),
//     prefix/suffix, and the inset focus ring (FocusIndicatorColor) are
//     follow-ups. The caret is static (no blink), always at the text end.
//     RTL mirrors the chrome; the text run itself stays LTR (no bidi).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const text_field_w = @import("text_field.zig"); // TextBuf + bufFromText
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// Re-exported so the registry/designer share one text-buffer type.
pub const TextBuf = text_field_w.TextBuf;
pub const bufFromText = text_field_w.bufFromText;

pub const SearchBarOptions = struct {
    enabled: bool = true,
    placeholder: []const u8 = "",
    /// The initial text (used when no live signal is given).
    initial: []const u8 = "",
    theme: Theme = theme_mod.light,
};

// --- M3E tokens (SearchBarTokens + the TextFieldImpl decorator paddings) ---
const container_h: f32 = 56; // ContainerHeight
const min_w: f32 = 360; // SearchBarMinWidth
const max_w: f32 = 720; // SearchBarMaxWidth
const icon_box: f32 = 48; // minimumInteractiveComponentSize
const icon_size: f32 = 24;
const icon_edge: f32 = 16; // the icon visual offset (12 centered + 4 offset)
const text_start: f32 = 52; // icon_box + (TextFieldPadding 16 - icon padding 12)
const text_gap_trail: f32 = 4; // the text's end padding before the icon box
const text_end_no_icon: f32 = 16; // TextFieldPadding without a trailing icon
const caret_w: f32 = 1;

const SearchBarState = struct {
    buf: std.array_list.Managed(u8), // kept null-terminated: items[len] == 0
    placeholder: [:0]const u8, // owned
    opts: SearchBarOptions,
    /// Live text mirror (registry/designer): the widget sets it on edit; an
    /// external set replaces the buffer (two-way).
    sig: ?*ui.state.Signal(TextBuf) = null,
    on_changed: ?Callback = null,
    on_submitted: ?Callback = null,
    hovered: bool = false,
    pressed: bool = false,
    clear_hovered: bool = false,
    clear_pressed: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,

    fn text(s: *SearchBarState) [:0]const u8 {
        // Sentinel slice via the many-item pointer (see input.zig).
        return s.buf.items.ptr[0..s.buf.items.len :0];
    }
};

fn stateOf(n: *Node) *SearchBarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// Write the null sentinel at items[len] (the P0 TextField helper).
fn setSentinel(buf: *std.array_list.Managed(u8)) void {
    buf.items.len += 1;
    buf.items[buf.items.len - 1] = 0;
    buf.items.len -= 1;
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

fn hasText(s: *SearchBarState) bool {
    return s.buf.items.len > 0;
}

/// The clear button's zone (the trailing 48dp min-interactive box), in the
/// widget's parent space. Only hot when the text is non-empty.
fn clearZone(b: Rect) Rect {
    return .{ .x = b.x + b.w - icon_box, .y = b.y, .w = icon_box, .h = container_h };
}

fn inClear(s: *SearchBarState, b: Rect, x: f32, y: f32) bool {
    if (!hasText(s)) return false;
    var z = clearZone(b);
    if (ui.i18n.direction() == .rtl) {
        z.x = b.x + b.w - (z.x - b.x) - z.w; // the zone mirrors to the start side
    }
    return x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h;
}

fn inPill(b: Rect, x: f32, y: f32) bool {
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + container_h;
}

/// The input text's line box (the LTR anchor; the width is the content's).
pub fn textRect(n: *Node) Rect {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const line_h = t.type_scale.body_large.line_height;
    return .{ .x = b.x + text_start, .y = b.y + (container_h - line_h) / 2, .w = 0, .h = line_h };
}

fn searchBarMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const t = s.opts.theme;
    const str = if (hasText(s)) s.text() else s.placeholder;
    const m = ui.paint.measureText(str, t.type_scale.body_large.size, false);
    const right = if (hasText(s)) icon_box + text_gap_trail else text_end_no_icon;
    const w = std.math.clamp(text_start + m.width + right, min_w, max_w);
    return c.constrain(.{ .w = w, .h = container_h });
}

fn searchBarLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: everything is positioned at paint time
}

/// Paint an icon glyph centered in a 24x24 box.
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    var gbuf: [4]u8 = .{ 0, 0, 0, 0 };
    const glen = std.unicode.utf8Encode(icon_w.codepoint(name), &gbuf) catch return;
    const glyph: [:0]const u8 = gbuf[0..glen :0];
    const m = ui.paint.measureText(glyph, icon_size, false);
    const gx = x + (icon_size - m.width) / 2;
    const baseline = y + (icon_size - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, glyph, gx, baseline, icon_size, false, color);
}

fn searchBarPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const b = n.bounds;
    const t = s.opts.theme;
    const cs = t.colors;
    const focused = input.isFocused(n) and s.opts.enabled;
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const radius = container_h / 2; // CornerFull

    // --- the pill ---
    const container = cs.surface_container_high;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, container_h, radius, container);
    // the state layer over the pill (enabled only)
    if (s.opts.enabled) {
        const alpha: f32 = if (s.pressed)
            t.state.pressed
        else if (s.hovered)
            t.state.hover
        else
            0;
        if (alpha > 0) {
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, container_h, radius, theme_mod.stateLayer(container, cs.on_surface, alpha));
        }
    }

    // --- content colors ---
    const content: Color = if (s.opts.enabled) cs.on_surface else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const muted: Color = if (s.opts.enabled) cs.on_surface_variant else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const caret: Color = if (s.opts.enabled) cs.primary else ui.paint.withAlphaScaled(cs.on_surface, 0.38);

    // --- the leading search icon (24dp at 16dp from the start edge) ---
    const icon_y = b.y + (container_h - icon_size) / 2;
    const lead_x = mx(b.x, b.w, b.x + icon_edge, icon_size, rtl);
    paintIcon(ctx, .search, lead_x, icon_y, content);

    // --- the clear button (the trailing 48dp box; shown iff text) ---
    if (hasText(s)) {
        const z = clearZone(b);
        const zx = mx(b.x, b.w, z.x, z.w, rtl);
        // the state layer over the clear zone (a 48x48 circle clipped to the pill)
        if (s.opts.enabled) {
            const alpha: f32 = if (s.clear_pressed)
                t.state.pressed
            else if (s.clear_hovered)
                t.state.hover
            else
                0;
            if (alpha > 0) {
                ui.paint.clipRect(ctx, b.x, b.y, b.w, container_h);
                ui.paint.fillRRect(ctx, zx, z.y + (container_h - icon_box) / 2, icon_box, icon_box, icon_box / 2, theme_mod.stateLayer(container, cs.on_surface_variant, alpha));
                ui.paint.clipReset(ctx);
            }
        }
        // the close icon visual at 16dp from the end edge
        const cx = mx(b.x, b.w, b.x + b.w - icon_edge - icon_size, icon_size, rtl);
        paintIcon(ctx, .close, cx, icon_y, muted);
    }

    // --- text content (clipped between the icons) ---
    const tr = textRect(n);
    const right = if (hasText(s)) icon_box + text_gap_trail else text_end_no_icon;
    const clip_x = mx(b.x, b.w, b.x + text_start, 0, rtl);
    const clip_w = b.w - text_start - right;
    ui.paint.clipRect(ctx, clip_x, b.y, clip_w, container_h);
    const style = t.type_scale.body_large;
    if (hasText(s)) {
        const m = ui.paint.measureText(s.text(), style.size, false);
        const tx = mx(b.x, b.w, tr.x, m.width, rtl);
        ui.paint.text(ctx, s.text(), tx, tr.y + m.ascent, style.size, false, content);
        if (focused) {
            // the caret at the end of the text
            ui.paint.fillRect(ctx, tx + m.width, tr.y, caret_w, m.height, caret);
        }
    } else {
        if (s.placeholder.len > 0) {
            const m = ui.paint.measureText(s.placeholder, style.size, false);
            const tx = mx(b.x, b.w, tr.x, m.width, rtl);
            ui.paint.text(ctx, s.placeholder, tx, tr.y + m.ascent, style.size, false, muted);
        }
        if (focused) {
            // the caret at the (mirrored) start (empty text)
            const caret_x = mx(b.x, b.w, tr.x, 0, rtl);
            ui.paint.fillRect(ctx, caret_x, tr.y, caret_w, style.line_height, caret);
        }
    }
    ui.paint.clipReset(ctx);
}

fn searchBarOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.enabled) return false;
    const b = n.bounds;
    const on_clear = inClear(s, b, ev.x, ev.y);
    switch (ev.phase) {
        .down => {
            if (on_clear) {
                s.clear_pressed = true;
            } else {
                s.pressed = true;
                input.requestFocus(n);
            }
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            n.markDirty();
            return true;
        },
        .up => {
            const was_clear = s.clear_pressed;
            const was_pressed = s.pressed;
            s.clear_pressed = false;
            s.pressed = false;
            n.markDirty();
            if (was_clear and on_clear) clearText(n, s);
            return was_clear or was_pressed;
        },
        .move => {
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.pressed or s.clear_pressed) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = false;
                    s.clear_pressed = false;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.pressed = false;
            s.clear_pressed = false;
            n.markDirty();
            return true;
        },
        .enter => {
            s.hovered = true;
            s.clear_hovered = on_clear;
            n.markDirty();
            return true;
        },
        // moving within the leaf emits hover_move (not enter/leave):
        // re-resolve the hover zones
        .hover_move => {
            const h = inPill(b, ev.x, ev.y);
            const ch = on_clear;
            if (h != s.hovered or ch != s.clear_hovered) {
                s.hovered = h;
                s.clear_hovered = ch;
                n.markDirty();
            }
            return true;
        },
        .leave => {
            s.hovered = false;
            s.clear_hovered = false;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// An edit happened: re-layout (the measured width is content-driven),
/// repaint, sync the a11y value, mirror the signal, fire the callback.
fn applyEdit(n: *Node, s: *SearchBarState) void {
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows edits
    ui.semantics.notifyControlChanged(n); // a11y: the control's value changed
    if (s.sig) |sig| sig.set(bufFromText(s.buf.items)); // the live mirror
    if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
}

/// Clear the text (the clear button): keep the focus, fire on_changed.
fn clearText(n: *Node, s: *SearchBarState) void {
    s.buf.clearRetainingCapacity();
    setSentinel(&s.buf);
    applyEdit(n, s);
}

fn searchBarOnKey(n: *Node, ev: input.KeyEvent) bool {
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
fn searchBarSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const incoming = s.sig.?.peek();
    const inc_len = std.mem.indexOfScalar(u8, &incoming, 0) orelse incoming.len;
    if (std.mem.eql(u8, s.buf.items, incoming[0..inc_len])) return;
    s.buf.clearRetainingCapacity();
    s.buf.appendSlice(incoming[0..inc_len]) catch @panic("klaxon: out of memory");
    setSentinel(&s.buf);
    n.markLayoutDirty();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows external edits
}

fn searchBarDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = searchBarSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.free(s.placeholder);
    s.buf.deinit();
    n.allocator.destroy(s);
}

const search_bar_vtable = ui.node.VTable{
    .measure = searchBarMeasure,
    .layout = searchBarLayout,
    .paint = searchBarPaint,
    .deinit = searchBarDeinit,
    .on_pointer = searchBarOnPointer,
    .on_key = searchBarOnKey,
};

/// An M3E collapsed search bar. `sig` = null → the text starts at
/// `opts.initial`; non-null → the text mirrors the signal both ways.
/// `on_changed` fires on every edit (including the clear button);
/// `on_submitted` on Enter. The bar is a leaf: it owns its text buffer and
/// paints all of its chrome.
pub fn searchBar(allocator: std.mem.Allocator, sig: ?*ui.state.Signal(TextBuf), on_changed: ?Callback, on_submitted: ?Callback, opts: SearchBarOptions) !*Node {
    const node = try Node.create(allocator, &search_bar_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(SearchBarState);
    errdefer allocator.destroy(s);
    const placeholder = try dupeZ(allocator, opts.placeholder);
    errdefer allocator.free(placeholder);
    s.* = .{
        .buf = std.array_list.Managed(u8).init(allocator),
        .placeholder = placeholder,
        .opts = opts,
        .sig = sig,
        .on_changed = on_changed,
        .on_submitted = on_submitted,
    };
    errdefer {
        allocator.free(s.placeholder);
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
        .label = s.placeholder,
        .hint = s.placeholder,
        .value = s.text(),
        .focusable = opts.enabled,
        .disabled = !opts.enabled,
    }); // Phase 2c
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = searchBarSyncCb, .userdata = node } }); // external edits land in the buffer
    }
    return node;
}

/// Current search bar text — borrowed from the widget's buffer (valid until
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

test "search_bar: measures 56 tall; width clamped to [360, 720]" {
    const t = theme_mod.light;
    const b = try searchBar(std.testing.allocator, null, null, null, .{ .placeholder = "Search", .theme = t });
    defer b.deinit();
    const m = b.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(container_h, m.h);
    // empty + short placeholder: the 360 min width wins
    try std.testing.expectEqual(min_w, m.w);
    // long content (non-empty → the clear button shows): 52 + text + 52
    const long = try searchBar(std.testing.allocator, null, null, null, .{ .initial = "a very long search query that overflows the minimum width for sure", .theme = t });
    defer long.deinit();
    const lw = ui.paint.measureText("a very long search query that overflows the minimum width for sure", 16, false).width;
    const mw = long.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@min(max_w, @max(min_w, text_start + lw + icon_box + text_gap_trail)), mw.w, 0.001);
    // with text the clear button adds the trailing box: 52 + text + 52
    const ic = try searchBar(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = t });
    defer ic.deinit();
    const iw = ic.measure(.{ .max_w = 2000, .max_h = 2000 }).w;
    const hw = ui.paint.measureText("Hi", 16, false).width;
    try std.testing.expectApproxEqAbs(@max(min_w, text_start + hw + icon_box + text_gap_trail), iw, 0.001);
}

test "search_bar: click focuses; typing appends; backspace/enter/escape; the clear button clears; disabled swallows" {
    var changed: u32 = 0;
    var submitted: u32 = 0;
    const cb = Callback{ .fn_ptr = editCounterCb, .userdata = &changed };
    const sub = Callback{ .fn_ptr = editCounterCb, .userdata = &submitted };
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const b = try searchBar(std.testing.allocator, null, cb, sub, .{ .placeholder = "Search" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 360, .h = 56 });
    try std.testing.expect(!input.isFocused(b));
    // click the pill → focus
    router.dispatchPointer(b, .{ .phase = .down, .x = 180, .y = 28, .raw_x = 180, .raw_y = 28 });
    try std.testing.expect(input.isFocused(b));
    // type
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Hi" });
    try std.testing.expectEqualStrings("Hi", text(b));
    try std.testing.expectEqual(@as(u32, 1), changed);
    try std.testing.expectEqualStrings("Hi", b.semantics.?.value); // a11y follows
    // the clear button's zone is the trailing 48dp box: click it
    const z = clearZone(b.bounds);
    router.dispatchPointer(b, .{ .phase = .down, .x = z.x + 24, .y = 28, .raw_x = z.x + 24, .raw_y = 28 });
    router.dispatchPointer(b, .{ .phase = .up, .x = z.x + 24, .y = 28, .raw_x = z.x + 24, .raw_y = 28 });
    try std.testing.expectEqualStrings("", text(b)); // cleared
    try std.testing.expectEqual(@as(u32, 2), changed); // on_changed fired
    try std.testing.expect(input.isFocused(b)); // the focus is kept
    // type again + backspace deletes the last codepoint
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Yo" });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("Y", text(b));
    // enter submits
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), submitted);
    // escape blurs
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!input.isFocused(b));
    // disabled: no focus, no edits, no clear
    const dis = try searchBar(std.testing.allocator, null, cb, sub, .{ .enabled = false, .initial = "Locked" });
    defer dis.deinit();
    dis.layout(.{ .x = 0, .y = 0, .w = 360, .h = 56 });
    router.dispatchPointer(dis, .{ .phase = .down, .x = 180, .y = 28, .raw_x = 180, .raw_y = 28 });
    try std.testing.expect(!input.isFocused(dis));
    try std.testing.expectEqualStrings("Locked", text(dis));
    const dz = clearZone(dis.bounds);
    router.dispatchPointer(dis, .{ .phase = .down, .x = dz.x + 24, .y = 28, .raw_x = dz.x + 24, .raw_y = 28 });
    router.dispatchPointer(dis, .{ .phase = .up, .x = dz.x + 24, .y = 28, .raw_x = dz.x + 24, .raw_y = 28 });
    try std.testing.expectEqualStrings("Locked", text(dis)); // not cleared
    try std.testing.expect(!dis.semantics.?.focusable);
    try std.testing.expect(dis.semantics.?.disabled);
}

test "search_bar: the signal mirrors the text both ways" {
    const sig = try ui.state.Signal(TextBuf).init(std.testing.allocator, bufFromText("Ada"));
    defer sig.deinit();
    const b = try searchBar(std.testing.allocator, sig, null, null, .{});
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 360, .h = 56 });
    try std.testing.expectEqualStrings("Ada", text(b)); // initialized from the signal
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.dispatchPointer(b, .{ .phase = .down, .x = 180, .y = 28, .raw_x = 180, .raw_y = 28 });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const v = sig.peek();
    try std.testing.expectEqualStrings("Ada!", v[0..(std.mem.indexOfScalar(u8, &v, 0).?)]); // the widget sets the signal
    // an external set replaces the buffer
    sig.set(bufFromText("Bob"));
    try std.testing.expectEqualStrings("Bob", text(b));
    try std.testing.expectEqualStrings("Bob", b.semantics.?.value);
}

test "search_bar: RTL mirrors the chrome (the search icon moves to the end side)" {
    const i18n = try ui.i18n.I18n.init(std.testing.allocator, "en");
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\":\"y\"}", .rtl);
    ui.i18n.setCurrent(i18n);
    defer ui.i18n.setCurrent(null);
    try i18n.setLocale("ar");
    const b = try searchBar(std.testing.allocator, null, null, null, .{ .initial = "Hi" });
    defer b.deinit();
    b.layout(.{ .x = 0, .y = 0, .w = 360, .h = 56 });
    // the clear zone moved to the START side (mirrored)
    try std.testing.expect(inClear(stateOf(b), b.bounds, icon_box / 2, 28));
    try std.testing.expect(!inClear(stateOf(b), b.bounds, 360 - icon_box / 2, 28));
    // the LTR anchor is unchanged (the paint mirrors it)
    try std.testing.expectEqual(text_start, textRect(b).x);
}

test "golden: the pill paints SurfaceContainerHigh with rounded ends; the search icon + placeholder ink" {
    const t = theme_mod.light;
    const b = try searchBar(std.testing.allocator, null, null, null, .{ .placeholder = "Search songs", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 420, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 380, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the pill's middle: surface_container_high
    try std.testing.expectEqual(t.colors.surface_container_high, f.pixelAt(200, 40));
    // the rounded end: the exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 12));
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 67));
    // the leading search icon ink (on_surface) at 16..40
    try std.testing.expect(f.countColorIn(.{ .x = 36, .y = 28, .w = 24, .h = 24 }, t.colors.on_surface) > 0);
    // the placeholder ink (on_surface_variant) right of the icon
    try std.testing.expect(f.countColorIn(.{ .x = 72, .y = 28, .w = 120, .h = 24 }, t.colors.on_surface_variant) > 0);
    // no clear button when empty: the trailing box is plain pill
    try std.testing.expectEqual(t.colors.surface_container_high, f.pixelAt(380, 40));
}

test "golden: with text, the input text + caret + clear button paint; hover layers the pill" {
    const t = theme_mod.light;
    const b = try searchBar(std.testing.allocator, null, null, null, .{ .initial = "Hi", .theme = t });
    defer b.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    router.focus(b);
    var r = try golden.Renderer.init(std.testing.allocator, 420, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 380, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the input text ink (on_surface) at x = 20 + 52
    const m = ui.paint.measureText("Hi", 16, false);
    try std.testing.expect(f.countColorIn(.{ .x = 72, .y = 28, .w = m.width, .h = 24 }, t.colors.on_surface) > 0);
    // the caret at the text end: a 1dp bar (AA'd at the fractional text
    // end) — assert non-pill ink in the band right of the last glyph
    const caret_band = Rect{ .x = @floor(72 + m.width), .y = 28, .w = 2, .h = 24 };
    try std.testing.expect(f.countNotIn(caret_band, t.colors.surface_container_high) > 0);
    // the clear button ink (on_surface_variant) at 16dp from the end edge
    // (the icon visual spans x = 20 + 380 - 40 = 360 .. 384)
    try std.testing.expect(f.countColorIn(.{ .x = 360, .y = 28, .w = 24, .h = 24 }, t.colors.on_surface_variant) > 0);
    // hover the pill (not the clear zone): the state layer blends over the pill
    _ = b.vtable.on_pointer.?(b, .{ .phase = .enter, .x = 200, .y = 40 });
    r.paint(b, 0xFFFFFFFF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try golden.expectPixelApprox(f2, 200, 40, golden.blendOver(theme_mod.stateLayer(t.colors.surface_container_high, t.colors.on_surface, t.state.hover), 0xFFFFFFFF));
}

test "golden: disabled paints the OnSurface@0.38 content" {
    const t = theme_mod.light;
    const b = try searchBar(std.testing.allocator, null, null, null, .{ .enabled = false, .initial = "Hi", .theme = t });
    defer b.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 420, 80);
    defer r.deinit();
    b.layout(.{ .x = 20, .y = 12, .w = 380, .h = 56 });
    r.paint(b, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the pill keeps its container color
    try std.testing.expectEqual(t.colors.surface_container_high, f.pixelAt(200, 40));
    // the text ink: on_surface @ 0.38 over the pill (Skia's blend rounding
    // differs ±1 from blendOver — count approx)
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.surface_container_high);
    try std.testing.expect(f.countColorApproxIn(.{ .x = 72, .y = 28, .w = 60, .h = 24 }, dis) > 0);
}
