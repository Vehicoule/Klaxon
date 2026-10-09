// Menu (Phase 2d.3 PR D2, M3E) — the Material 3 Expressive dropdown menu:
// an anchor + a popup panel of item rows, opened/closed by a signal, with
// hover/pressed/highlight state layers and keyboard navigation.
//
// Spec: m3.material.io/components/menus + Compose Menu.kt / MenuDefaults.kt /
// MenuTokens (the M3E menu item IS a list item with menu colors):
//   - panel: SurfaceContainer, radius 4 (CornerExtraSmall), vertical padding
//     8 (DropdownMenuVerticalPadding); flat in v1 (Level2 — Phase 3)
//   - item rows: height 48 (MenuListItemContainerHeight), horizontal padding
//     12 (DropdownMenuItemHorizontalPadding), leading icon 24dp at x=12 +
//     16dp to the label (LeadingContentEndPadding), trailing text (label_small)
//     8dp before the end padding; label body_large
//   - colors: label OnSurface; the leading icon OnSecondaryContainer (the
//     menu quirk — MenuListItemLeadingIconColor); trailing text
//     OnSurfaceVariant; the state layer = on_surface @ hover 0.08 /
//     focus 0.10 / pressed 0.12 over the panel; disabled items OnSurface@0.38
//   - position: below the anchor, start-aligned, intrinsic width (the widest
//     item); clamped to the parent width
//
// The menu is a wrapper: the anchor is a document child (it sizes the menu);
// the item rows are internal chrome overlaying below the anchor (the P0
// dropdown pattern: hidden children + the router's open-popup barrier closes
// the menu on an outside click). On open the menu takes the keyboard focus
// (arrow/enter/escape navigation) and restores it on close.
//
// v1 deviations (documented, fixed later):
//   - Flat panel (no Level2 shadow — Phase 3); no submenus, no checkable
//     items, no group labels/dividers; no scroll for long menus; no M3E shape
//     morph. RTL mirrors the panel and the item rows (the text runs stay LTR
//     — no bidi, same as text.zig).
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

/// A menu item (the factory copies the strings).
pub const MenuItem = struct {
    label: []const u8,
    leading_icon: ?icon_w.IconName = null,
    trailing_text: []const u8 = "",
    enabled: bool = true,
};

pub const MenuOptions = struct {
    theme: Theme = theme_mod.light,
};

/// M3E tokens (MenuTokens + Menu.kt/MenuDefaults.kt).
const item_h: f32 = 48; // MenuListItemContainerHeight
const item_h_pad: f32 = 12; // DropdownMenuItemHorizontalPadding
const icon_size: f32 = 24;
const icon_gap: f32 = 16; // LeadingContentEndPadding
const trail_gap: f32 = 8;
const panel_v_pad: f32 = 8; // DropdownMenuVerticalPadding
const panel_radius: f32 = 4; // CornerExtraSmall

const ItemDef = struct {
    label: [:0]const u8, // owned
    leading_icon: ?icon_w.IconName,
    trailing_text: [:0]const u8, // owned
    enabled: bool,
};

const MenuState = struct {
    items: std.array_list.Managed(ItemDef), // owned defs
    anchor: *Node, // the anchor child (document data — sizes the menu)
    opts: MenuOptions,
    sig: ?*ui.state.Signal(bool) = null,
    on_select: ?Callback = null,
    open: bool = false,
    /// The hovered/highlighted item (-1 = none; keyboard nav moves it too).
    highlight: i32 = -1,
    pressed_index: i32 = -1,
    /// The last selected index (pub accessor `selectedIndex`).
    selected: usize = 0,
    /// The focus to restore on close.
    prev_focus: ?*Node = null,
};

fn stateOf(n: *Node) *MenuState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// The panel width: the widest item's content + paddings.
fn panelWidth(s: *MenuState, t: Theme) f32 {
    var w: f32 = 0;
    for (s.items.items) |def| {
        var cw = item_h_pad * 2 + ui.paint.measureText(def.label, t.type_scale.body_large.size, false).width;
        if (def.leading_icon != null) cw += icon_size + icon_gap;
        if (def.trailing_text.len > 0) cw += trail_gap + ui.paint.measureText(def.trailing_text, t.type_scale.label_small.size, false).width;
        w = @max(w, cw);
    }
    return w;
}

/// Damage covers the anchor AND the item rows: the panel paints below the
/// menu's bounds (overflow), so the dirty-rect clip must include it for the
/// panel to appear (open) and disappear (close).
fn markMenuDirty(n: *Node) void {
    var region = n.bounds;
    for (n.children.items) |child| region = ui.node.rectUnion(region, child.bounds);
    n.markDirtyRect(region);
}

