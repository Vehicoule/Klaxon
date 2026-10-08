// Klaxon gallery (Phase 1g) — full showcase: all 30 widgets, dark/light
// themes, animations, gestures, scroll 10k, TextField.
//
//   root (AnimatedContainer — the bg animates on theme switch)
//   └─ Column — REBUILT on theme switch (Node.remove + deinit + rebuild)
//       ├─ header: title + subtitle | dark/light Toggle
//       └─ ScrollView (fills the rest)
//           └─ content Column — sections:
//               Input · Gestures · Animations · Layout · Typography & media · Scroll
//
// Signals are owned by the Gallery and survive theme rebuilds; the themed
// tree is rebuilt from the new Theme on every switch.
const std = @import("std");
const ui = @import("ui.zig");
const widgets = @import("widgets.zig");
const theme_mod = @import("theme.zig");
const golden = @import("golden.zig"); // tests

const Node = ui.node.Node;
const state = ui.state;
const input_mod = ui.input;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;
const EdgeInsets = ui.layout.EdgeInsets;
const layout = widgets.layout;
const text_w = widgets.text;
const icon_w = widgets.icon;
const image_w = widgets.image;
const container_w = widgets.container;
const divider_w = widgets.divider;
const input_w = widgets.input;
const gestures_w = widgets.gestures;
const anim_w = widgets.anim;

pub const WINDOW_W: i32 = 960;
pub const WINDOW_H: i32 = 640;

/// Fixed-capacity status line (gestures / echo / dropdown), null-terminated.
pub const StatusBuf = [96]u8;

const dropdown_items = [_][]const u8{ "Alpha", "Beta", "Gamma" };
const radio_labels = [_][]const u8{ "One", "Two", "Three" };

/// Widget references into the current tree (refreshed on every rebuild).
const Refs = struct {
    demo_button: *Node,
    theme_toggle: *Node,
    press_text: *Node,
    scroll_view: *Node,
    list_10k: *Node,
    grid: *Node,
    text_field: *Node,
    dropdown: *Node,
    chip: *Node,
};

/// ItemFactory context for the virtualized lists (theme read at build time).
const ListItemCtx = struct {
    allocator: std.mem.Allocator,
    theme: Theme,
};