/// Apply the open state (the single transition path — the signal and the
/// programmatic setOpen both land here).
fn applyOpen(n: *Node, s: *MenuState, open: bool) void {
    if (s.open == open) return;
    s.open = open;
    for (n.children.items[1..]) |child| child.visible = open; // [0] = anchor
    s.highlight = -1;
    s.pressed_index = -1;
    markMenuDirty(n);
    if (open) {
        input.setOpenPopup(n); // the router's barrier closes on outside clicks
        // take the keyboard focus (arrow/enter/escape), restore it on close
        if (input.current()) |r| s.prev_focus = r.focused;
        input.requestFocus(n);
    } else {
        input.setOpenPopup(null);
        input.requestFocus(s.prev_focus);
        s.prev_focus = null;
    }
}

fn menuSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyOpen(n, s, s.sig.?.peek());
}

/// Open/close the menu (the pub API without a signal; with one, this sets
/// the signal — the sync callback applies the transition).
pub fn setOpen(n: *Node, open: bool) void {
    const s = stateOf(n);
    if (s.sig) |sig| {
        sig.set(open);
    } else {
        applyOpen(n, s, open);
    }
}

pub fn isOpen(n: *Node) bool {
    return stateOf(n).open;
}

/// The last selected item's index (valid after a selection).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

fn menuSelect(owner: *Node, index: usize) void {
    const s = stateOf(owner);
    if (index >= s.items.items.len) return;
    if (!s.items.items[index].enabled) return;
    s.selected = index;
    if (owner.semantics) |sem| {
        sem.value = s.items.items[index].label; // a11y: the value follows the selection
        ui.semantics.notifyControlChanged(owner);
    }
    setOpen(owner, false);
    if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
}

// --- menu item row (internal chrome child) ---

const ItemState = struct {
    def_index: usize,
    owner: *Node,
};

fn itemStateOf(n: *Node) *ItemState {
    return @ptrCast(@alignCast(n.state.?));
}

fn itemMeasure(n: *Node, c: Constraints) Size {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const t = ms.opts.theme;
    const def = ms.items.items[s.def_index];
    var w = item_h_pad * 2 + ui.paint.measureText(def.label, t.type_scale.body_large.size, false).width;
    if (def.leading_icon != null) w += icon_size + icon_gap;
    if (def.trailing_text.len > 0) w += trail_gap + ui.paint.measureText(def.trailing_text, t.type_scale.label_small.size, false).width;
    return c.constrain(.{ .w = w, .h = item_h });
}

fn itemLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf
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

fn itemPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const t = ms.opts.theme;
    const cs = t.colors;
    const def = ms.items.items[s.def_index];
    const b = n.bounds;
    const rtl = ui.i18n.direction() == .rtl;
    const mx = struct {
        fn f(bx: f32, bw: f32, x: f32, w: f32, rtl_flag: bool) f32 {
            return if (rtl_flag) bx + bw - (x - bx) - w else x;
        }
    }.f;
    const label_col = if (def.enabled) cs.on_surface else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const icon_col = if (def.enabled) cs.on_secondary_container else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    const trail_col = if (def.enabled) cs.on_surface_variant else ui.paint.withAlphaScaled(cs.on_surface, 0.38);
    // the state layer (enabled only): pressed > highlight (focus when the menu
    // holds the keyboard focus, hover otherwise)
    if (def.enabled) {
        const alpha: f32 = if (ms.pressed_index == @as(i32, @intCast(s.def_index)))
            t.state.pressed
        else if (ms.highlight == @as(i32, @intCast(s.def_index)))
            if (input.isFocused(s.owner)) t.state.focus else t.state.hover
        else
            0;
        if (alpha > 0) {
            ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, theme_mod.stateLayer(cs.surface_container, cs.on_surface, alpha));
        }
    }
    // the label (vertically centered)
    const lm = ui.paint.measureText(def.label, t.type_scale.body_large.size, false);
    const label_x = b.x + item_h_pad + (if (def.leading_icon != null) icon_size + icon_gap else 0);
    const label_y = b.y + (b.h - lm.height) / 2 + lm.ascent;
    ui.paint.text(ctx, def.label, mx(b.x, b.w, label_x, lm.width, rtl), label_y, t.type_scale.body_large.size, false, label_col);
    // the leading icon (start side, vertically centered)
    if (def.leading_icon) |iname| {
        const ix = mx(b.x, b.w, b.x + item_h_pad, icon_size, rtl);
        paintIcon(ctx, iname, ix, b.y + (b.h - icon_size) / 2, icon_col);
    }
    // the trailing text (end side, vertically centered)
    if (def.trailing_text.len > 0) {
        const tm = ui.paint.measureText(def.trailing_text, t.type_scale.label_small.size, false);
        const ty = b.y + (b.h - tm.height) / 2 + tm.ascent;
        const tx = mx(b.x, b.w, b.x + b.w - item_h_pad - tm.width, tm.width, rtl);
        ui.paint.text(ctx, def.trailing_text, tx, ty, t.type_scale.label_small.size, false, trail_col);
    }
}