pub const Gallery = struct {
    allocator: std.mem.Allocator,
    root: *Node, // AnimatedContainer (bg)
    tree: ?*Node = null, // root's current child (rebuilt on theme switch)
    // Signals (owned by the gallery, survive theme rebuilds).
    dark_mode: *state.Signal(bool),
    bg_sig: *state.Signal(Color),
    press_count: *state.Signal(u32),
    radio_group: *state.Signal(u32),
    slider_sig: *state.Signal(f32),
    feat_toggle: *state.Signal(bool),
    feat_check: *state.Signal(bool),
    chip_sel: *state.Signal(bool),
    scale_toggle: *state.Signal(bool),
    pulse_sig: *state.Signal(Color),
    offset_sig: *state.Signal(anim_w.Offset),
    scale_sig: *state.Signal(f32),
    status_sig: *state.Signal(StatusBuf),
    echo_sig: *state.Signal(StatusBuf),
    pick_sig: *state.Signal(StatusBuf),
    list_ctx: ListItemCtx,
    refs: Refs,
    // Transient widget state captured before a theme rebuild and restored
    // after it (a theme switch must not lose typed text, selections or
    // scroll positions).
    saved_tf: [128]u8 = std.mem.zeroes([128]u8),
    saved_tf_len: usize = 0,
    saved_dd: usize = 0,
    saved_scroll: f32 = 0,
    saved_list: f32 = 0,
    saved_grid: f32 = 0,

    /// Heap-allocated: the tree holds pointers into the Gallery (item
    /// factories, callback userdata), so its address must be stable.
    pub fn init(allocator: std.mem.Allocator) !*Gallery {
        const g = try allocator.create(Gallery);
        errdefer allocator.destroy(g);
        g.* = undefined;
        g.allocator = allocator;
        g.tree = null; // no tree yet (undefined would NOT pick up the default)
        g.saved_tf = std.mem.zeroes([128]u8);
        g.saved_tf_len = 0;
        g.saved_dd = 0;
        g.saved_scroll = 0;
        g.saved_list = 0;
        g.saved_grid = 0;
        g.dark_mode = try state.Signal(bool).init(allocator, true);
        errdefer g.dark_mode.deinit();
        g.bg_sig = try state.Signal(Color).init(allocator, theme_mod.dark.bg);
        errdefer g.bg_sig.deinit();
        g.press_count = try state.Signal(u32).init(allocator, 0);
        errdefer g.press_count.deinit();
        g.radio_group = try state.Signal(u32).init(allocator, 0);
        errdefer g.radio_group.deinit();
        g.slider_sig = try state.Signal(f32).init(allocator, 0.5);
        errdefer g.slider_sig.deinit();
        g.feat_toggle = try state.Signal(bool).init(allocator, false);
        errdefer g.feat_toggle.deinit();
        g.feat_check = try state.Signal(bool).init(allocator, true);
        errdefer g.feat_check.deinit();
        g.chip_sel = try state.Signal(bool).init(allocator, false);
        errdefer g.chip_sel.deinit();
        g.scale_toggle = try state.Signal(bool).init(allocator, false);
        errdefer g.scale_toggle.deinit();
        g.pulse_sig = try state.Signal(Color).init(allocator, theme_mod.dark.accent);
        errdefer g.pulse_sig.deinit();
        g.offset_sig = try state.Signal(anim_w.Offset).init(allocator, .{});
        errdefer g.offset_sig.deinit();
        g.scale_sig = try state.Signal(f32).init(allocator, 1);
        errdefer g.scale_sig.deinit();
        g.status_sig = try state.Signal(StatusBuf).init(allocator, std.mem.zeroes(StatusBuf));
        errdefer g.status_sig.deinit();
        g.echo_sig = try state.Signal(StatusBuf).init(allocator, std.mem.zeroes(StatusBuf));
        errdefer g.echo_sig.deinit();
        g.pick_sig = try state.Signal(StatusBuf).init(allocator, std.mem.zeroes(StatusBuf));
        errdefer g.pick_sig.deinit();
        g.list_ctx = .{ .allocator = allocator, .theme = theme_mod.dark };
        g.root = try anim_w.animatedContainer(allocator, .{ .color = g.bg_sig });
        errdefer g.root.deinit();
        try g.rebuild();
        return g;
    }

    pub fn currentTheme(g: *Gallery) Theme {
        return if (g.dark_mode.peek()) theme_mod.dark else theme_mod.light;
    }

    /// Swap the themed tree for a fresh one built from the current theme.
    /// The fresh tree is fully built before the old one is torn down.
    /// Transient widget state (typed text, dropdown selection, scroll
    /// offsets) is captured before the swap and restored after it.
    fn rebuild(g: *Gallery) !void {
        const theme = g.currentTheme();
        g.list_ctx.theme = theme;
        const had_tree = g.tree != null;
        if (had_tree) {
            const tf_text = input_w.textFieldText(g.refs.text_field);
            g.saved_tf_len = @min(tf_text.len, g.saved_tf.len - 1);
            @memcpy(g.saved_tf[0..g.saved_tf_len], tf_text[0..g.saved_tf_len]);
            g.saved_dd = input_w.dropdownSelected(g.refs.dropdown);
            g.saved_scroll = widgets.scroll_view.scrollOffset(g.refs.scroll_view);
            g.saved_list = widgets.list_view.scrollOffset(g.refs.list_10k);
            g.saved_grid = widgets.grid_view.scrollOffset(g.refs.grid);
        }
        const fresh = try buildTree(g, theme);
        if (g.tree) |old| {
            _ = g.root.remove(old);
            old.deinit();
        }
        g.root.add(fresh);
        g.tree = fresh;
        g.bg_sig.set(theme.bg); // animates the root bg to the new theme
        if (had_tree) {
            // Restore the scroll offsets: lay out first (the scrollables
            // need their viewport/content sizes to clamp correctly).
            g.root.layout(g.root.bounds);
            _ = widgets.scroll_view.setScrollOffset(g.refs.scroll_view, g.saved_scroll);
            _ = widgets.list_view.setScrollOffset(g.refs.list_10k, g.saved_list);
            _ = widgets.grid_view.setScrollOffset(g.refs.grid, g.saved_grid);
        }
    }

    pub fn deinit(g: *Gallery) void {
        // Tree first: widgets unsubscribe from the signals while they live.
        if (g.tree) |t| {
            _ = g.root.remove(t);
            t.deinit();
        }
        g.root.deinit();
        g.dark_mode.deinit();
        g.bg_sig.deinit();
        g.press_count.deinit();
        g.radio_group.deinit();
        g.slider_sig.deinit();
        g.feat_toggle.deinit();
        g.feat_check.deinit();
        g.chip_sel.deinit();
        g.scale_toggle.deinit();
        g.pulse_sig.deinit();
        g.offset_sig.deinit();
        g.scale_sig.deinit();
        g.status_sig.deinit();
        g.echo_sig.deinit();
        g.pick_sig.deinit();
        g.allocator.destroy(g);
    }
};

// --- tree building ---

fn buildTree(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12, .padding = 16 });
    col.add(try buildHeader(g, theme));
    const sv = try widgets.scroll_view.scrollView(a, .{});
    g.refs.scroll_view = sv;
    const content = try layout.column(a, .{ .gap = 16 });
    content.add(try section(a, theme, "Input", try buildInputSection(g, theme)));
    content.add(try section(a, theme, "Gestures", try buildGestureSection(g, theme)));
    content.add(try section(a, theme, "Animations", try buildAnimSection(g, theme)));
    content.add(try section(a, theme, "Layout", try buildLayoutSection(a, theme)));
    content.add(try section(a, theme, "Typography & media", try buildTypoSection(a, theme)));
    content.add(try section(a, theme, "Scroll", try buildScrollSection(g, theme)));
    sv.add(content);
    // Expanded: the ScrollView takes exactly the height remaining after the
    // header (a plain fill would overflow the window and hide the bottom).
    const ex = try layout.expanded(a, 1);
    ex.add(sv);
    col.add(ex);
    return col;
}

fn buildHeader(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const header = try container_w.container(a, .{
        .color = theme.surface,
        .radius = 12,
        .padding = EdgeInsets.all(12),
        .border_color = theme.border,
        .border_width = 1,
    });
    const row = try layout.row(a, .{ .gap = 12, .main_align = .space_between, .cross_align = .center });
    header.add(row);
    const titles = try layout.column(a, .{ .gap = 2 });
    titles.add(try text_w.text(a, "Klaxon Gallery", .{ .size = 24, .bold = true, .color = theme.text }));
    titles.add(try text_w.text(a, "31 widgets · dark/light themes · gestures · animations · scroll 10k", .{ .size = 12, .color = theme.text_dim }));
    row.add(titles);
    const right = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const toggle = try input_w.toggle(a, g.dark_mode, .{ .fn_ptr = themeToggleCb, .userdata = g }, .{
        .track_on = theme.accent,
        .track_off = theme.border,
        .knob = theme.text,
    });
    g.refs.theme_toggle = toggle;
    right.add(toggle);
    right.add(try text_w.BoundText(bool).text(a, g.dark_mode, fmtMode, .{ .size = 13, .color = theme.text_dim }));
    row.add(right);
    return header;
}

fn buildInputSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 10 });
    // Button + bound press count
    const r1 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const btn = try input_w.button(a, .{ .fn_ptr = pressCb, .userdata = g }, .{ .bg = theme.accent, .bg_hover = theme.accent_hover });
    btn.add(try text_w.text(a, "Press me", .{ .size = 14, .color = 0xFFFFFFFF }));
    g.refs.demo_button = btn;
    r1.add(btn);
    const press_text = try text_w.BoundText(u32).text(a, g.press_count, fmtPress, .{ .size = 13, .color = theme.text });
    g.refs.press_text = press_text;
    r1.add(press_text);
    col.add(r1);
    // Toggle + Checkbox + Chip
    const r2 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    r2.add(try input_w.toggle(a, g.feat_toggle, null, .{ .track_on = theme.accent, .track_off = theme.border, .knob = theme.text }));
    r2.add(try text_w.text(a, "Toggle", .{ .size = 13, .color = theme.text }));
    r2.add(try input_w.checkbox(a, g.feat_check, null, .{
        .box_color = theme.surface_2,
        .border = theme.border,
        .check = theme.text,
        .accent = theme.accent,
    }));
    r2.add(try text_w.text(a, "Checkbox", .{ .size = 13, .color = theme.text }));
    const chip = try input_w.chip(a, "Chip", g.chip_sel, .{ .fn_ptr = chipCb, .userdata = g }, null, .{
        .bg = theme.surface_2,
        .bg_selected = theme.accent,
        .color = theme.text,
    });
    g.refs.chip = chip;
    r2.add(chip);
    col.add(r2);
    // Radio group
    const r3 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    for (radio_labels, 0..) |label, i| {
        r3.add(try input_w.Radio(u32).radio(a, g.radio_group, @intCast(i), .{
            .ring = theme.border,
            .track = theme.surface_2,
            .dot = theme.accent,
        }));
        r3.add(try text_w.text(a, label, .{ .size = 13, .color = theme.text }));
    }
    r3.add(try text_w.BoundText(u32).text(a, g.radio_group, fmtRadio, .{ .size = 13, .color = theme.text_dim }));
    col.add(r3);
    // Slider
    const r4 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r4.add(try input_w.slider(a, g.slider_sig, null, .{
        .track = theme.surface_2,
        .fill = theme.accent,
        .knob = theme.text,
        .default_width = 160,
    }));
    r4.add(try text_w.BoundText(f32).text(a, g.slider_sig, fmtSlider, .{ .size = 13, .color = theme.text }));
    col.add(r4);
    // TextField + echo
    const r5 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const tf = try input_w.textField(a, .{
        .color = theme.text,
        .hint = theme.text_dim,
        .bg = theme.surface_2,
        .placeholder = "Type here...",
        .initial = g.saved_tf[0..g.saved_tf_len], // restored across theme switches
    }, .{ .fn_ptr = echoCb, .userdata = g }, null);
    g.refs.text_field = tf;
    r5.add(tf);
    r5.add(try text_w.BoundText(StatusBuf).text(a, g.echo_sig, fmtStatus, .{ .size = 13, .color = theme.text_dim }));
    col.add(r5);
    // Dropdown + picked item
    const r6 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const dd = try input_w.dropdown(a, &dropdown_items, .{
        .bg = theme.surface_2,
        .menu_bg = theme.surface,
        .color = theme.text,
        .initial_selected = g.saved_dd, // restored across theme switches
    }, .{ .fn_ptr = pickCb, .userdata = g });
    g.refs.dropdown = dd;
    r6.add(dd);
    r6.add(try text_w.BoundText(StatusBuf).text(a, g.pick_sig, fmtStatus, .{ .size = 13, .color = theme.text_dim }));
    col.add(r6);
    return col;
}