fn itemOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = itemStateOf(n);
    const ms = stateOf(s.owner);
    const def = ms.items.items[s.def_index];
    if (!def.enabled) return false;
    const idx: i32 = @intCast(s.def_index);
    switch (ev.phase) {
        .enter => {
            ms.highlight = idx;
            markMenuDirty(s.owner);
            return true;
        },
        .leave => {
            if (ms.highlight == idx) ms.highlight = -1;
            markMenuDirty(s.owner);
            return true;
        },
        .down => {
            ms.pressed_index = idx;
            markMenuDirty(s.owner);
            return true;
        },
        .up => {
            const was = ms.pressed_index == idx;
            ms.pressed_index = -1;
            if (was and n.bounds.contains(ev.x, ev.y)) {
                menuSelect(s.owner, s.def_index);
            } else {
                markMenuDirty(s.owner);
            }
            return true;
        },
        else => {},
    }
    return false;
}

fn itemDeinit(n: *Node) void {
    n.allocator.destroy(itemStateOf(n));
}

const item_vtable = ui.node.VTable{
    .measure = itemMeasure,
    .layout = itemLayout,
    .paint = itemPaint,
    .deinit = itemDeinit,
    .on_pointer = itemOnPointer,
};

// --- the menu widget ---

fn menuMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    return s.anchor.measure(c); // the items are overlay chrome (not measured)
}

fn menuLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    // the anchor fills the menu's bounds (the menu sizes to the anchor)
    s.anchor.layout(bounds);
    // the panel overlays below the anchor, start-aligned, intrinsic width
    const pw = panelWidth(s, t);
    const rtl = ui.i18n.direction() == .rtl;
    const px = if (rtl) bounds.x + bounds.w - pw else bounds.x;
    const py = bounds.y + bounds.h + panel_v_pad;
    for (n.children.items[1..], 0..) |child, i| {
        child.layout(.{
            .x = px,
            .y = py + @as(f32, @floatFromInt(i)) * item_h,
            .w = pw,
            .h = item_h,
        });
    }
}

fn menuPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    if (!s.open) return;
    const t = s.opts.theme;
    const b = n.bounds;
    const pw = panelWidth(s, t);
    const ph = panel_v_pad * 2 + @as(f32, @floatFromInt(s.items.items.len)) * item_h;
    const rtl = ui.i18n.direction() == .rtl;
    const px = if (rtl) b.x + b.w - pw else b.x;
    ui.paint.fillRRect(ctx, px, b.y + b.h, pw, ph, panel_radius, t.colors.surface_container);
}

fn menuOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (ev.phase == .outside_down and s.open) {
        setOpen(n, false); // the router's barrier sends this on outside clicks
        return true;
    }
    return false;
}

/// Keyboard navigation while open: up/down move the highlight (skipping
/// disabled items), Enter selects it, Escape closes.
fn menuOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.open) return false;
    if (ev.kind != .key_down) return false;
    const count: i32 = @intCast(s.items.items.len);
    switch (ev.key) {
        .up, .down => {
            if (count == 0) return true;
            const step: i32 = if (ev.key == .down) 1 else -1;
            var i: i32 = if (s.highlight < 0) (if (step > 0) -1 else count) else s.highlight;
            var guard: i32 = 0;
            while (guard < count) : (guard += 1) {
                i = @mod(i + step, count);
                if (s.items.items[@intCast(i)].enabled) break;
            }
            s.highlight = i;
            markMenuDirty(n);
            return true;
        },
        .enter => {
            if (s.highlight >= 0) menuSelect(n, @intCast(s.highlight));
            return true;
        },
        .escape => {
            setOpen(n, false);
            return true;
        },
        else => {},
    }
    return false;
}

fn menuDeinit(n: *Node) void {
    const s = stateOf(n);
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = menuSyncCb, .userdata = n } });
    input.releaseNode(n);
    if (s.open) input.setOpenPopup(null);
    for (s.items.items) |*def| {
        n.allocator.free(def.label);
        n.allocator.free(def.trailing_text);
    }
    s.items.deinit();
    n.allocator.destroy(s);
}

const menu_vtable = ui.node.VTable{
    .measure = menuMeasure,
    .layout = menuLayout,
    .paint = menuPaint,
    .deinit = menuDeinit,
    .on_pointer = menuOnPointer,
    .on_key = menuOnKey,
};

/// An M3E dropdown menu. `anchor` is a document child (it sizes the menu and
/// keeps its own interaction — the app opens the menu via the signal or
/// `setOpen`). `items` are copied (the labels/texts are owned). `sig` drives
/// the open state (round-trips); `on_select` fires with `selectedIndex(n)`
/// valid. The item rows are internal chrome (skip_children for the registry).
pub fn menu(allocator: std.mem.Allocator, anchor: *Node, items: []const MenuItem, sig: ?*ui.state.Signal(bool), on_select: ?Callback, opts: MenuOptions) !*Node {
    const node = try Node.create(allocator, &menu_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(MenuState);
    errdefer allocator.destroy(s);
    s.* = .{
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .anchor = anchor,
        .opts = opts,
        .sig = sig,
        .on_select = on_select,
    };
    errdefer s.items.deinit();
    for (items) |item| {
        const label = try dupeZ(allocator, item.label);
        errdefer allocator.free(label);
        const trailing = try dupeZ(allocator, item.trailing_text);
        errdefer allocator.free(trailing);
        s.items.append(.{
            .label = label,
            .leading_icon = item.leading_icon,
            .trailing_text = trailing,
            .enabled = item.enabled,
        }) catch {
            allocator.free(label);
            allocator.free(trailing);
            return error.OutOfMemory;
        };
    }
    node.state = s;
    // The anchor is slot-owned (the registry round-trips it through the
    // "anchor" option — document children never serialize for this widget),
    // so it is marked internal like the item rows: child-walking serializers
    // must not see it as document data. No effect on hit-testing, painting
    // or semantics — the anchor stays fully interactive.
    anchor.internal = true;
    node.add(anchor);
    // the item rows (internal chrome, hidden until open)
    for (0..s.items.items.len) |i| {
        const item_node = try Node.create(allocator, &item_vtable);
        errdefer item_node.allocator.destroy(item_node);
        const is = try allocator.create(ItemState);
        errdefer allocator.destroy(is);
        is.* = .{ .def_index = i, .owner = node };
        item_node.state = is;
        item_node.visible = false;
        item_node.internal = true; // chrome: never serialized
        item_node.exclude_semantics = true; // the menu node carries the semantics
        node.add(item_node);
    }
    ui.semantics.attach(node, .{
        .role = .menu,
        .label = "Menu",
        .focusable = true, // takes the keyboard focus while open
        .value = if (s.items.items.len > 0) s.items.items[0].label else "",
    }); // Phase 2c
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = menuSyncCb, .userdata = node } });
        if (sg.peek()) applyOpen(node, s, true); // starts open
    }
    return node;
}

// --- tests ---

fn selectCounterCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

fn anchorBox(allocator: std.mem.Allocator, w: f32, h: f32) !*Node {
    return golden.solidBox(allocator, w, h, 0x888888FF);
}

test "menu: measures like the anchor; lays the panel out below it (start-aligned)" {
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste", .leading_icon = .star }, .{ .label = "Delete", .trailing_text = "Del" } }, null, null, .{});
    defer m.deinit();
    const sz = m.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectEqual(@as(f32, 120), sz.w);
    try std.testing.expectEqual(@as(f32, 40), sz.h);
    m.layout(.{ .x = 100, .y = 200, .w = 120, .h = 40 });
    // the anchor fills the menu's bounds
    try std.testing.expectEqual(@as(f32, 100), anchor.bounds.x);
    try std.testing.expectEqual(@as(f32, 200), anchor.bounds.y);
    // the panel: below the anchor + 8dp vertical padding, intrinsic width
    const item0 = m.children.items[1];
    try std.testing.expectEqual(@as(f32, 100), item0.bounds.x);
    try std.testing.expectEqual(@as(f32, 200 + 40 + 8), item0.bounds.y);
    try std.testing.expectEqual(item_h, item0.bounds.h);
    const item1 = m.children.items[2];
    try std.testing.expectEqual(@as(f32, 200 + 40 + 8 + 48), item1.bounds.y);
    // the panel width = the widest item (icon + label + trailing text)
    const t = theme_mod.light;
    const w_copy = item_h_pad * 2 + ui.paint.measureText("Copy", 16, false).width;
    const w_paste = item_h_pad * 2 + icon_size + icon_gap + ui.paint.measureText("Paste", 16, false).width;
    const w_delete = item_h_pad * 2 + ui.paint.measureText("Delete", 16, false).width + trail_gap + ui.paint.measureText("Del", 11, false).width;
    const expect_w = @max(w_copy, @max(w_paste, w_delete));
    try std.testing.expectApproxEqAbs(expect_w, item0.bounds.w, 0.001);
    _ = t;
}