fn buildGestureSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 8 });
    const det = try gestures_w.gestureDetector(a, .{ .callbacks = .{
        .on_tap = .{ .fn_ptr = gTap, .userdata = g },
        .on_double_tap = .{ .fn_ptr = gDoubleTap, .userdata = g },
        .on_long_press = .{ .fn_ptr = gLongPress, .userdata = g },
        .on_pan_start = .{ .fn_ptr = gPanStart, .userdata = g },
        .on_pan_update = .{ .fn_ptr = gPanUpdate, .userdata = g },
        .on_pan_end = .{ .fn_ptr = gPanEnd, .userdata = g },
        .on_swipe = .{ .fn_ptr = gSwipe, .userdata = g },
        .on_pinch = .{ .fn_ptr = gPinch, .userdata = g },
        .on_rotate = .{ .fn_ptr = gRotate, .userdata = g },
    } });
    const pad = try container_w.container(a, .{ .color = theme.surface_2, .radius = 8, .padding = EdgeInsets.all(12) });
    const c = try layout.center(a);
    c.add(try text_w.text(a, "Tap · double-tap · long-press · pan · swipe · pinch · rotate", .{ .size = 13, .color = theme.text_dim }));
    pad.add(c);
    det.add(pad);
    const box = try layout.constrainedBox(a, .{ .min_h = 96 });
    box.add(det);
    col.add(box);
    col.add(try text_w.BoundText(StatusBuf).text(a, g.status_sig, fmtStatus, .{ .size = 13, .color = theme.text }));
    return col;
}

fn buildAnimSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 10 });
    const row = try layout.row(a, .{ .gap = 24, .cross_align = .center });
    // AnimatedContainer: the color pulses (driven by the app's on_frame).
    const pulse = try anim_w.animatedContainer(a, .{ .color = g.pulse_sig, .radius = 8 });
    pulse.add(try layout.constrainedBox(a, .{ .min_w = 96, .min_h = 48, .max_w = 96, .max_h = 48 }));
    const pulse_col = try layout.column(a, .{ .gap = 6, .cross_align = .center });
    pulse_col.add(pulse);
    pulse_col.add(try text_w.text(a, "AnimatedContainer — color pulses", .{ .size = 12, .color = theme.text_dim }));
    row.add(pulse_col);
    // AnimatedOffset: the Slide button moves the box.
    const slide = try anim_w.animatedOffset(a, .{ .offset = g.offset_sig });
    const slide_box = try container_w.container(a, .{ .color = theme.accent, .radius = 8 });
    slide_box.add(try layout.constrainedBox(a, .{ .min_w = 64, .min_h = 44, .max_w = 64, .max_h = 44 }));
    slide.add(slide_box);
    const slide_btn = try input_w.button(a, .{ .fn_ptr = slideCb, .userdata = g }, .{ .bg = theme.surface_2 });
    slide_btn.add(try text_w.text(a, "Slide", .{ .size = 13, .color = theme.text }));
    const slide_col = try layout.column(a, .{ .gap = 6, .cross_align = .center });
    slide_col.add(slide);
    slide_col.add(slide_btn);
    row.add(slide_col);
    // AnimatedScale: the toggle grows the box.
    const scale = try anim_w.animatedScale(a, .{ .scale = g.scale_sig });
    const scale_box = try container_w.container(a, .{ .color = theme.danger, .radius = 8 });
    scale_box.add(try layout.constrainedBox(a, .{ .min_w = 48, .min_h = 48, .max_w = 48, .max_h = 48 }));
    scale.add(scale_box);
    const big = try input_w.toggle(a, g.scale_toggle, .{ .fn_ptr = bigToggleCb, .userdata = g }, .{ .track_on = theme.accent, .track_off = theme.border, .knob = theme.text });
    const scale_col = try layout.column(a, .{ .gap = 6, .cross_align = .center });
    scale_col.add(scale);
    scale_col.add(big);
    row.add(scale_col);
    col.add(row);
    return col;
}

fn buildLayoutSection(a: std.mem.Allocator, theme: Theme) !*Node {
    const col = try layout.column(a, .{ .gap = 10 });
    // Row + Container
    const r1 = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    r1.add(try colorBox(a, theme.accent, 72, 40, 8));
    r1.add(try colorBox(a, theme.surface_2, 72, 40, 8));
    r1.add(try colorBox(a, theme.danger, 72, 40, 8));
    r1.add(try text_w.text(a, "Row + Container", .{ .size = 12, .color = theme.text_dim }));
    col.add(r1);
    col.add(try divider_w.divider(a, .{ .color = theme.border }));
    // Grid (3 columns)
    const grid = try layout.grid(a, .{ .columns = 3, .gap = 8 });
    for (0..6) |i| {
        const color = if (i % 3 == 0) theme.accent else if (i % 3 == 1) theme.surface_2 else theme.danger;
        grid.add(try colorBox(a, color, 0, 32, 6));
    }
    col.add(grid);
    col.add(try text_w.text(a, "Grid — 3 columns", .{ .size = 12, .color = theme.text_dim }));
    col.add(try divider_w.divider(a, .{ .color = theme.border }));
    // Stack + Center
    const stack = try layout.stack(a, .{ .fit = .loose, .alignment = .center });
    stack.add(try colorBox(a, theme.surface_2, 160, 72, 8));
    const ctr = try layout.center(a);
    ctr.add(try colorBox(a, theme.accent, 72, 40, 8));
    stack.add(ctr);
    col.add(stack);
    col.add(try text_w.text(a, "Stack + Center", .{ .size = 12, .color = theme.text_dim }));
    // Align + Padding (+ Container border)
    const r3 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    const al_box = try container_w.container(a, .{ .border_color = theme.border, .border_width = 1, .radius = 8, .padding = EdgeInsets.all(4) });
    const al = try layout.alignTo(a, .{ .alignment = .bottom_right });
    al.add(try colorBox(a, theme.danger, 48, 28, 6));
    al_box.add(al);
    r3.add(al_box);
    const pad = try layout.padding(a, EdgeInsets.all(10));
    pad.add(try colorBox(a, theme.surface_2, 64, 32, 6));
    r3.add(pad);
    r3.add(try text_w.text(a, "Align · Padding · Container border", .{ .size = 12, .color = theme.text_dim }));
    col.add(r3);
    return col;
}

fn buildTypoSection(a: std.mem.Allocator, theme: Theme) !*Node {
    const col = try layout.column(a, .{ .gap = 8 });
    col.add(try text_w.text(a, "Heading — Text widget", .{ .size = 20, .bold = true, .color = theme.text }));
    col.add(try text_w.text(a, "Body text follows the active theme; RichText mixes styled spans:", .{ .size = 13, .color = theme.text_dim }));
    col.add(try text_w.richText(a, &.{
        .{ .text = "Rich", .size = 16, .bold = true, .color = theme.accent },
        .{ .text = "Text — ", .size = 16, .color = theme.text },
        .{ .text = "spans", .size = 16, .bold = true, .color = theme.danger },
        .{ .text = " in ", .size = 16, .color = theme.text_dim },
        .{ .text = "colors", .size = 16, .bold = true, .color = theme.accent },
    }));
    const icons = try layout.row(a, .{ .gap = 10, .cross_align = .center });
    const icon_names = [_]icon_w.IconName{ .play, .pause, .stop, .heart, .star, .home, .search, .menu };
    for (icon_names) |name| icons.add(try icon_w.icon(a, name, .{ .size = 20, .color = theme.text }));
    icons.add(try text_w.text(a, "Icon", .{ .size = 12, .color = theme.text_dim }));
    col.add(icons);
    const img_row = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    img_row.add(try makeImage(a));
    img_row.add(try text_w.text(a, "Image — 96×64 RGBA gradient", .{ .size = 12, .color = theme.text_dim }));
    col.add(img_row);
    return col;
}