test "menu: open/close via the signal; item click selects + closes; keyboard nav" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = selectCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Cut", .enabled = false }, .{ .label = "Paste" } }, sig, cb, .{});
    defer m.deinit();
    m.layout(.{ .x = 0, .y = 0, .w = 120, .h = 40 });
    try std.testing.expect(!isOpen(m));
    try std.testing.expect(!m.children.items[1].visible);
    // open via the signal
    sig.set(true);
    try std.testing.expect(isOpen(m));
    try std.testing.expect(m.children.items[1].visible);
    try std.testing.expect(input.isFocused(m)); // took the keyboard focus
    // keyboard: down skips the disabled item, enter selects it
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(m)); // "Paste" (index 1 skipped)
    try std.testing.expect(!isOpen(m)); // closed after the selection
    try std.testing.expect(!input.isFocused(m)); // focus restored (null here)
    try std.testing.expectEqualStrings("Paste", m.semantics.?.value); // a11y follows
    // pointer: open, hover highlights, click selects (the item row is at
    // y = 40 + 8 = 48..96 — the click lands inside its bounds)
    sig.set(true);
    const item0 = m.children.items[1];
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .enter, .x = 10, .y = 58 });
    try std.testing.expectEqual(@as(i32, 0), stateOf(m).highlight);
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .down, .x = 10, .y = 58, .raw_x = 10, .raw_y = 58 });
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .up, .x = 10, .y = 58, .raw_x = 10, .raw_y = 58 });
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(m));
    try std.testing.expect(!isOpen(m));
    // outside click closes (the router's barrier sends outside_down)
    sig.set(true);
    try std.testing.expect(isOpen(m));
    _ = m.vtable.on_pointer.?(m, .{ .phase = .outside_down, .x = 500, .y = 500 });
    try std.testing.expect(!isOpen(m));
    // escape closes
    sig.set(true);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!isOpen(m));
}

test "menu: semantics — role menu, focusable, value follows the selection" {
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste" } }, null, null, .{});
    defer m.deinit();
    try std.testing.expectEqual(ui.semantics.Role.menu, m.semantics.?.role);
    try std.testing.expect(m.semantics.?.focusable);
    try std.testing.expectEqualStrings("Copy", m.semantics.?.value);
}

test "golden: open menu paints the SurfaceContainer panel + item labels" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{ .{ .label = "Copy" }, .{ .label = "Paste", .leading_icon = .star } }, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the panel: SurfaceContainer, its top at the anchor's bottom edge
    // (20 + 40 = 60; the 8dp vertical padding is inside the panel)
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(80, 70));
    // the panel's rounded corner (radius 4): the exact corner stays background
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(20, 60));
    // the first item's label ink (on_surface) in its row
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 12, .w = 80, .h = 24 }, t.colors.on_surface) > 0);
    // the second item's leading icon ink (on_secondary_container — the menu quirk)
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 48 + 12, .w = 24, .h = 24 }, t.colors.on_secondary_container) > 0);
}

test "golden: hovered menu item paints the on_surface state layer" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{.{ .label = "Copy" }}, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    const item0 = m.children.items[1];
    _ = item0.vtable.on_pointer.?(item0, .{ .phase = .enter, .x = 10, .y = 10 });
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the row (past the label ink): on_surface @ 0.08 over surface_container
    try golden.expectPixelApprox(f, 70, 68 + 8 + 24, golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, t.state.hover), t.colors.surface_container));
}

test "golden: disabled menu item paints the OnSurface@0.38 label" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const anchor = try anchorBox(a, 120, 40);
    const m = try menu(a, anchor, &.{.{ .label = "Copy", .enabled = false }}, null, null, .{ .theme = t });
    defer m.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 260, 200);
    defer r.deinit();
    m.layout(.{ .x = 20, .y = 20, .w = 120, .h = 40 });
    setOpen(m, true);
    r.paint(m, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the label ink: on_surface @ 0.38 over the panel
    const dis = golden.blendOver(ui.paint.withAlphaScaled(t.colors.on_surface, 0.38), t.colors.surface_container);
    try std.testing.expect(f.countColorIn(.{ .x = 32, .y = 68 + 8 + 12, .w = 80, .h = 24 }, dis) > 0);
}