fn buildScrollSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    col.add(try text_w.text(a, "ListView — 10 000 items (virtualized: ~7 live nodes) + Scrollbar", .{ .size = 12, .color = theme.text_dim }));
    const list = try widgets.list_view.listView(a, .{
        .item_count = 10_000,
        .factory = .{ .fn_ptr = listItem, .userdata = &g.list_ctx },
        .item_height = 36,
    });
    g.refs.list_10k = list;
    const list_row = try layout.row(a, .{ .gap = 8 });
    const list_box = try layout.constrainedBox(a, .{ .max_w = 880, .max_h = 260 });
    list_box.add(list);
    list_row.add(list_box);
    // The Scrollbar fills max_h like the lists — bound it (the content
    // Column is vertically unbounded inside the ScrollView).
    const sb = try widgets.scrollbar.scrollbar(a, .{ .scroll = list, .track_color = theme.border, .thumb_color = theme.text_dim });
    const sb_box = try layout.constrainedBox(a, .{ .max_h = 260 });
    sb_box.add(sb);
    list_row.add(sb_box);
    col.add(list_row);
    col.add(try text_w.text(a, "GridView — 500 items, 3 columns + Scrollbar", .{ .size = 12, .color = theme.text_dim }));
    const grid = try widgets.grid_view.gridView(a, .{
        .item_count = 500,
        .factory = .{ .fn_ptr = gridItem, .userdata = &g.list_ctx },
        .cross_axis_count = 3,
        .item_height = 44,
    });
    g.refs.grid = grid;
    const grid_row = try layout.row(a, .{ .gap = 8 });
    const grid_box = try layout.constrainedBox(a, .{ .max_w = 880, .max_h = 160 });
    grid_box.add(grid);
    grid_row.add(grid_box);
    const gsb = try widgets.scrollbar.scrollbar(a, .{ .scroll = grid, .track_color = theme.border, .thumb_color = theme.text_dim });
    const gsb_box = try layout.constrainedBox(a, .{ .max_h = 160 });
    gsb_box.add(gsb);
    grid_row.add(gsb_box);
    col.add(grid_row);
    col.add(try text_w.text(a, "ScrollView — single child, wheel + drag", .{ .size = 12, .color = theme.text_dim }));
    const sv = try widgets.scroll_view.scrollView(a, .{});
    const sv_col = try layout.column(a, .{ .gap = 4 });
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        var buf: [48]u8 = undefined;
        sv_col.add(try text_w.text(a, std.fmt.bufPrint(&buf, "ScrollView line {d} — wheel or drag to scroll", .{i}) catch "line", .{ .size = 13, .color = theme.text }));
    }
    sv.add(sv_col);
    const sv_box = try layout.constrainedBox(a, .{ .max_w = 880, .max_h = 120 });
    sv_box.add(sv);
    col.add(sv_box);
    return col;
}

/// A section: dim bold title + a bordered surface card around the body.
fn section(a: std.mem.Allocator, theme: Theme, title: []const u8, body: *Node) !*Node {
    const col = try layout.column(a, .{ .gap = 8 });
    col.add(try text_w.text(a, title, .{ .size = 15, .bold = true, .color = theme.text_dim }));
    const card = try container_w.container(a, .{
        .color = theme.surface,
        .radius = 12,
        .padding = EdgeInsets.all(12),
        .border_color = theme.border,
        .border_width = 1,
    });
    card.add(body);
    col.add(card);
    return col;
}

/// A colored box: a Container around a fixed-size spacer (an empty
/// ConstrainedBox honors its minimums).
fn colorBox(a: std.mem.Allocator, color: Color, w: f32, h: f32, radius: f32) !*Node {
    const c = try container_w.container(a, .{ .color = color, .radius = radius });
    c.add(try layout.constrainedBox(a, .{
        .min_w = w,
        .min_h = h,
        .max_w = if (w > 0) w else std.math.inf(f32),
        .max_h = if (h > 0) h else std.math.inf(f32),
    }));
    return c;
}

/// A 96×64 RGBA gradient (checker-free: R=x, G=y, B=0x80, A=0xFF).
fn makeImage(a: std.mem.Allocator) !*Node {
    const w: usize = 96;
    const h: usize = 64;
    const px = try a.alloc(u8, w * h * 4);
    defer a.free(px); // image() copies the pixels
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            px[i] = @intCast(x * 255 / (w - 1));
            px[i + 1] = @intCast(y * 255 / (h - 1));
            px[i + 2] = 0x80;
            px[i + 3] = 0xFF;
        }
    }
    return image_w.image(a, @intCast(w), @intCast(h), px);
}

// --- virtualized list items (ItemFactory: no error union, OOM is fatal) ---

fn listItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *ListItemCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const card = container_w.container(a, .{ .color = ctx.theme.surface_2, .radius = 6, .padding = .{ .left = 8, .top = 6, .right = 8, .bottom = 6 } }) catch @panic("klaxon: out of memory");
    const row = layout.row(a, .{ .gap = 8, .cross_align = .center }) catch @panic("klaxon: out of memory");
    row.add(icon_w.icon(a, .star, .{ .size = 14, .color = ctx.theme.accent }) catch @panic("klaxon: out of memory"));
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch "Item";
    row.add(text_w.text(a, label, .{ .size = 14, .color = ctx.theme.text }) catch @panic("klaxon: out of memory"));
    card.add(row);
    return card;
}

fn gridItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *ListItemCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const card = container_w.container(a, .{ .color = ctx.theme.surface_2, .radius = 6 }) catch @panic("klaxon: out of memory");
    var buf: [24]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{d}", .{index}) catch "#";
    const c = layout.center(a) catch @panic("klaxon: out of memory");
    c.add(text_w.text(a, label, .{ .size = 13, .color = ctx.theme.text_dim }) catch @panic("klaxon: out of memory"));
    card.add(c);
    return card;
}

// --- callbacks (userdata = the Gallery) ---

fn galleryOf(userdata: ?*anyopaque) *Gallery {
    return @ptrCast(@alignCast(userdata.?));
}

fn pressCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.press_count.set(g.press_count.peek() + 1);
}

fn chipCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.chip_sel.set(!g.chip_sel.peek()); // the Chip widget only fires callbacks
}

fn themeToggleCb(userdata: ?*anyopaque) void {
    galleryOf(userdata).rebuild() catch @panic("klaxon: out of memory");
}

fn echoCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    statusSet(g.echo_sig, input_w.textFieldText(g.refs.text_field));
}

fn pickCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    const i = @min(input_w.dropdownSelected(g.refs.dropdown), dropdown_items.len - 1);
    statusSet(g.pick_sig, dropdown_items[i]);
}

fn slideCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    const cur = g.offset_sig.peek();
    g.offset_sig.set(if (std.meta.eql(cur, anim_w.Offset{})) .{ .x = 48, .y = -16 } else .{});
}

fn bigToggleCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.scale_sig.set(if (g.scale_toggle.peek()) 1.5 else 1.0);
}

fn gTap(userdata: ?*anyopaque) void {
    statusSet(galleryOf(userdata).status_sig, "tap");
}
fn gDoubleTap(userdata: ?*anyopaque) void {
    statusSet(galleryOf(userdata).status_sig, "double-tap");
}
fn gLongPress(userdata: ?*anyopaque) void {
    statusSet(galleryOf(userdata).status_sig, "long-press");
}
fn gPanStart(userdata: ?*anyopaque, dx: f32, dy: f32) void {
    var buf: [48]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "pan start ({d:.0}, {d:.0})", .{ dx, dy }) catch "pan");
}
fn gPanUpdate(userdata: ?*anyopaque, dx: f32, dy: f32) void {
    var buf: [48]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "pan ({d:.0}, {d:.0})", .{ dx, dy }) catch "pan");
}
fn gPanEnd(userdata: ?*anyopaque, vx: f32, vy: f32, dx: f32, dy: f32) void {
    _ = dx;
    _ = dy;
    var buf: [48]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "pan end — velocity ({d:.0}, {d:.0})", .{ vx, vy }) catch "pan end");
}
fn gSwipe(userdata: ?*anyopaque, dir: ui.gestures.SwipeDirection, vx: f32, vy: f32) void {
    _ = vx;
    _ = vy;
    var buf: [32]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "swipe {s}", .{@tagName(dir)}) catch "swipe");
}
fn gPinch(userdata: ?*anyopaque, scale: f32) void {
    var buf: [32]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "pinch x{d:.2}", .{scale}) catch "pinch");
}
fn gRotate(userdata: ?*anyopaque, delta: f32) void {
    var buf: [32]u8 = undefined;
    statusSet(galleryOf(userdata).status_sig, std.fmt.bufPrint(&buf, "rotate {d:.2} rad", .{delta}) catch "rotate");
}

fn statusSet(sig: *state.Signal(StatusBuf), str: []const u8) void {
    var buf: StatusBuf = std.mem.zeroes(StatusBuf);
    const n = @min(str.len, buf.len - 1);
    @memcpy(buf[0..n], str[0..n]);
    sig.set(buf);
}

// --- BoundText formatters ---

fn fmtPress(v: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Pressed {d} times", .{v}) catch "Pressed";
}
fn fmtRadio(v: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Selected: {d}", .{v + 1}) catch "Selected";
}
fn fmtSlider(v: f32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "?";
}
fn fmtMode(v: bool, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} mode", .{if (v) "Dark" else "Light"}) catch "mode";
}
fn fmtStatus(v: StatusBuf, buf: []u8) []const u8 {
    const s = std.mem.sliceTo(&v, 0);
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// --- tests ---

fn countNodes(n: *Node) u64 {
    var c: u64 = 1;
    for (n.children.items) |ch| c += countNodes(ch);
    return c;
}

test "gallery: builds the full showcase and deinits clean" {
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    try std.testing.expect(g.tree != null);
    try std.testing.expectEqual(@as(usize, 2), g.tree.?.children.items.len); // header + ScrollView
    try std.testing.expect(countNodes(g.root) > 100);
    // the 10k list is virtualized: a handful of live nodes at offset 0
    try std.testing.expect(g.refs.list_10k.children.items.len < 20);
}

test "gallery: clicking the theme toggle rebuilds the tree in the other theme" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const old_tree = g.tree.?;
    const old_button = g.refs.demo_button;
    // transient state to preserve: typed text + scroll offsets
    const tf = g.refs.text_field.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = tf.x + 10, .y = tf.y + tf.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = tf.x + 10, .y = tf.y + tf.h / 2 });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "hello" });
    try std.testing.expectEqualStrings("hello", input_w.textFieldText(g.refs.text_field));
    _ = widgets.scroll_view.setScrollOffset(g.refs.scroll_view, 120);
    _ = widgets.list_view.setScrollOffset(g.refs.list_10k, 200);
    // toggle the theme
    const b = g.refs.theme_toggle.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
    // the toggle flipped the signal and the rebuild swapped the tree
    try std.testing.expect(!g.dark_mode.peek());
    try std.testing.expect(g.tree.? != old_tree);
    try std.testing.expect(g.refs.demo_button != old_button);
    try std.testing.expectEqual(theme_mod.light.bg, g.bg_sig.peek());
    // the fresh tree lays out clean and the list is still virtualized
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    try std.testing.expect(g.refs.list_10k.children.items.len < 20);
    // the transient state survived the rebuild
    try std.testing.expectEqualStrings("hello", input_w.textFieldText(g.refs.text_field));
    try std.testing.expectEqual(@as(f32, 120), widgets.scroll_view.scrollOffset(g.refs.scroll_view));
    try std.testing.expectEqual(@as(f32, 200), widgets.list_view.scrollOffset(g.refs.list_10k));
}

test "gallery: the chip toggles its selection signal" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    try std.testing.expect(!g.chip_sel.peek());
    const c = g.refs.chip.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = c.x + c.w / 2, .y = c.y + c.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = c.x + c.w / 2, .y = c.y + c.h / 2 });
    try std.testing.expect(g.chip_sel.peek());
}

test "gallery: pressing the demo button updates the bound text" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const b = g.refs.demo_button.bounds;
    for (0..2) |_| {
        router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
        router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
    }
    try std.testing.expectEqual(@as(u32, 2), g.press_count.peek());
    // the bound text was marked for re-layout (its size changed)
    try std.testing.expect(g.refs.press_text.layout_dirty);
}

test "gallery: the 10k list stays virtualized after a big scroll" {
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const list = g.refs.list_10k;
    _ = widgets.list_view.setScrollOffset(list, widgets.list_view.maxScrollOffset(list));
    try std.testing.expect(list.children.items.len < 20);
    try std.testing.expectEqual(widgets.list_view.maxScrollOffset(list), widgets.list_view.scrollOffset(list));
}

test "golden: gallery paints the themed header over the animated bg" {
    // Deinit order matters: the tree BEFORE the renderer — the Image widget
    // holds a ctx-bound resource (imageDestroy touches the ctx).
    var r = try golden.Renderer.init(std.testing.allocator, WINDOW_W, WINDOW_H);
    defer r.deinit(); // runs LAST
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit(); // runs FIRST (LIFO)
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    r.paint(g.root, 0x000000FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // window bg (AnimatedContainer) + header card surface (deep inside the
    // card: away from the 1px border and the 12px rounded corners)
    try std.testing.expectEqual(theme_mod.dark.bg, f.pixelAt(2, 2));
    try std.testing.expectEqual(theme_mod.dark.surface, f.pixelAt(500, 70));
    // title ink inside the header card
    try std.testing.expect(f.countNotIn(.{ .x = 28, .y = 20, .w = 220, .h = 26 }, theme_mod.dark.surface) > 0);
    // the Input section's accent button is visible below the header
    const b = g.refs.demo_button.bounds;
    try std.testing.expectEqual(theme_mod.dark.accent, f.pixelAt(@intFromFloat(b.x + 4), @intFromFloat(b.y + b.h / 2)));
}

test "gallery: the scroll view fits the window (bottom reachable)" {
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const sv = g.refs.scroll_view;
    // the ScrollView ends inside the window (Expanded sized it to the
    // remaining height after the header)
    try std.testing.expect(sv.bounds.y + sv.bounds.h <= @as(f32, @floatFromInt(WINDOW_H)));
    // and its scroll range can reveal the very bottom of the content
    _ = widgets.scroll_view.setScrollOffset(sv, 1_000_000); // clamps to max
    try std.testing.expect(widgets.scroll_view.scrollOffset(sv) > 0);
}
