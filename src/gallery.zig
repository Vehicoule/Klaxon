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
const button_w = widgets.button;
const icon_button_w = widgets.icon_button;
const checkbox_w = widgets.checkbox;
const radio_w = widgets.radio;
const switch_w = widgets.@"switch";
const slider_w = widgets.slider;
const chip_w = widgets.chip;
const text_field_w = widgets.text_field;
const card_w = widgets.card;
const list_item_w = widgets.list_item;
const menu_w = widgets.menu;
const segmented_button_w = widgets.segmented_button;
const search_bar_w = widgets.search_bar;
const navigation_rail_w = widgets.navigation_rail;
const side_sheet_w = widgets.side_sheet;
const pull_to_refresh_w = widgets.pull_to_refresh;
const split_button_w = widgets.split_button;
const gestures_w = widgets.gestures;
const anim_w = widgets.anim;
const app_bar_w = widgets.app_bar;
const nav_bar_w = widgets.nav_bar;
const drawer_w = widgets.drawer;
const tabs_w = widgets.tabs;
const progress_w = widgets.progress;
const badge_w = widgets.badge;
const tooltip_w = widgets.tooltip;
const bottom_sheet_w = widgets.bottom_sheet;
const dialog_w = widgets.dialog;
const snackbar_w = widgets.snackbar;

pub const WINDOW_W: i32 = 960;
pub const WINDOW_H: i32 = 640;

/// Fixed-capacity status line (gestures / echo / dropdown), null-terminated.
pub const StatusBuf = [96]u8;

const dropdown_items = [_][]const u8{ "Alpha", "Beta", "Gamma" };
const radio_labels = [_][]const u8{ "One", "Two", "Three" };

/// Widget references into the current tree (refreshed on every rebuild).
const Refs = struct {
    demo_button: *Node,
    m3e_button: *Node, // the M3E filled button (Buttons M3E section)
    ib_heart: *Node, // the M3E filled icon toggle (Icon buttons M3E section)
    cb_m3e_btn: *Node, // the M3E checkbox (Selection controls section)
    chip_m3e_filter: *Node, // the M3E filter chip (Chips section)
    tf_m3e: [5]*Node, // the M3E text fields (Text fields section)
    card_m3e: *Node, // the clickable M3E card (Cards section)
    li_m3e: *Node, // the clickable M3E list item (List items section)
    li_m3e_sel: *Node, // the selected M3E list item (List items section)
    menu_m3e: *Node, // the M3E dropdown menu (Menus section)
    seg_m3e: *Node, // the M3E segmented button (Segmented buttons section)
    split_m3e: *Node, // the M3E split button (Split buttons section)
    sb_m3e: *Node, // the M3E search bar (Search bar section)
    nr_m3e: *Node, // the M3E navigation rail, collapsed (Navigation rail section)
    nr_exp_m3e: *Node, // the M3E navigation rail, expanded (Navigation rail section)
    ss_m3e: *Node, // the M3E side sheet (Side sheet section)
    ss_btn: *Node, // the side sheet's toggle button (Side sheet section)
    ptr_m3e: *Node, // the M3E pull-to-refresh container (Pull to refresh section)
    theme_toggle: *Node,
    desktop_toggle: *Node, // mobile/desktop density switch (Phase 2d-0.5)
    sb_list: *Node, // the list scrollbar (style follows the platform tokens)
    sb_grid: *Node,
    press_text: *Node,
    scroll_view: *Node,
    list_10k: *Node,
    grid: *Node,
    text_field: *Node,
    dropdown: *Node,
    chip: *Node,
    nav_bar: *Node,
    tabs: *Node,
    drawer: *Node,
    drawer_btn: *Node,
    sheet: *Node,
    sheet_btn: *Node,
    dialog: *Node,
    dialog_btn: *Node,
    snack_btn: *Node,
    snackbar: *Node,
    tooltip_btn: *Node,
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
    ib_toggles: [4]*state.Signal(bool), // the icon-button toggles' checked states
    // the selection controls' signals (M3E section, 2d.2 PR B2)
    cb_m3e: *state.Signal(bool), // checkbox, clickable (unchecked)
    cb_on: *state.Signal(bool), // checkbox, checked
    cb_dis: *state.Signal(bool), // checkbox, disabled
    cb_err: *state.Signal(bool), // checkbox, error + checked
    sw_m3e: *state.Signal(bool), // switch, clickable (off)
    sw_on: *state.Signal(bool), // switch, on
    sw_dis: *state.Signal(bool), // switch, disabled
    sl_m3e: *state.Signal(f32), // slider, 0.25
    sl_dis: *state.Signal(f32), // slider, disabled
    radio_m3e: *state.Signal(usize), // the M3E radio group selection
    // the chips' signals (M3E section, 2d.2 PR C1)
    chip_filter: *state.Signal(bool), // filter chip, clickable (unselected)
    chip_filter_on: *state.Signal(bool), // filter chip, selected
    // the cards + list items' signals (M3E sections, 2d.3 PR D1)
    card_press: *state.Signal(u32), // the clickable card's counter
    li_press: *state.Signal(u32), // the clickable list item's counter
    li_selected: *state.Signal(bool), // the selected list item's state
    // the menu's signals (M3E section, 2d.3 PR D2)
    menu_open: *state.Signal(bool), // the menu's open state (toggled by the anchor)
    menu_select: *state.Signal(u32), // the menu's selection counter
    // the segmented/split buttons' signals (M3E sections, 2d.3 PR D3)
    seg_selected: *state.Signal(usize), // the segmented button's selection
    seg_change: *state.Signal(u32), // the segmented button's change counter
    split_press: *state.Signal(u32), // the split button's leading counter
    split_trail: *state.Signal(u32), // the split button's trailing counter
    // the search bar + navigation rails' signals (M3E sections, 2d.3 PR D4)
    sb_text: *state.Signal(search_bar_w.TextBuf), // the search bar's text
    sb_change: *state.Signal(u32), // the search bar's change counter
    sb_submit: *state.Signal(u32), // the search bar's submit (Enter) counter
    nr_selected: *state.Signal(usize), // the collapsed rail's selection
    nr_change: *state.Signal(u32), // the collapsed rail's change counter
    nr_exp_selected: *state.Signal(usize), // the expanded rail's selection
    nr_exp_change: *state.Signal(u32), // the expanded rail's change counter
    // the side sheet + pull-to-refresh's signals (M3E sections, 2d.3 PR D5)
    ss_open: *state.Signal(bool), // the side sheet's open state (toggled)
    ss_closed: *state.Signal(u32), // the side sheet's close counter
    ptr_refreshing: *state.Signal(bool), // the PTR's refreshing state
    ptr_refresh: *state.Signal(u32), // the PTR's refresh counter
    /// App hook fired after a theme/platform rebuild (the app re-reads the
    /// platform tokens — e.g. host.cursors).
    on_platform_changed: ?state.Callback = null,
    desktop_mode: *state.Signal(bool), // false = mobile presets, true = desktop presets
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
    nav_selected: *state.Signal(usize),
    tabs_selected: *state.Signal(usize),
    drawer_open: *state.Signal(bool),
    sheet_open: *state.Signal(bool),
    dialog_open: *state.Signal(bool),
    snack_visible: *state.Signal(bool),
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
    // the M3E text fields' entries (restored across theme switches)
    saved_tf_m3e: [5][256]u8 = std.mem.zeroes([5][256]u8),
    saved_tf_m3e_lens: [5]usize = std.mem.zeroes([5]usize),
    // the M3E search bar's entry (restored across theme switches at FULL
    // length — the TextBuf signal mirror caps at 255 bytes, so the saved
    // copy is an owned buffer, not a fixed array)
    saved_sb: std.array_list.Managed(u8),

    /// Heap-allocated: the tree holds pointers into the Gallery (item
    /// factories, callback userdata), so its address must be stable.
    pub fn init(allocator: std.mem.Allocator) !*Gallery {
        const g = try allocator.create(Gallery);
        errdefer allocator.destroy(g);
        g.* = undefined;
        g.allocator = allocator;
        g.tree = null; // no tree yet (undefined would NOT pick up the default)
        g.on_platform_changed = null; // same: undefined would NOT pick up the default
        g.saved_tf = std.mem.zeroes([128]u8);
        g.saved_tf_len = 0;
        g.saved_dd = 0;
        g.saved_scroll = 0;
        g.saved_list = 0;
        g.saved_grid = 0;
        g.saved_tf_m3e = std.mem.zeroes([5][256]u8);
        g.saved_tf_m3e_lens = std.mem.zeroes([5]usize);
        g.saved_sb = std.array_list.Managed(u8).init(allocator);
        errdefer g.saved_sb.deinit();
        g.dark_mode = try state.Signal(bool).init(allocator, true);
        errdefer g.dark_mode.deinit();
        // one function-scope errdefer frees the signals initialized so far
        // (a loop-body errdefer stops applying when its iteration ends)
        var ib_init: usize = 0;
        errdefer {
            for (g.ib_toggles[0..ib_init]) |sig| sig.deinit();
        }
        for (&g.ib_toggles, 0..) |*sig, i| {
            sig.* = try state.Signal(bool).init(allocator, i == 0); // the heart starts checked
            ib_init += 1;
        }
        g.cb_m3e = try state.Signal(bool).init(allocator, false);
        errdefer g.cb_m3e.deinit();
        g.cb_on = try state.Signal(bool).init(allocator, true);
        errdefer g.cb_on.deinit();
        g.cb_dis = try state.Signal(bool).init(allocator, false);
        errdefer g.cb_dis.deinit();
        g.cb_err = try state.Signal(bool).init(allocator, true);
        errdefer g.cb_err.deinit();
        g.sw_m3e = try state.Signal(bool).init(allocator, false);
        errdefer g.sw_m3e.deinit();
        g.sw_on = try state.Signal(bool).init(allocator, true);
        errdefer g.sw_on.deinit();
        g.sw_dis = try state.Signal(bool).init(allocator, false);
        errdefer g.sw_dis.deinit();
        g.sl_m3e = try state.Signal(f32).init(allocator, 0.25);
        errdefer g.sl_m3e.deinit();
        g.sl_dis = try state.Signal(f32).init(allocator, 0.4);
        errdefer g.sl_dis.deinit();
        g.radio_m3e = try state.Signal(usize).init(allocator, 0);
        errdefer g.radio_m3e.deinit();
        g.chip_filter = try state.Signal(bool).init(allocator, false);
        errdefer g.chip_filter.deinit();
        g.chip_filter_on = try state.Signal(bool).init(allocator, true);
        errdefer g.chip_filter_on.deinit();
        g.card_press = try state.Signal(u32).init(allocator, 0);
        errdefer g.card_press.deinit();
        g.li_press = try state.Signal(u32).init(allocator, 0);
        errdefer g.li_press.deinit();
        g.li_selected = try state.Signal(bool).init(allocator, false);
        errdefer g.li_selected.deinit();
        g.menu_open = try state.Signal(bool).init(allocator, false);
        errdefer g.menu_open.deinit();
        g.menu_select = try state.Signal(u32).init(allocator, 0);
        errdefer g.menu_select.deinit();
        g.seg_selected = try state.Signal(usize).init(allocator, 0);
        errdefer g.seg_selected.deinit();
        g.seg_change = try state.Signal(u32).init(allocator, 0);
        errdefer g.seg_change.deinit();
        g.split_press = try state.Signal(u32).init(allocator, 0);
        errdefer g.split_press.deinit();
        g.split_trail = try state.Signal(u32).init(allocator, 0);
        errdefer g.split_trail.deinit();
        g.sb_text = try state.Signal(search_bar_w.TextBuf).init(allocator, search_bar_w.bufFromText(""));
        errdefer g.sb_text.deinit();
        g.sb_change = try state.Signal(u32).init(allocator, 0);
        errdefer g.sb_change.deinit();
        g.sb_submit = try state.Signal(u32).init(allocator, 0);
        errdefer g.sb_submit.deinit();
        g.nr_selected = try state.Signal(usize).init(allocator, 0);
        errdefer g.nr_selected.deinit();
        g.nr_change = try state.Signal(u32).init(allocator, 0);
        errdefer g.nr_change.deinit();
        g.nr_exp_selected = try state.Signal(usize).init(allocator, 0);
        errdefer g.nr_exp_selected.deinit();
        g.nr_exp_change = try state.Signal(u32).init(allocator, 0);
        errdefer g.nr_exp_change.deinit();
        g.ss_open = try state.Signal(bool).init(allocator, false);
        errdefer g.ss_open.deinit();
        g.ss_closed = try state.Signal(u32).init(allocator, 0);
        errdefer g.ss_closed.deinit();
        g.ptr_refreshing = try state.Signal(bool).init(allocator, false);
        errdefer g.ptr_refreshing.deinit();
        g.ptr_refresh = try state.Signal(u32).init(allocator, 0);
        errdefer g.ptr_refresh.deinit();
        g.desktop_mode = try state.Signal(bool).init(allocator, false);
        errdefer g.desktop_mode.deinit();
        g.bg_sig = try state.Signal(Color).init(allocator, theme_mod.dark.colors.surface);
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
        g.pulse_sig = try state.Signal(Color).init(allocator, theme_mod.dark.colors.primary);
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
        g.nav_selected = try state.Signal(usize).init(allocator, 0);
        errdefer g.nav_selected.deinit();
        g.tabs_selected = try state.Signal(usize).init(allocator, 0);
        errdefer g.tabs_selected.deinit();
        g.drawer_open = try state.Signal(bool).init(allocator, false);
        errdefer g.drawer_open.deinit();
        g.sheet_open = try state.Signal(bool).init(allocator, false);
        errdefer g.sheet_open.deinit();
        g.dialog_open = try state.Signal(bool).init(allocator, false);
        errdefer g.dialog_open.deinit();
        g.snack_visible = try state.Signal(bool).init(allocator, false);
        errdefer g.snack_visible.deinit();
        g.list_ctx = .{ .allocator = allocator, .theme = theme_mod.dark };
        g.root = try anim_w.animatedContainer(allocator, .{ .color = g.bg_sig });
        errdefer g.root.deinit();
        try g.rebuild();
        return g;
    }

    pub fn currentTheme(g: *Gallery) Theme {
        if (g.desktop_mode.peek()) {
            return if (g.dark_mode.peek()) theme_mod.desktop_dark else theme_mod.desktop_light;
        }
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
            for (g.refs.tf_m3e, 0..) |tf, i| {
                const txt = text_field_w.text(tf);
                g.saved_tf_m3e_lens[i] = @min(txt.len, g.saved_tf_m3e[i].len - 1);
                @memcpy(g.saved_tf_m3e[i][0..g.saved_tf_m3e_lens[i]], txt[0..g.saved_tf_m3e_lens[i]]);
            }
            // the search bar's full text (the signal mirror caps at 255)
            g.saved_sb.clearRetainingCapacity();
            g.saved_sb.appendSlice(search_bar_w.text(g.refs.sb_m3e)) catch @panic("klaxon: out of memory");
        }
        const fresh = try buildTree(g, theme);
        if (g.tree) |old| {
            _ = g.root.remove(old);
            old.deinit();
        }
        g.root.add(fresh);
        g.tree = fresh;
        g.bg_sig.set(theme.colors.surface); // animates the root bg to the new theme
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
        for (g.ib_toggles) |sig| sig.deinit();
        g.cb_m3e.deinit();
        g.cb_on.deinit();
        g.cb_dis.deinit();
        g.cb_err.deinit();
        g.sw_m3e.deinit();
        g.sw_on.deinit();
        g.sw_dis.deinit();
        g.sl_m3e.deinit();
        g.sl_dis.deinit();
        g.radio_m3e.deinit();
        g.chip_filter.deinit();
        g.chip_filter_on.deinit();
        g.card_press.deinit();
        g.li_press.deinit();
        g.li_selected.deinit();
        g.menu_open.deinit();
        g.menu_select.deinit();
        g.seg_selected.deinit();
        g.seg_change.deinit();
        g.split_press.deinit();
        g.split_trail.deinit();
        g.saved_sb.deinit();
        g.sb_text.deinit();
        g.sb_change.deinit();
        g.sb_submit.deinit();
        g.nr_selected.deinit();
        g.nr_change.deinit();
        g.nr_exp_selected.deinit();
        g.nr_exp_change.deinit();
        g.ss_open.deinit();
        g.ss_closed.deinit();
        g.ptr_refreshing.deinit();
        g.ptr_refresh.deinit();
        g.desktop_mode.deinit();
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
        g.nav_selected.deinit();
        g.tabs_selected.deinit();
        g.drawer_open.deinit();
        g.sheet_open.deinit();
        g.dialog_open.deinit();
        g.snack_visible.deinit();
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
    content.add(try section(a, theme, "Buttons (M3E)", try buildButtonsSection(g, theme)));
    content.add(try section(a, theme, "Icon buttons (M3E)", try buildIconButtonsSection(g, theme)));
    content.add(try section(a, theme, "Selection controls (M3E)", try buildSelectionSection(g, theme)));
    content.add(try section(a, theme, "Chips (M3E)", try buildChipsSection(g, theme)));
    content.add(try section(a, theme, "Text fields (M3E)", try buildTextFieldsSection(g, theme)));
    content.add(try section(a, theme, "Cards (M3E)", try buildCardsSection(g, theme)));
    content.add(try section(a, theme, "List items (M3E)", try buildListItemsSection(g, theme)));
    content.add(try section(a, theme, "Menus (M3E)", try buildMenusSection(g, theme)));
    content.add(try section(a, theme, "Segmented buttons (M3E)", try buildSegmentedSection(g, theme)));
    content.add(try section(a, theme, "Split buttons (M3E)", try buildSplitSection(g, theme)));
    content.add(try section(a, theme, "Search bar (M3E)", try buildSearchBarSection(g, theme)));
    content.add(try section(a, theme, "Navigation rail (M3E)", try buildNavRailSection(g, theme)));
    content.add(try section(a, theme, "Side sheet (M3E)", try buildSideSheetSection(g, theme)));
    content.add(try section(a, theme, "Pull to refresh (M3E)", try buildPullToRefreshSection(g, theme)));
    content.add(try section(a, theme, "Navigation chrome", try buildNavSection(g, theme)));
    content.add(try section(a, theme, "Feedback", try buildFeedbackSection(g, theme)));
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
    // The snackbar overlays the window's bottom, above the scroll content —
    // a Stack (expand: both children get the full window bounds; the snackbar
    // self-positions at the bottom-center and hit-tests its content rect only).
    const snack = try snackbar_w.snackBar(a, g.snack_visible, null, null, .{
        .text = "Item saved",
        .action_label = "Undo",
        .theme = theme,
    });
    g.refs.snackbar = snack;
    const stack = try layout.stack(a, .{ .fit = .expand });
    stack.add(col);
    stack.add(snack);
    return stack;
}

fn buildHeader(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const header = try container_w.container(a, .{
        .color = theme.colors.surface_container,
        .radius = 12,
        .padding = EdgeInsets.all(12),
        .border_color = theme.colors.outline_variant,
        .border_width = 1,
    });
    const row = try layout.row(a, .{ .gap = 12, .main_align = .space_between, .cross_align = .center });
    header.add(row);
    const titles = try layout.column(a, .{ .gap = 2 });
    titles.add(try text_w.text(a, "Klaxon Gallery", .{ .size = 24, .bold = true, .color = theme.colors.on_surface }));
    titles.add(try text_w.text(a, "31 widgets · dark/light themes · gestures · animations · scroll 10k", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    row.add(titles);
    const right = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const toggle = try input_w.toggle(a, g.dark_mode, .{ .fn_ptr = themeToggleCb, .userdata = g }, .{
        .track_on = theme.colors.primary,
        .track_off = theme.colors.surface_container_highest,
        .knob_on = theme.colors.on_primary,
        .knob_off = theme.colors.outline,
    });
    g.refs.theme_toggle = toggle;
    right.add(toggle);
    right.add(try text_w.BoundText(bool).text(a, g.dark_mode, fmtMode, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    // Density switch (Phase 2d-0.5): mobile presets ↔ desktop presets.
    const dtoggle = try input_w.toggle(a, g.desktop_mode, .{ .fn_ptr = themeToggleCb, .userdata = g }, .{
        .track_on = theme.colors.primary,
        .track_off = theme.colors.surface_container_highest,
        .knob_on = theme.colors.on_primary,
        .knob_off = theme.colors.outline,
    });
    g.refs.desktop_toggle = dtoggle;
    right.add(dtoggle);
    right.add(try text_w.BoundText(bool).text(a, g.desktop_mode, fmtDensity, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    row.add(right);
    return header;
}

fn buildInputSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 10 });
    // Button + bound press count
    const r1 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const btn = try input_w.button(a, .{ .fn_ptr = pressCb, .userdata = g }, .{ .bg = theme.colors.primary, .bg_hover = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.hover), .bg_pressed = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.pressed) });
    btn.add(try text_w.text(a, "Press me", .{ .size = 14, .color = theme.colors.on_primary }));
    g.refs.demo_button = btn;
    r1.add(btn);
    const press_text = try text_w.BoundText(u32).text(a, g.press_count, fmtPress, .{ .size = 13, .color = theme.colors.on_surface });
    g.refs.press_text = press_text;
    r1.add(press_text);
    col.add(r1);
    // Toggle + Checkbox + Chip
    const r2 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    r2.add(try input_w.toggle(a, g.feat_toggle, null, .{ .track_on = theme.colors.primary, .track_off = theme.colors.surface_container_highest, .knob_on = theme.colors.on_primary, .knob_off = theme.colors.outline }));
    r2.add(try text_w.text(a, "Toggle", .{ .size = 13, .color = theme.colors.on_surface }));
    r2.add(try input_w.checkbox(a, g.feat_check, null, .{
        .box_color = theme.colors.surface_container_high,
        .border = theme.colors.outline_variant,
        .check = theme.colors.on_primary,
        .accent = theme.colors.primary,
    }));
    r2.add(try text_w.text(a, "Checkbox", .{ .size = 13, .color = theme.colors.on_surface }));
    const chip = try input_w.chip(a, "Chip", g.chip_sel, .{ .fn_ptr = chipCb, .userdata = g }, null, .{
        .bg = theme.colors.surface_container_high,
        .bg_selected = theme.colors.primary_container,
        .color = theme.colors.on_surface,
        .color_selected = theme.colors.on_primary_container,
    });
    g.refs.chip = chip;
    r2.add(chip);
    col.add(r2);
    // Radio group
    const r3 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    for (radio_labels, 0..) |label, i| {
        r3.add(try input_w.Radio(u32).radio(a, g.radio_group, @intCast(i), .{
            .ring = theme.colors.outline_variant,
            .track = theme.colors.surface_container_high,
            .dot = theme.colors.primary,
        }));
        r3.add(try text_w.text(a, label, .{ .size = 13, .color = theme.colors.on_surface }));
    }
    r3.add(try text_w.BoundText(u32).text(a, g.radio_group, fmtRadio, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(r3);
    // Slider
    const r4 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r4.add(try input_w.slider(a, g.slider_sig, null, .{
        .track = theme.colors.surface_container_high,
        .fill = theme.colors.primary,
        .knob = theme.colors.on_surface,
        .default_width = 160,
    }));
    r4.add(try text_w.BoundText(f32).text(a, g.slider_sig, fmtSlider, .{ .size = 13, .color = theme.colors.on_surface }));
    col.add(r4);
    // TextField + echo
    const r5 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const tf = try input_w.textField(a, .{
        .color = theme.colors.on_surface,
        .hint = theme.colors.on_surface_variant,
        .bg = theme.colors.surface_container_high,
        .placeholder = "Type here...",
        .initial = g.saved_tf[0..g.saved_tf_len], // restored across theme switches
    }, .{ .fn_ptr = echoCb, .userdata = g }, null);
    g.refs.text_field = tf;
    r5.add(tf);
    r5.add(try text_w.BoundText(StatusBuf).text(a, g.echo_sig, fmtStatus, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(r5);
    // Dropdown + picked item
    const r6 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const dd = try input_w.dropdown(a, &dropdown_items, .{
        .bg = theme.colors.surface_container_high,
        .menu_bg = theme.colors.surface_container,
        .color = theme.colors.on_surface,
        .initial_selected = g.saved_dd, // restored across theme switches
    }, .{ .fn_ptr = pickCb, .userdata = g });
    g.refs.dropdown = dd;
    r6.add(dd);
    r6.add(try text_w.BoundText(StatusBuf).text(a, g.pick_sig, fmtStatus, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(r6);
    return col;
}

/// Buttons (M3E, batch 2d.2 PR A): the 5 variants, the 5 sizes, and the
/// icon / disabled / square-shape combinations.
fn buildButtonsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // Variants (small)
    const r1 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const filled = try button_w.button(a, .{ .fn_ptr = pressCb, .userdata = g }, .{ .label = "Filled", .theme = theme });
    g.refs.m3e_button = filled;
    r1.add(filled);
    r1.add(try button_w.button(a, null, .{ .variant = .filled_tonal, .label = "Tonal", .theme = theme }));
    r1.add(try button_w.button(a, null, .{ .variant = .elevated, .label = "Elevated", .theme = theme }));
    r1.add(try button_w.button(a, null, .{ .variant = .outlined, .label = "Outlined", .theme = theme }));
    r1.add(try button_w.button(a, null, .{ .variant = .text, .label = "Text", .theme = theme }));
    col.add(r1);
    // Sizes (filled)
    const r2 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r2.add(try button_w.button(a, null, .{ .size = .xsmall, .label = "XS", .theme = theme }));
    r2.add(try button_w.button(a, null, .{ .size = .small, .label = "S", .theme = theme }));
    r2.add(try button_w.button(a, null, .{ .size = .medium, .label = "M", .theme = theme }));
    r2.add(try button_w.button(a, null, .{ .size = .large, .label = "L", .theme = theme }));
    r2.add(try button_w.button(a, null, .{ .size = .xlarge, .label = "XL", .theme = theme }));
    col.add(r2);
    // Icon + disabled + square shape
    const r3 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r3.add(try button_w.button(a, null, .{ .label = "Favorite", .icon = .heart, .theme = theme }));
    r3.add(try button_w.button(a, null, .{ .variant = .outlined, .label = "Save", .icon = .star, .theme = theme }));
    r3.add(try button_w.button(a, null, .{ .label = "Disabled", .enabled = false, .theme = theme }));
    r3.add(try button_w.button(a, null, .{ .variant = .outlined, .label = "Disabled", .enabled = false, .theme = theme }));
    r3.add(try button_w.button(a, null, .{ .shape = .square, .label = "Square", .theme = theme }));
    col.add(r3);
    return col;
}

/// Icon buttons (M3E, batch 2d.2 PR B1): the 4 variants (plain), the 4
/// variants (toggle), the 5 sizes, and width/disabled/square combinations.
fn buildIconButtonsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // Variants (plain, small)
    const r1 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r1.add(try icon_button_w.iconButton(a, null, null, .{ .icon = .star, .a11y_label = "Standard", .theme = theme }));
    r1.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .icon = .star, .a11y_label = "Filled", .theme = theme }));
    r1.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled_tonal, .icon = .star, .a11y_label = "Tonal", .theme = theme }));
    r1.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .outlined, .icon = .star, .a11y_label = "Outlined", .theme = theme }));
    col.add(r1);
    // Variants (toggle, small — click to check/uncheck; the Gallery owns the
    // signals so they survive theme rebuilds)
    const r2 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    const heart = try icon_button_w.iconButton(a, g.ib_toggles[0], null, .{ .icon = .heart, .a11y_label = "Favorite", .theme = theme });
    g.refs.ib_heart = heart;
    r2.add(heart);
    r2.add(try icon_button_w.iconButton(a, g.ib_toggles[1], null, .{ .variant = .filled, .icon = .menu, .a11y_label = "Menu", .theme = theme }));
    r2.add(try icon_button_w.iconButton(a, g.ib_toggles[2], null, .{ .variant = .filled_tonal, .icon = .heart, .a11y_label = "Tonal", .theme = theme }));
    r2.add(try icon_button_w.iconButton(a, g.ib_toggles[3], null, .{ .variant = .outlined, .icon = .heart, .a11y_label = "Outlined", .theme = theme }));
    col.add(r2);
    // Sizes (filled)
    const r3 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r3.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .size = .xsmall, .icon = .star, .a11y_label = "XS", .theme = theme }));
    r3.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .size = .small, .icon = .star, .a11y_label = "S", .theme = theme }));
    r3.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .size = .medium, .icon = .star, .a11y_label = "M", .theme = theme }));
    r3.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .size = .large, .icon = .star, .a11y_label = "L", .theme = theme }));
    r3.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .size = .xlarge, .icon = .star, .a11y_label = "XL", .theme = theme }));
    col.add(r3);
    // Widths + disabled + square shape
    const r4 = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    r4.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .width = .narrow, .icon = .star, .a11y_label = "Narrow", .theme = theme }));
    r4.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .width = .wide, .icon = .star, .a11y_label = "Wide", .theme = theme }));
    r4.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .filled, .enabled = false, .icon = .star, .a11y_label = "Disabled", .theme = theme }));
    r4.add(try icon_button_w.iconButton(a, null, null, .{ .variant = .outlined, .shape = .square, .icon = .star, .a11y_label = "Square", .theme = theme }));
    col.add(r4);
    return col;
}

/// Selection controls (M3E, batch 2d.2 PR B2): checkboxes (off/on/disabled/
/// error), a radio group, switches (off/on/disabled), sliders (determinate/
/// disabled).
fn buildSelectionSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // Checkboxes
    const r1 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    const cb = try checkbox_w.checkbox(a, g.cb_m3e, null, .{ .a11y_label = "Unchecked", .theme = theme });
    g.refs.cb_m3e_btn = cb;
    r1.add(cb);
    r1.add(try checkbox_w.checkbox(a, g.cb_on, null, .{ .a11y_label = "Checked", .theme = theme }));
    r1.add(try checkbox_w.checkbox(a, g.cb_dis, null, .{ .enabled = false, .a11y_label = "Disabled", .theme = theme }));
    r1.add(try checkbox_w.checkbox(a, g.cb_err, null, .{ .@"error" = true, .a11y_label = "Error", .theme = theme }));
    col.add(r1);
    // Radio group (3 radios, shared selection signal)
    const r2 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    for (radio_labels, 0..) |label, i| {
        r2.add(try radio_w.radio(a, g.radio_m3e, @intCast(i), .{ .a11y_label = label, .theme = theme }));
        r2.add(try text_w.text(a, label, .{ .size = 13, .color = theme.colors.on_surface }));
    }
    col.add(r2);
    // Switches
    const r3 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    r3.add(try switch_w.@"switch"(a, g.sw_m3e, null, .{ .a11y_label = "Off", .theme = theme }));
    r3.add(try switch_w.@"switch"(a, g.sw_on, null, .{ .a11y_label = "On", .theme = theme }));
    r3.add(try switch_w.@"switch"(a, g.sw_dis, null, .{ .enabled = false, .a11y_label = "Disabled", .theme = theme }));
    col.add(r3);
    // Sliders + value labels
    const r4 = try layout.column(a, .{ .gap = 8 });
    const sl1 = try slider_w.slider(a, g.sl_m3e, null, .{ .a11y_label = "Volume", .theme = theme });
    r4.add(sl1);
    r4.add(try text_w.BoundText(f32).text(a, g.sl_m3e, fmtSlider, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    const sl2 = try slider_w.slider(a, g.sl_dis, null, .{ .enabled = false, .a11y_label = "Disabled", .theme = theme });
    r4.add(sl2);
    col.add(r4);
    return col;
}

/// Chips (M3E, batch 2d.2 PR C1): the 5 variants (assist / elevated / filter /
/// suggestion / input) + states (selected filter, disabled, with icons).
fn buildChipsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // the 5 variants (the filter chip toggles; the input chip carries the
    // trailing close affordance)
    const r1 = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    r1.add(try chip_w.chip(a, null, null, .{ .variant = .assist, .label = "Assist", .theme = theme }));
    r1.add(try chip_w.chip(a, null, null, .{ .variant = .elevated, .label = "Elevated", .theme = theme }));
    const flt = try chip_w.chip(a, g.chip_filter, null, .{ .variant = .filter, .label = "Filter", .theme = theme });
    g.refs.chip_m3e_filter = flt;
    r1.add(flt);
    r1.add(try chip_w.chip(a, null, null, .{ .variant = .suggestion, .label = "Suggestion", .theme = theme }));
    r1.add(try chip_w.chip(a, null, null, .{ .variant = .input, .label = "Input", .trailing_icon = .close, .theme = theme }));
    col.add(r1);
    // states: a selected filter chip (toggle, starts checked), a disabled
    // chip, a chip with a leading icon
    const r2 = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    r2.add(try chip_w.chip(a, g.chip_filter_on, null, .{ .variant = .filter, .label = "Selected", .theme = theme }));
    r2.add(try chip_w.chip(a, null, null, .{ .enabled = false, .label = "Disabled", .theme = theme }));
    r2.add(try chip_w.chip(a, null, null, .{ .variant = .suggestion, .label = "With icon", .leading_icon = .star, .theme = theme }));
    col.add(r2);
    return col;
}

/// Text fields (M3E, batch 2d.2 PR C2): outlined (label + placeholder),
/// outlined with a leading icon, filled with supporting text, error,
/// disabled. The fields stretch to the full width (column cross_align).
fn buildTextFieldsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    var specs = [_]text_field_w.TextFieldOptions{
        .{ .variant = .outlined, .label = "Email", .placeholder = "you@example.com", .theme = theme },
        .{ .variant = .outlined, .label = "Search", .leading_icon = .search, .theme = theme },
        .{ .variant = .filled, .label = "Notes", .supporting = "Helper text", .theme = theme },
        .{ .variant = .outlined, .@"error" = true, .label = "Username", .supporting = "Already taken", .theme = theme },
        .{ .variant = .filled, .enabled = false, .label = "Locked", .initial = "Read only", .theme = theme },
    };
    for (&specs, 0..) |*spec, i| {
        // the entry is restored across theme switches (disabled fields keep
        // their fixed initial — they are never edited)
        if (spec.enabled) spec.initial = g.saved_tf_m3e[i][0..g.saved_tf_m3e_lens[i]];
        const f = try text_field_w.textField(a, null, null, null, spec.*);
        g.refs.tf_m3e[i] = f;
        col.add(f);
    }
    return col;
}

/// Cards (M3E, batch 2d.3 PR D1): the 3 variants in a row + a clickable card
/// (counter) + a disabled card.
fn buildCardsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    const row = try layout.row(a, .{ .gap = 12 });
    const variants = [_]card_w.CardVariant{ .filled, .elevated, .outlined };
    const names = [_][]const u8{ "Filled", "Elevated", "Outlined" };
    for (variants, names) |v, name| {
        const c = try card_w.card(a, null, .{ .variant = v, .theme = theme });
        c.add(try text_w.text(a, name, .{ .size = 14, .color = theme.colors.on_surface }));
        row.add(c);
    }
    col.add(row);
    // a clickable card with its counter beside it
    const click_card = try card_w.card(a, .{ .fn_ptr = cardPressCb, .userdata = g }, .{ .theme = theme });
    g.refs.card_m3e = click_card;
    click_card.add(try text_w.text(a, "Clickable card", .{ .size = 14, .color = theme.colors.on_surface }));
    const cc = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    cc.add(click_card);
    cc.add(try text_w.BoundText(u32).text(a, g.card_press, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(cc);
    // disabled
    const dis = try card_w.card(a, null, .{ .enabled = false, .theme = theme });
    dis.add(try text_w.text(a, "Disabled card", .{ .size = 14, .color = theme.colors.on_surface }));
    col.add(dis);
    return col;
}

/// List items (M3E, batch 2d.3 PR D1): one-line (leading icon), two-line
/// (supporting + trailing icon), three-line (overline), selected (signal),
/// clickable (counter), disabled.
fn buildListItemsSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 0 });
    col.add(try list_item_w.listItem(a, null, null, .{ .headline = "One line", .leading_icon = .home, .theme = theme }));
    col.add(try list_item_w.listItem(a, null, null, .{ .headline = "Two lines", .supporting = "Supporting text", .lines = .two, .trailing_icon = .chevron_right, .theme = theme }));
    col.add(try list_item_w.listItem(a, null, null, .{ .overline = "Overline", .headline = "Three lines", .supporting = "Supporting text", .lines = .three, .theme = theme }));
    const sel_li = try list_item_w.listItem(a, g.li_selected, null, .{ .headline = "Selected (signal)", .leading_icon = .check, .theme = theme });
    g.refs.li_m3e_sel = sel_li;
    col.add(sel_li);
    const click_li = try list_item_w.listItem(a, null, .{ .fn_ptr = listItemPressCb, .userdata = g }, .{ .headline = "Clickable", .trailing_text = "tap", .theme = theme });
    g.refs.li_m3e = click_li;
    col.add(click_li);
    col.add(try list_item_w.listItem(a, null, null, .{ .enabled = false, .headline = "Disabled", .supporting = "Supporting text", .lines = .two, .theme = theme }));
    // the clickable row's counter
    const li_row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    li_row.add(try list_item_w.listItem(a, null, .{ .fn_ptr = listItemPressCb, .userdata = g }, .{ .headline = "Counter row", .leading_icon = .plus, .trailing_icon = .close, .trailing_text = "both", .theme = theme }));
    li_row.add(try text_w.BoundText(u32).text(a, g.li_press, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(li_row);
    return col;
}

/// Menus (M3E, batch 2d.3 PR D2): an M3E dropdown menu anchored to an M3E
/// button — the anchor opens/closes it, selecting an item fires the counter.
fn buildMenusSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const anchor = try button_w.button(a, .{ .fn_ptr = menuOpenCb, .userdata = g }, .{ .label = "Open menu", .icon = .arrow_down, .theme = theme });
    const m = try menu_w.menu(a, anchor, &.{
        .{ .label = "Copy", .leading_icon = .star },
        .{ .label = "Paste", .trailing_text = "Ctrl+V" },
        .{ .label = "Delete", .enabled = false },
    }, g.menu_open, .{ .fn_ptr = menuSelectCb, .userdata = g }, .{ .theme = theme });
    g.refs.menu_m3e = m;
    row.add(m);
    row.add(try text_w.BoundText(u32).text(a, g.menu_select, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    return row;
}

/// Segmented buttons (M3E, batch 2d.3 PR D3): a single-choice row — a click
/// selects (the signal round-trips) and the change counter fires.
fn buildSegmentedSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const m = try segmented_button_w.segmentedButton(a, &.{
        .{ .label = "Day" },
        .{ .label = "Week", .icon = .star },
        .{ .label = "Month" },
    }, g.seg_selected, .{ .fn_ptr = segChangeCb, .userdata = g }, .{ .theme = theme });
    g.refs.seg_m3e = m;
    row.add(m);
    row.add(try text_w.BoundText(u32).text(a, g.seg_change, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    return row;
}

/// Split buttons (M3E, batch 2d.3 PR D3): the leading half fires the action,
/// the trailing half fires the toggle (the app would open a menu).
fn buildSplitSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const m = try split_button_w.splitButton(a, .{ .fn_ptr = splitPressCb, .userdata = g }, .{ .fn_ptr = splitTrailCb, .userdata = g }, .{ .label = "Save", .leading_icon = .star, .theme = theme });
    g.refs.split_m3e = m;
    row.add(m);
    row.add(try text_w.BoundText(u32).text(a, g.split_press, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    row.add(try text_w.BoundText(u32).text(a, g.split_trail, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    return row;
}

/// Search bar (M3E, batch 2d.3 PR D4): the collapsed pill — click to focus,
/// type (the text mirrors the signal), Enter submits, the trailing clear
/// button clears.
fn buildSearchBarSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 8 });
    const sb = try search_bar_w.searchBar(a, g.sb_text, .{ .fn_ptr = sbChangeCb, .userdata = g }, .{ .fn_ptr = sbSubmitCb, .userdata = g }, .{ .placeholder = "Search songs, videos, books…", .theme = theme });
    g.refs.sb_m3e = sb;
    // restore the entry captured before a theme rebuild (full length — the
    // signal mirror caps at 255 bytes; setText also re-mirrors the signal)
    if (g.saved_sb.items.len > 0) search_bar_w.setText(sb, g.saved_sb.items);
    col.add(sb);
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    row.add(try text_w.BoundText(u32).text(a, g.sb_change, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    row.add(try text_w.BoundText(u32).text(a, g.sb_submit, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(row);
    return col;
}

/// Navigation rail (M3E, batch 2d.3 PR D4): the collapsed rail (96dp,
/// circle indicator) next to the expanded rail (icon+label rows, pill
/// indicator) — a click selects (the signal round-trips) and the change
/// counter fires.
fn buildNavRailSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const items = [_]navigation_rail_w.NavRailItem{
        .{ .label = "Home", .icon = .home },
        .{ .label = "Music", .icon = .play },
        .{ .label = "Video", .icon = .square },
        .{ .label = "Books", .icon = .star },
    };
    const row = try layout.row(a, .{ .gap = 16, .cross_align = .start });
    const nr = try navigation_rail_w.navigationRail(a, &items, g.nr_selected, .{ .fn_ptr = nrChangeCb, .userdata = g }, .{ .theme = theme });
    g.refs.nr_m3e = nr;
    row.add(nr);
    const nr_exp = try navigation_rail_w.navigationRail(a, &items, g.nr_exp_selected, .{ .fn_ptr = nrExpChangeCb, .userdata = g }, .{ .expanded = true, .theme = theme });
    g.refs.nr_exp_m3e = nr_exp;
    row.add(nr_exp);
    row.add(try text_w.BoundText(u32).text(a, g.nr_change, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    row.add(try text_w.BoundText(u32).text(a, g.nr_exp_change, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    // the rails fill a fixed-height box (fillMaxHeight semantics)
    const box = try layout.constrainedBox(a, .{ .min_h = 320, .max_h = 320 });
    box.add(row);
    return box;
}

/// Side sheet (M3E, batch 2d.3 PR D5): a modal side sheet (scrim +
/// SurfaceContainerLow panel) toggled by a button; the close counter fires
/// on a scrim click / Escape.
fn buildSideSheetSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 8 });
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    const btn = try button_w.button(a, .{ .fn_ptr = ssToggleCb, .userdata = g }, .{ .label = "Toggle side sheet", .theme = theme });
    g.refs.ss_btn = btn;
    row.add(btn);
    row.add(try text_w.BoundText(u32).text(a, g.ss_closed, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(row);
    const body = try text_w.text(a, "Page body behind the sheet", .{ .size = 14, .color = theme.colors.on_surface_variant });
    const content = try layout.column(a, .{ .gap = 8, .padding = 16 });
    content.add(try text_w.text(a, "Filters", .{ .size = 16, .bold = true, .color = theme.colors.on_surface }));
    content.add(try text_w.text(a, "Recent", .{ .size = 14, .color = theme.colors.on_surface_variant }));
    content.add(try text_w.text(a, "Favorites", .{ .size = 14, .color = theme.colors.on_surface_variant }));
    const ss = try side_sheet_w.sideSheet(a, g.ss_open, .{ .fn_ptr = ssClosedCb, .userdata = g }, .{
        .modal = true,
        .body = body,
        .content = content,
        .theme = theme,
    });
    g.refs.ss_m3e = ss;
    // the sheet fills finite constraints (a sheet is screen-height — bound it)
    const box = try layout.constrainedBox(a, .{ .min_h = 240, .max_h = 240 });
    box.add(ss);
    col.add(box);
    return col;
}

/// Pull to refresh (M3E, batch 2d.3 PR D5): a scrollable list wrapped in a
/// PTR container — pull down at the top past 80dp to trigger a refresh (the
/// counter fires; the refreshing state shows until the app clears it).
fn buildPullToRefreshSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 8 });
    const sv = try widgets.scroll_view.scrollView(a, .{});
    const list = try layout.column(a, .{ .gap = 8, .padding = 8 });
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        list.add(try text_w.text(a, "Pull me down — list item", .{ .size = 14, .color = theme.colors.on_surface }));
    }
    sv.add(list);
    const ptr = try pull_to_refresh_w.pullToRefresh(a, g.ptr_refreshing, .{ .fn_ptr = ptrRefreshCb, .userdata = g }, .{ .theme = theme });
    ptr.add(sv);
    g.refs.ptr_m3e = ptr;
    const box = try layout.constrainedBox(a, .{ .min_h = 240, .max_h = 240 });
    box.add(ptr);
    col.add(box);
    const row = try layout.row(a, .{ .gap = 8, .cross_align = .center });
    row.add(try text_w.BoundText(u32).text(a, g.ptr_refresh, fmtPress, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    row.add(try text_w.BoundText(bool).text(a, g.ptr_refreshing, fmtRefreshing, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(row);
    return col;
}

/// Navigation chrome (M3E batch 1): AppBar, NavBar, Tabs, Drawer.
fn buildNavSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // AppBar (small): leading menu button, title (title_large), trailing actions.
    const icon_btn = struct {
        fn make(alloc: std.mem.Allocator, ic: icon_w.IconName, t: Theme) !*Node {
            const b = try input_w.button(alloc, null, .{
                .bg = t.colors.surface,
                .bg_hover = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.hover),
                .bg_pressed = theme_mod.stateLayer(t.colors.surface, t.colors.on_surface, t.state.pressed),
                .padding = EdgeInsets.all(12),
            });
            b.add(try icon_w.icon(alloc, ic, .{ .size = 24, .color = t.colors.on_surface }));
            return b;
        }
    }.make;
    const actions = try layout.row(a, .{});
    actions.add(try icon_btn(a, .search, theme));
    actions.add(try icon_btn(a, .star, theme));
    col.add(try app_bar_w.appBar(a, .{
        .theme = theme,
        .leading = try icon_btn(a, .menu, theme),
        .title = try text_w.text(a, "Klaxon", .{ .size = theme.type_scale.title_large.size, .color = theme.colors.on_surface }),
        .actions = actions,
    }));
    // NavBar: 4 destinations (icon + label content; the bar owns selection).
    const destinations = [_]struct { icon: icon_w.IconName, label: []const u8 }{
        .{ .icon = .home, .label = "Home" },
        .{ .icon = .play, .label = "Music" },
        .{ .icon = .square, .label = "Video" },
        .{ .icon = .star, .label = "Books" },
    };
    const nav = try nav_bar_w.navBar(a, g.nav_selected, .{ .theme = theme });
    g.refs.nav_bar = nav;
    for (destinations) |d| {
        const item = try layout.column(a, .{ .gap = 4, .cross_align = .center });
        item.add(try icon_w.icon(a, d.icon, .{ .size = 24, .color = theme.colors.on_surface_variant }));
        item.add(try text_w.text(a, d.label, .{ .size = theme.type_scale.label_medium.size, .color = theme.colors.on_surface_variant }));
        nav.add(item);
    }
    col.add(nav);
    col.add(try text_w.BoundText(usize).text(a, g.nav_selected, fmtNavSel, .{ .size = 12, .color = theme.colors.on_surface_variant }));
    // Tabs: 3 tabs (icon + label), gliding indicator.
    const tabs = try tabs_w.tabs(a, g.tabs_selected, .{ .theme = theme });
    g.refs.tabs = tabs;
    const tab_items = [_]struct { icon: icon_w.IconName, label: []const u8 }{
        .{ .icon = .play, .label = "Music" },
        .{ .icon = .square, .label = "Video" },
        .{ .icon = .heart, .label = "Favorites" },
    };
    for (tab_items) |d| {
        const item = try layout.column(a, .{ .gap = 4, .cross_align = .center });
        item.add(try icon_w.icon(a, d.icon, .{ .size = 24, .color = theme.colors.on_surface_variant }));
        item.add(try text_w.text(a, d.label, .{ .size = theme.type_scale.label_medium.size, .color = theme.colors.on_surface_variant }));
        tabs.add(item);
    }
    col.add(tabs);
    col.add(try text_w.BoundText(usize).text(a, g.tabs_selected, fmtTabsSel, .{ .size = 12, .color = theme.colors.on_surface_variant }));
    // Drawer (modal): an open button + the drawer itself (body + panel).
    const open_btn = try input_w.button(a, .{ .fn_ptr = drawerOpenCb, .userdata = g }, .{
        .bg = theme.colors.primary,
        .bg_hover = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.pressed),
    });
    open_btn.add(try text_w.text(a, "Open drawer", .{ .size = 14, .color = theme.colors.on_primary }));
    g.refs.drawer_btn = open_btn;
    const drawer_row = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    drawer_row.add(open_btn);
    drawer_row.add(try text_w.BoundText(bool).text(a, g.drawer_open, fmtDrawerOpen, .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(drawer_row);
    // The drawer: body = the page content (behind), content = the panel.
    const body = try container_w.container(a, .{ .color = theme.colors.surface_container_high, .radius = 8, .padding = EdgeInsets.all(16) });
    const body_col = try layout.column(a, .{ .gap = 8 });
    body_col.add(try text_w.text(a, "Body — open the drawer, then click the scrim (or press Escape) to close", .{ .size = 13, .color = theme.colors.on_surface_variant }));
    body_col.add(try layout.constrainedBox(a, .{ .min_h = 140 }));
    body.add(body_col);
    const panel_col = try layout.column(a, .{ .gap = 10 });
    panel_col.add(try text_w.text(a, "Navigation drawer", .{ .size = theme.type_scale.title_large.size, .color = theme.colors.on_surface }));
    panel_col.add(try divider_w.divider(a, .{ .color = theme.colors.outline_variant }));
    for (destinations[0..3]) |d| {
        const row = try layout.row(a, .{ .gap = 12, .cross_align = .center });
        row.add(try icon_w.icon(a, d.icon, .{ .size = 24, .color = theme.colors.on_surface }));
        row.add(try text_w.text(a, d.label, .{ .size = 14, .color = theme.colors.on_surface }));
        panel_col.add(row);
    }
    const panel_content = try layout.padding(a, EdgeInsets.all(16));
    panel_content.add(panel_col);
    const dr = try drawer_w.drawer(a, g.drawer_open, null, .{ .theme = theme, .body = body, .content = panel_content });
    g.refs.drawer = dr;
    // The drawer fills finite constraints (a modal is screen-height); in this
    // unbounded scroll column, wrap it in a bounded box.
    const drawer_box = try layout.constrainedBox(a, .{ .min_h = 240, .max_h = 240 });
    drawer_box.add(dr);
    col.add(drawer_box);
    return col;
}

fn buildFeedbackSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    // Progress indicators: linear determinate (25% / 60% / 100%), linear
    // indeterminate, M3E wavy determinate, circular determinate + indeterminate.
    const prog_col = try layout.column(a, .{ .gap = 12 });
    prog_col.add(try progress_w.progressIndicator(a, .{ .progress = 0.25, .theme = theme }));
    prog_col.add(try progress_w.progressIndicator(a, .{ .progress = 0.6, .theme = theme }));
    prog_col.add(try progress_w.progressIndicator(a, .{ .progress = 1.0, .theme = theme }));
    prog_col.add(try progress_w.progressIndicator(a, .{ .theme = theme })); // indeterminate
    prog_col.add(try progress_w.progressIndicator(a, .{ .progress = 0.6, .wavy = true, .theme = theme }));
    const circ_row = try layout.row(a, .{ .gap = 24, .cross_align = .center });
    circ_row.add(try progress_w.progressIndicator(a, .{ .kind = .circular, .progress = 0.75, .theme = theme }));
    circ_row.add(try progress_w.progressIndicator(a, .{ .kind = .circular, .theme = theme })); // indeterminate
    prog_col.add(circ_row);
    col.add(prog_col);
    // Badges: large count badge, small dot badge, max-count badge.
    const badge_row = try layout.row(a, .{ .gap = 24, .cross_align = .center });
    const star = try icon_w.icon(a, .star, .{ .size = 24, .color = theme.colors.on_surface });
    badge_row.add(try badge_w.badgedBox(a, star, try badge_w.badge(a, .{ .label = "3", .theme = theme }), .{}));
    const heart = try icon_w.icon(a, .heart, .{ .size = 24, .color = theme.colors.on_surface });
    badge_row.add(try badge_w.badgedBox(a, heart, try badge_w.badge(a, .{ .theme = theme }), .{})); // dot
    const menu_ic = try icon_w.icon(a, .menu, .{ .size = 24, .color = theme.colors.on_surface });
    badge_row.add(try badge_w.badgedBox(a, menu_ic, try badge_w.badge(a, .{ .label = "99+", .theme = theme }), .{}));
    col.add(badge_row);
    // Tooltip: hover the button to show the bubble.
    const tip_btn = try input_w.button(a, null, .{
        .bg = theme.colors.secondary_container,
        .bg_hover = theme_mod.stateLayer(theme.colors.secondary_container, theme.colors.on_secondary_container, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.secondary_container, theme.colors.on_secondary_container, theme.state.pressed),
    });
    tip_btn.add(try text_w.text(a, "Hover me", .{ .size = 14, .color = theme.colors.on_secondary_container }));
    g.refs.tooltip_btn = tip_btn;
    col.add(try tooltip_w.tooltip(a, tip_btn, .{ .text = "Save", .theme = theme }));
    // Bottom sheet (modal): an open button + the sheet in a bounded box.
    const sheet_btn = try input_w.button(a, .{ .fn_ptr = sheetOpenCb, .userdata = g }, .{
        .bg = theme.colors.primary,
        .bg_hover = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.pressed),
    });
    sheet_btn.add(try text_w.text(a, "Open bottom sheet", .{ .size = 14, .color = theme.colors.on_primary }));
    g.refs.sheet_btn = sheet_btn;
    col.add(sheet_btn);
    const sheet_body = try container_w.container(a, .{ .color = theme.colors.surface_container_high, .radius = 8, .padding = EdgeInsets.all(16) });
    sheet_body.add(try text_w.text(a, "Body — click the scrim (or press Escape) to close", .{ .size = 13, .color = theme.colors.on_surface_variant }));
    const sheet_content = try layout.column(a, .{ .gap = 8 });
    sheet_content.add(try text_w.text(a, "Bottom sheet", .{ .size = theme.type_scale.title_large.size, .color = theme.colors.on_surface }));
    sheet_content.add(try text_w.text(a, "Supplementary content anchored to the bottom.", .{ .size = 13, .color = theme.colors.on_surface_variant }));
    const sheet_pad = try layout.padding(a, EdgeInsets.all(16));
    sheet_pad.add(sheet_content);
    const sh = try bottom_sheet_w.bottomSheet(a, g.sheet_open, null, .{ .theme = theme, .body = sheet_body, .content = sheet_pad });
    g.refs.sheet = sh;
    const sheet_box = try layout.constrainedBox(a, .{ .min_h = 240, .max_h = 240 });
    sheet_box.add(sh);
    col.add(sheet_box);
    // Dialog (modal): an open button + the dialog in a bounded box.
    const dialog_btn = try input_w.button(a, .{ .fn_ptr = dialogOpenCb, .userdata = g }, .{
        .bg = theme.colors.primary,
        .bg_hover = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.pressed),
    });
    dialog_btn.add(try text_w.text(a, "Open dialog", .{ .size = 14, .color = theme.colors.on_primary }));
    g.refs.dialog_btn = dialog_btn;
    col.add(dialog_btn);
    const dlg = try dialog_w.dialog(a, g.dialog_open, null, .{
        .theme = theme,
        .title = try text_w.text(a, "Delete this item?", .{ .size = theme.type_scale.headline_small.size, .color = theme.colors.on_surface }),
        .content = try text_w.text(a, "This action cannot be undone.", .{ .size = theme.type_scale.body_medium.size, .color = theme.colors.on_surface_variant }),
        .actions = try dialogActionsRow(a, theme),
    });
    g.refs.dialog = dlg;
    const dialog_box = try layout.constrainedBox(a, .{ .min_w = 360, .max_w = 360, .min_h = 240, .max_h = 240 });
    dialog_box.add(dlg);
    col.add(dialog_box);
    // SnackBar: the show button (the snackbar itself overlays the window).
    const snack_btn = try input_w.button(a, .{ .fn_ptr = snackShowCb, .userdata = g }, .{
        .bg = theme.colors.primary,
        .bg_hover = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.primary, theme.colors.on_primary, theme.state.pressed),
    });
    snack_btn.add(try text_w.text(a, "Show snackbar", .{ .size = 14, .color = theme.colors.on_primary }));
    g.refs.snack_btn = snack_btn;
    col.add(snack_btn);
    return col;
}

/// The dialog's actions row: Cancel / Delete text buttons (M3E: primary
/// label_large, end-aligned, 8dp gap).
fn dialogActionsRow(a: std.mem.Allocator, theme: Theme) !*Node {
    const row = try layout.row(a, .{ .gap = 8 });
    const cancel = try input_w.button(a, null, .{
        .bg = 0x00000000,
        .bg_hover = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.primary, theme.state.pressed),
        .padding = EdgeInsets.symmetric(8, 4),
    });
    cancel.add(try text_w.text(a, "Cancel", .{ .size = theme.type_scale.label_large.size, .color = theme.colors.primary }));
    const del = try input_w.button(a, null, .{
        .bg = 0x00000000,
        .bg_hover = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.primary, theme.state.hover),
        .bg_pressed = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.primary, theme.state.pressed),
        .padding = EdgeInsets.symmetric(8, 4),
    });
    del.add(try text_w.text(a, "Delete", .{ .size = theme.type_scale.label_large.size, .color = theme.colors.primary }));
    row.add(cancel);
    row.add(del);
    return row;
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
    const pad = try container_w.container(a, .{ .color = theme.colors.surface_container_high, .radius = 8, .padding = EdgeInsets.all(12) });
    const c = try layout.center(a);
    c.add(try text_w.text(a, "Tap · double-tap · long-press · pan · swipe · pinch · rotate", .{ .size = 13, .color = theme.colors.on_surface_variant }));
    pad.add(c);
    det.add(pad);
    const box = try layout.constrainedBox(a, .{ .min_h = 96 });
    box.add(det);
    col.add(box);
    col.add(try text_w.BoundText(StatusBuf).text(a, g.status_sig, fmtStatus, .{ .size = 13, .color = theme.colors.on_surface }));
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
    pulse_col.add(try text_w.text(a, "AnimatedContainer — color pulses", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    row.add(pulse_col);
    // AnimatedOffset: the Slide button moves the box.
    const slide = try anim_w.animatedOffset(a, .{ .offset = g.offset_sig });
    const slide_box = try container_w.container(a, .{ .color = theme.colors.primary, .radius = 8 });
    slide_box.add(try layout.constrainedBox(a, .{ .min_w = 64, .min_h = 44, .max_w = 64, .max_h = 44 }));
    slide.add(slide_box);
    const slide_btn = try input_w.button(a, .{ .fn_ptr = slideCb, .userdata = g }, .{ .bg = theme.colors.surface_container_high, .bg_hover = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.on_surface, theme.state.hover), .bg_pressed = theme_mod.stateLayer(theme.colors.surface_container_high, theme.colors.on_surface, theme.state.pressed) });
    slide_btn.add(try text_w.text(a, "Slide", .{ .size = 13, .color = theme.colors.on_surface }));
    const slide_col = try layout.column(a, .{ .gap = 6, .cross_align = .center });
    slide_col.add(slide);
    slide_col.add(slide_btn);
    row.add(slide_col);
    // AnimatedScale: the toggle grows the box.
    const scale = try anim_w.animatedScale(a, .{ .scale = g.scale_sig });
    const scale_box = try container_w.container(a, .{ .color = theme.colors.@"error", .radius = 8 });
    scale_box.add(try layout.constrainedBox(a, .{ .min_w = 48, .min_h = 48, .max_w = 48, .max_h = 48 }));
    scale.add(scale_box);
    const big = try input_w.toggle(a, g.scale_toggle, .{ .fn_ptr = bigToggleCb, .userdata = g }, .{ .track_on = theme.colors.primary, .track_off = theme.colors.surface_container_highest, .knob_on = theme.colors.on_primary, .knob_off = theme.colors.outline });
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
    r1.add(try colorBox(a, theme.colors.primary, 72, 40, 8));
    r1.add(try colorBox(a, theme.colors.surface_container_high, 72, 40, 8));
    r1.add(try colorBox(a, theme.colors.@"error", 72, 40, 8));
    r1.add(try text_w.text(a, "Row + Container", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    col.add(r1);
    col.add(try divider_w.divider(a, .{ .color = theme.colors.outline_variant }));
    // Grid (3 columns)
    const grid = try layout.grid(a, .{ .columns = 3, .gap = 8 });
    for (0..6) |i| {
        const color = if (i % 3 == 0) theme.colors.primary else if (i % 3 == 1) theme.colors.surface_container_high else theme.colors.@"error";
        grid.add(try colorBox(a, color, 0, 32, 6));
    }
    col.add(grid);
    col.add(try text_w.text(a, "Grid — 3 columns", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    col.add(try divider_w.divider(a, .{ .color = theme.colors.outline_variant }));
    // Stack + Center
    const stack = try layout.stack(a, .{ .fit = .loose, .alignment = .center });
    stack.add(try colorBox(a, theme.colors.surface_container_high, 160, 72, 8));
    const ctr = try layout.center(a);
    ctr.add(try colorBox(a, theme.colors.primary, 72, 40, 8));
    stack.add(ctr);
    col.add(stack);
    col.add(try text_w.text(a, "Stack + Center", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    // Align + Padding (+ Container border)
    const r3 = try layout.row(a, .{ .gap = 16, .cross_align = .center });
    const al_box = try container_w.container(a, .{ .border_color = theme.colors.outline_variant, .border_width = 1, .radius = 8, .padding = EdgeInsets.all(4) });
    const al = try layout.alignTo(a, .{ .alignment = .bottom_right });
    al.add(try colorBox(a, theme.colors.@"error", 48, 28, 6));
    al_box.add(al);
    r3.add(al_box);
    const pad = try layout.padding(a, EdgeInsets.all(10));
    pad.add(try colorBox(a, theme.colors.surface_container_high, 64, 32, 6));
    r3.add(pad);
    r3.add(try text_w.text(a, "Align · Padding · Container border", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    col.add(r3);
    return col;
}

fn buildTypoSection(a: std.mem.Allocator, theme: Theme) !*Node {
    const col = try layout.column(a, .{ .gap = 8 });
    col.add(try text_w.text(a, "Heading — Text widget", .{ .size = 20, .bold = true, .color = theme.colors.on_surface }));
    col.add(try text_w.text(a, "Body text follows the active theme; RichText mixes styled spans:", .{ .size = 13, .color = theme.colors.on_surface_variant }));
    col.add(try text_w.richText(a, &.{
        .{ .text = "Rich", .size = 16, .bold = true, .color = theme.colors.primary },
        .{ .text = "Text — ", .size = 16, .color = theme.colors.on_surface },
        .{ .text = "spans", .size = 16, .bold = true, .color = theme.colors.@"error" },
        .{ .text = " in ", .size = 16, .color = theme.colors.on_surface_variant },
        .{ .text = "colors", .size = 16, .bold = true, .color = theme.colors.primary },
    }));
    const icons = try layout.row(a, .{ .gap = 10, .cross_align = .center });
    const icon_names = [_]icon_w.IconName{ .play, .pause, .stop, .heart, .star, .home, .search, .menu };
    for (icon_names) |name| icons.add(try icon_w.icon(a, name, .{ .size = 20, .color = theme.colors.on_surface }));
    icons.add(try text_w.text(a, "Icon", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    col.add(icons);
    const img_row = try layout.row(a, .{ .gap = 12, .cross_align = .center });
    img_row.add(try makeImage(a));
    img_row.add(try text_w.text(a, "Image — 96×64 RGBA gradient", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    col.add(img_row);
    return col;
}

fn buildScrollSection(g: *Gallery, theme: Theme) !*Node {
    const a = g.allocator;
    const col = try layout.column(a, .{ .gap = 12 });
    col.add(try text_w.text(a, "ListView — 10 000 items (virtualized: ~7 live nodes) + Scrollbar", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    const list = try widgets.list_view.listView(a, .{
        .item_count = 10_000,
        .factory = .{ .fn_ptr = listItem, .userdata = &g.list_ctx },
        .item_height = 36,
    });
    g.refs.list_10k = list;
    // A Stack inside the bounding box: the scrollbar sits at the list's right
    // edge — classic (mobile) takes 8dp at the end, overlay (desktop) floats
    // over the content with no layout space. The scrollbar's parent is the
    // stack (the list's viewport bounds), so the overlay track lands ON the
    // content and stays hit-testable + draggable. The box bounds the height
    // (the Scrollbar fills max_h; the content Column is vertically unbounded).
    const list_box = try layout.constrainedBox(a, .{ .max_w = 880, .max_h = 260 });
    const list_stack = try layout.stack(a, .{ .alignment = .top_right });
    list_stack.add(list);
    const sb = try widgets.scrollbar.scrollbar(a, .{ .scroll = list, .theme = theme, .track_color = theme.colors.outline_variant, .thumb_color = theme.colors.on_surface_variant });
    g.refs.sb_list = sb;
    list_stack.add(sb);
    list_box.add(list_stack);
    col.add(list_box);
    col.add(try text_w.text(a, "GridView — 500 items, 3 columns + Scrollbar", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    const grid = try widgets.grid_view.gridView(a, .{
        .item_count = 500,
        .factory = .{ .fn_ptr = gridItem, .userdata = &g.list_ctx },
        .cross_axis_count = 3,
        .item_height = 44,
    });
    g.refs.grid = grid;
    // Same stack structure as the list: the scrollbar overlays the grid's
    // right edge (desktop) or sits at its end (mobile classic).
    const grid_box = try layout.constrainedBox(a, .{ .max_w = 880, .max_h = 160 });
    const grid_stack = try layout.stack(a, .{ .alignment = .top_right });
    grid_stack.add(grid);
    const gsb = try widgets.scrollbar.scrollbar(a, .{ .scroll = grid, .theme = theme, .track_color = theme.colors.outline_variant, .thumb_color = theme.colors.on_surface_variant });
    g.refs.sb_grid = gsb;
    grid_stack.add(gsb);
    grid_box.add(grid_stack);
    col.add(grid_box);
    col.add(try text_w.text(a, "ScrollView — single child, wheel + drag", .{ .size = 12, .color = theme.colors.on_surface_variant }));
    const sv = try widgets.scroll_view.scrollView(a, .{});
    const sv_col = try layout.column(a, .{ .gap = 4 });
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        var buf: [48]u8 = undefined;
        sv_col.add(try text_w.text(a, std.fmt.bufPrint(&buf, "ScrollView line {d} — wheel or drag to scroll", .{i}) catch "line", .{ .size = 13, .color = theme.colors.on_surface }));
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
    col.add(try text_w.text(a, title, .{ .size = 15, .bold = true, .color = theme.colors.on_surface_variant }));
    const card = try container_w.container(a, .{
        .color = theme.colors.surface_container,
        .radius = 12,
        .padding = EdgeInsets.all(12),
        .border_color = theme.colors.outline_variant,
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
    const card = container_w.container(a, .{ .color = ctx.theme.colors.surface_container_high, .radius = 6, .padding = .{ .left = 8, .top = 6, .right = 8, .bottom = 6 } }) catch @panic("klaxon: out of memory");
    const row = layout.row(a, .{ .gap = 8, .cross_align = .center }) catch @panic("klaxon: out of memory");
    row.add(icon_w.icon(a, .star, .{ .size = 14, .color = ctx.theme.colors.primary }) catch @panic("klaxon: out of memory"));
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Item #{d}", .{index}) catch "Item";
    row.add(text_w.text(a, label, .{ .size = 14, .color = ctx.theme.colors.on_surface }) catch @panic("klaxon: out of memory"));
    card.add(row);
    return card;
}

fn gridItem(userdata: ?*anyopaque, index: usize) *Node {
    const ctx: *ListItemCtx = @ptrCast(@alignCast(userdata.?));
    const a = ctx.allocator;
    const card = container_w.container(a, .{ .color = ctx.theme.colors.surface_container_high, .radius = 6 }) catch @panic("klaxon: out of memory");
    var buf: [24]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{d}", .{index}) catch "#";
    const c = layout.center(a) catch @panic("klaxon: out of memory");
    c.add(text_w.text(a, label, .{ .size = 13, .color = ctx.theme.colors.on_surface_variant }) catch @panic("klaxon: out of memory"));
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

fn cardPressCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.card_press.set(g.card_press.peek() + 1);
}

fn listItemPressCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.li_press.set(g.li_press.peek() + 1);
}

fn menuOpenCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.menu_open.set(!g.menu_open.peek()); // the anchor button toggles the menu
}

fn menuSelectCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.menu_select.set(g.menu_select.peek() + 1);
}

fn segChangeCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.seg_change.set(g.seg_change.peek() + 1);
}

fn splitPressCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.split_press.set(g.split_press.peek() + 1);
}

fn splitTrailCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.split_trail.set(g.split_trail.peek() + 1);
}

fn sbChangeCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.sb_change.set(g.sb_change.peek() + 1);
}

fn sbSubmitCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.sb_submit.set(g.sb_submit.peek() + 1);
}

fn nrChangeCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.nr_change.set(g.nr_change.peek() + 1);
}

fn nrExpChangeCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.nr_exp_change.set(g.nr_exp_change.peek() + 1);
}

fn ssToggleCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.ss_open.set(!g.ss_open.peek());
}

fn ssClosedCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.ss_closed.set(g.ss_closed.peek() + 1);
}

fn ptrRefreshCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.ptr_refresh.set(g.ptr_refresh.peek() + 1);
    // The refreshing signal is app-owned (Compose's isRefreshing contract):
    // the PTR sets it on trigger, the app clears it when the refresh
    // completes. The gallery's "refresh" is instant — the test models the
    // completion explicitly (a real app clears it when the data arrives).
}

fn chipCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    g.chip_sel.set(!g.chip_sel.peek()); // the Chip widget only fires callbacks
}

fn themeToggleCb(userdata: ?*anyopaque) void {
    const g = galleryOf(userdata);
    // the platform layer may have changed: sync the focus ring tokens
    if (ui.semantics.currentFocus()) |fm| {
        fm.ring_width = g.currentTheme().platform.focus_ring_width;
        fm.ring_offset = g.currentTheme().platform.focus_ring_offset;
    }
    g.rebuild() catch @panic("klaxon: out of memory");
    // notify the app (density presets changed: host.cursors, …)
    if (g.on_platform_changed) |cb| cb.fn_ptr(cb.userdata);
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

fn drawerOpenCb(userdata: ?*anyopaque) void {
    galleryOf(userdata).drawer_open.set(true);
}

fn sheetOpenCb(userdata: ?*anyopaque) void {
    galleryOf(userdata).sheet_open.set(true);
}

fn dialogOpenCb(userdata: ?*anyopaque) void {
    galleryOf(userdata).dialog_open.set(true);
}

fn snackShowCb(userdata: ?*anyopaque) void {
    galleryOf(userdata).snack_visible.set(true);
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
fn fmtDensity(v: bool, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} density", .{if (v) "Desktop" else "Mobile"}) catch "density";
}
fn fmtNavSel(v: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "NavBar selected: {d}", .{v}) catch "NavBar";
}
fn fmtTabsSel(v: usize, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Tabs selected: {d}", .{v}) catch "Tabs";
}
fn fmtDrawerOpen(v: bool, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Drawer {s}", .{if (v) "open" else "closed"}) catch "Drawer";
}

fn fmtRefreshing(v: bool, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "Refreshing {s}", .{if (v) "yes" else "no"}) catch "Refreshing";
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
    try std.testing.expectEqual(theme_mod.light.colors.surface, g.bg_sig.peek());
    // the fresh tree lays out clean and the list is still virtualized
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    try std.testing.expect(g.refs.list_10k.children.items.len < 20);
    // the transient state survived the rebuild
    try std.testing.expectEqualStrings("hello", input_w.textFieldText(g.refs.text_field));
    try std.testing.expectEqual(@as(f32, 120), widgets.scroll_view.scrollOffset(g.refs.scroll_view));
    try std.testing.expectEqual(@as(f32, 200), widgets.list_view.scrollOffset(g.refs.list_10k));
}

test "gallery: the density toggle switches to the desktop platform presets" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // mobile default: the scrollbars are classic (8dp of layout space)
    try std.testing.expectEqual(@as(f32, 8), g.refs.sb_list.measure(.{ .max_w = 400, .max_h = 260 }).w);
    try std.testing.expectEqual(theme_mod.Density.mobile, g.currentTheme().platform.density);
    // toggle the density (the header is above the scroll content)
    const b = g.refs.desktop_toggle.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 });
    try std.testing.expect(g.desktop_mode.peek());
    try std.testing.expectEqual(theme_mod.Density.desktop, g.currentTheme().platform.density);
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the rebuilt scrollbars are overlay: no layout space (macOS-style)
    try std.testing.expectEqual(@as(f32, 0), g.refs.sb_list.measure(.{ .max_w = 400, .max_h = 260 }).w);
    try std.testing.expectEqual(@as(f32, 0), g.refs.sb_grid.measure(.{ .max_w = 400, .max_h = 160 }).w);
    // the overlay track lands on the content's right edge (the stack is the
    // list's viewport): the hit zone covers the last 8dp of the list
    const lb = g.refs.list_10k.bounds;
    const hb = g.refs.sb_list.vtable.hit_bounds.?(g.refs.sb_list);
    try std.testing.expectEqual(lb.x + lb.w - 8, hb.x);
    try std.testing.expectEqual(lb.y, hb.y);
    try std.testing.expectEqual(@as(f32, 260), hb.h);
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

test "gallery: the M3E button fires its callback on click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Buttons (M3E) section sits below the Input section: scroll it into
    // the viewport (window = content - scroll_y)
    const b = g.refs.m3e_button.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const before = g.press_count.peek();
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(before + 1, g.press_count.peek());
}

test "gallery: the M3E icon toggle flips its signal on click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Icon buttons section sits below the Buttons section: scroll it in
    const b = g.refs.ib_heart.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expect(g.ib_toggles[0].peek()); // starts checked
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expect(!g.ib_toggles[0].peek()); // clicked -> unchecked
}

test "gallery: the M3E checkbox toggles its signal on click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Selection controls section sits below the Icon buttons section
    const b = g.refs.cb_m3e_btn.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expect(!g.cb_m3e.peek());
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expect(g.cb_m3e.peek()); // clicked -> checked
}

test "gallery: the M3E filter chip toggles its signal on click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Chips section sits below the Selection controls section
    const b = g.refs.chip_m3e_filter.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expect(!g.chip_filter.peek());
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expect(g.chip_filter.peek()); // clicked -> selected
    try std.testing.expectEqual(true, g.refs.chip_m3e_filter.semantics.?.checked.?); // a11y follows
}

test "gallery: the M3E text field takes focus, floats its label and accepts text" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Text fields section sits below the Chips section
    const b = g.refs.tf_m3e[0].bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    // the label starts expanded (centered in the 56dp container; labelRect is
    // in tree coordinates → relative to the field's y)
    try std.testing.expectEqual(@as(f32, 16), text_field_w.labelRect(g.refs.tf_m3e[0]).?.y - b.y);
    // click → focus → the label floats into the cutout
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expect(input_mod.isFocused(g.refs.tf_m3e[0]));
    try std.testing.expectEqual(@as(f32, -8), text_field_w.labelRect(g.refs.tf_m3e[0]).?.y - b.y);
    // type: the text + the a11y value follow
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Hi" });
    try std.testing.expectEqualStrings("Hi", text_field_w.text(g.refs.tf_m3e[0]));
    try std.testing.expectEqualStrings("Hi", g.refs.tf_m3e[0].semantics.?.value);
    // the label stays floated (the field holds text)
    try std.testing.expectEqual(@as(f32, -8), text_field_w.labelRect(g.refs.tf_m3e[0]).?.y - b.y);
}

test "gallery: the M3E text field's entry survives a theme switch" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const b = g.refs.tf_m3e[0].bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "typed" });
    try std.testing.expectEqualStrings("typed", text_field_w.text(g.refs.tf_m3e[0]));
    // toggle the theme (the header sits above the scroll content)
    const t = g.refs.theme_toggle.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = t.x + t.w / 2, .y = t.y + t.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = t.x + t.w / 2, .y = t.y + t.h / 2 });
    // the entry survived the rebuild
    try std.testing.expectEqualStrings("typed", text_field_w.text(g.refs.tf_m3e[0]));
}

test "gallery: the M3E card fires its callback on click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Cards section sits below the Text fields section
    const b = g.refs.card_m3e.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expectEqual(@as(u32, 0), g.card_press.peek());
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.card_press.peek());
}

test "gallery: the M3E list item fires on click; its selection follows the signal" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the List items section sits below the Cards section
    const b = g.refs.li_m3e.bounds;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, b.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expectEqual(@as(u32, 0), g.li_press.peek());
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.li_press.peek());
    // the selected item follows the external signal (a11y checked syncs)
    try std.testing.expectEqual(false, g.refs.li_m3e_sel.semantics.?.checked.?);
    g.li_selected.set(true);
    try std.testing.expectEqual(true, g.refs.li_m3e_sel.semantics.?.checked.?);
}

test "gallery: the M3E menu opens via the anchor, selects an item and closes" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Menus section sits below the List items section
    const m = g.refs.menu_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, m.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    // the anchor (the menu's first child) fills the menu's bounds: click it
    const ab = m.children.items[0].bounds;
    try std.testing.expect(!g.menu_open.peek());
    try std.testing.expect(!menu_w.isOpen(m));
    router.dispatchPointer(g.root, .{ .phase = .down, .x = ab.x + ab.w / 2, .y = ab.y + ab.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = ab.x + ab.w / 2, .y = ab.y + ab.h / 2 - sy });
    try std.testing.expect(g.menu_open.peek()); // opened via the anchor
    try std.testing.expect(menu_w.isOpen(m));
    try std.testing.expect(m.children.items[1].visible); // the item rows show
    // the panel's first item row sits below the anchor (overlay): click it
    const item0 = m.children.items[1].bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = item0.x + 10, .y = item0.y + item0.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = item0.x + 10, .y = item0.y + item0.h / 2 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.menu_select.peek()); // the selection fired
    try std.testing.expectEqual(@as(usize, 0), menu_w.selectedIndex(m));
    try std.testing.expect(!g.menu_open.peek()); // closed after the selection
    try std.testing.expect(!menu_w.isOpen(m));
    try std.testing.expect(!m.children.items[1].visible);
}

test "gallery: the M3E segmented button selects on click and follows the signal" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Segmented buttons section sits below the Menus section
    const m = g.refs.seg_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, m.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = m.bounds;
    // 3 equal segments overlapping by 1dp: the segment width from the total
    const w = (b.w + 2) / 3;
    try std.testing.expectEqual(@as(usize, 0), g.seg_selected.peek());
    // click the 3rd segment
    const x3 = b.x + 2 * (w - 1) + 10;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = x3, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = x3, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(@as(usize, 2), g.seg_selected.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(usize, 2), segmented_button_w.selectedIndex(m));
    try std.testing.expectEqual(@as(u32, 1), g.seg_change.peek()); // on_change fired
    // the external signal moves the selection (and the a11y value)
    g.seg_selected.set(0);
    try std.testing.expectEqual(@as(usize, 0), segmented_button_w.selectedIndex(m));
    try std.testing.expectEqualStrings("Day", m.semantics.?.value);
}

test "gallery: the M3E search bar takes focus, accepts text, submits and clears" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Search bar section sits below the Split buttons section
    const sb = g.refs.sb_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, sb.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = sb.bounds;
    try std.testing.expect(!input_mod.isFocused(sb));
    // click the pill → focus
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + 100, .y = b.y + b.h / 2 - sy, .raw_x = b.x + 100, .raw_y = b.y + b.h / 2 - sy });
    try std.testing.expect(input_mod.isFocused(sb));
    // type: the text mirrors the signal, the change counter fires
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "Hi" });
    try std.testing.expectEqualStrings("Hi", search_bar_w.text(sb));
    const v = g.sb_text.peek();
    try std.testing.expectEqualStrings("Hi", v[0..(std.mem.indexOfScalar(u8, &v, 0).?)]); // the signal round-trips
    try std.testing.expectEqual(@as(u32, 1), g.sb_change.peek());
    // Enter submits
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), g.sb_submit.peek());
    // the clear button (the trailing 48dp box) clears the text, keeps focus
    const cz = b.x + b.w - 48;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = cz + 24, .y = b.y + b.h / 2 - sy, .raw_x = cz + 24, .raw_y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = cz + 24, .y = b.y + b.h / 2 - sy, .raw_x = cz + 24, .raw_y = b.y + b.h / 2 - sy });
    try std.testing.expectEqualStrings("", search_bar_w.text(sb));
    try std.testing.expectEqual(@as(u32, 2), g.sb_change.peek());
    try std.testing.expect(input_mod.isFocused(sb)); // the focus is kept
    // the external signal replaces the text
    g.sb_text.set(search_bar_w.bufFromText("Ada"));
    try std.testing.expectEqualStrings("Ada", search_bar_w.text(sb));
    try std.testing.expectEqualStrings("Ada", sb.semantics.?.value);
}

test "gallery: the M3E search bar's entry survives a theme switch at full length" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    const sb = g.refs.sb_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, sb.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = sb.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + 100, .y = b.y + b.h / 2 - sy, .raw_x = b.x + 100, .raw_y = b.y + b.h / 2 - sy });
    // type a query LONGER than the 255-byte signal mirror
    var buf: [300]u8 = undefined;
    @memset(&buf, 'a');
    _ = router.dispatchKey(.{ .kind = .text_input, .text = &buf });
    try std.testing.expectEqual(@as(usize, 300), search_bar_w.text(sb).len);
    // toggle the theme (the header sits above the scroll content)
    const t = g.refs.theme_toggle.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = t.x + t.w / 2, .y = t.y + t.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = t.x + t.w / 2, .y = t.y + t.h / 2 });
    // the full entry survived the rebuild (not truncated to the mirror's 255)
    const txt = search_bar_w.text(g.refs.sb_m3e);
    try std.testing.expectEqual(@as(usize, 300), txt.len);
    try std.testing.expect(txt[0] == 'a' and txt[299] == 'a');
}

test "gallery: the M3E navigation rails select on click and follow the signal" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Navigation rail section sits below the Search bar section
    const nr = g.refs.nr_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, nr.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = nr.bounds;
    try std.testing.expectEqual(@as(usize, 0), g.nr_selected.peek());
    // click the 3rd item (y = bounds.y + 44 + 2*60 + 28, x = center)
    const y3 = b.y + 44 + 2 * 60 + 28 - sy;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + 48, .y = y3, .raw_x = b.x + 48, .raw_y = y3 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + 48, .y = y3, .raw_x = b.x + 48, .raw_y = y3 });
    try std.testing.expectEqual(@as(usize, 2), g.nr_selected.peek()); // the signal round-trips
    try std.testing.expectEqual(@as(usize, 2), navigation_rail_w.selectedIndex(nr));
    try std.testing.expectEqual(@as(u32, 1), g.nr_change.peek()); // on_change fired
    try std.testing.expectEqualStrings("Video", nr.semantics.?.value); // a11y follows
    // the external signal moves the selection
    g.nr_selected.set(0);
    try std.testing.expectEqual(@as(usize, 0), navigation_rail_w.selectedIndex(nr));
    // the expanded rail: click its 2nd item (same item rows)
    const ne = g.refs.nr_exp_m3e;
    const be = ne.bounds;
    const y2 = be.y + 44 + 60 + 28 - sy;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = be.x + 40, .y = y2, .raw_x = be.x + 40, .raw_y = y2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = be.x + 40, .y = y2, .raw_x = be.x + 40, .raw_y = y2 });
    try std.testing.expectEqual(@as(usize, 1), g.nr_exp_selected.peek());
    try std.testing.expectEqual(@as(usize, 1), navigation_rail_w.selectedIndex(ne));
    try std.testing.expectEqual(@as(u32, 1), g.nr_exp_change.peek());
    try std.testing.expectEqualStrings("Music", ne.semantics.?.value);
}

test "gallery: the M3E split button fires the leading + trailing callbacks" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Split buttons section sits below the Segmented buttons section
    const m = g.refs.split_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, m.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = m.bounds;
    try std.testing.expectEqual(@as(u32, 0), g.split_press.peek());
    try std.testing.expectEqual(@as(u32, 0), g.split_trail.peek());
    // click the leading half
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + 10, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + 10, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.split_press.peek());
    try std.testing.expectEqual(@as(u32, 0), g.split_trail.peek());
    // click the trailing half
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w - 10, .y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w - 10, .y = b.y + b.h / 2 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.split_press.peek());
    try std.testing.expectEqual(@as(u32, 1), g.split_trail.peek());
}

test "gallery: the M3E side sheet toggles via the button and closes on a scrim click" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Side sheet section sits below the Navigation rail section — scroll
    // to its toggle button (the sheet sits below it; both fit the viewport)
    const ss = g.refs.ss_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, g.refs.ss_btn.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = ss.bounds;
    try std.testing.expect(!g.ss_open.peek());
    // click the toggle button (the section's first row)
    const btn = g.refs.ss_btn.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = btn.x + btn.w / 2, .y = btn.y + btn.h / 2 - sy, .raw_x = btn.x + btn.w / 2, .raw_y = btn.y + btn.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = btn.x + btn.w / 2, .y = btn.y + btn.h / 2 - sy, .raw_x = btn.x + btn.w / 2, .raw_y = btn.y + btn.h / 2 - sy });
    try std.testing.expect(g.ss_open.peek()); // opened via the button
    // a scrim click (left of the panel, which docks to the right edge)
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + 20, .y = b.y + b.h / 2 - sy, .raw_x = b.x + 20, .raw_y = b.y + b.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + 20, .y = b.y + b.h / 2 - sy, .raw_x = b.x + 20, .raw_y = b.y + b.h / 2 - sy });
    try std.testing.expect(!g.ss_open.peek()); // closed via the scrim
    try std.testing.expectEqual(@as(u32, 1), g.ss_closed.peek()); // on_closed fired
}

test "gallery: the M3E pull-to-refresh triggers on a pull past the threshold" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // the Pull to refresh section sits below the Side sheet section
    const ptr = g.refs.ptr_m3e;
    const sv = g.refs.scroll_view;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, ptr.bounds.y - sv.bounds.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    const b = ptr.bounds;
    try std.testing.expect(!g.ptr_refreshing.peek());
    // pull down 100 at the top (past the 80dp threshold; the first move past
    // the top anchors the pull origin, the next one pulls)
    const x = b.x + b.w / 2;
    const y0 = b.y + 40;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = x, .y = y0 - sy, .raw_x = x, .raw_y = y0 - sy });
    router.dispatchPointer(g.root, .{ .phase = .move, .x = x, .y = y0 + 60 - sy, .raw_x = x, .raw_y = y0 + 60 - sy }); // anchor
    router.dispatchPointer(g.root, .{ .phase = .move, .x = x, .y = y0 + 160 - sy, .raw_x = x, .raw_y = y0 + 160 - sy }); // pull 100
    router.dispatchPointer(g.root, .{ .phase = .up, .x = x, .y = y0 + 160 - sy, .raw_x = x, .raw_y = y0 + 160 - sy });
    try std.testing.expectEqual(@as(u32, 1), g.ptr_refresh.peek()); // on_refresh fired
    try std.testing.expect(g.ptr_refreshing.peek()); // the signal round-trips
    try std.testing.expect(pull_to_refresh_w.adjusted(ptr) > 0); // the indicator holds at rest
    // the app clears the refreshing state (the refresh completed) → the
    // indicator hides, and a LATER pull triggers again (no stranded state)
    g.ptr_refreshing.set(false);
    try std.testing.expectEqual(@as(f32, 0), pull_to_refresh_w.adjusted(ptr));
    router.dispatchPointer(g.root, .{ .phase = .down, .x = x, .y = y0 - sy, .raw_x = x, .raw_y = y0 - sy });
    router.dispatchPointer(g.root, .{ .phase = .move, .x = x, .y = y0 + 60 - sy, .raw_x = x, .raw_y = y0 + 60 - sy }); // anchor
    router.dispatchPointer(g.root, .{ .phase = .move, .x = x, .y = y0 + 200 - sy, .raw_x = x, .raw_y = y0 + 200 - sy }); // pull 140
    router.dispatchPointer(g.root, .{ .phase = .up, .x = x, .y = y0 + 200 - sy, .raw_x = x, .raw_y = y0 + 200 - sy });
    try std.testing.expectEqual(@as(u32, 2), g.ptr_refresh.peek()); // the second pull fired too
    try std.testing.expect(g.ptr_refreshing.peek());
    g.ptr_refreshing.set(false);
}

test "gallery: navigation chrome — nav bar, tabs and drawer are wired" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // The ScrollView maps window coords through the scroll offset at hit-test
    // (window = content - scroll_y) and only its viewport is on screen. Font
    // metrics are platform-dependent, so the section's position is not —
    // scroll the nav bar to the top of the viewport before clicking.
    const sv = g.refs.scroll_view;
    const sv_b = sv.bounds;
    const nb = g.refs.nav_bar.bounds;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, nb.y - sv_b.y));
    const sy = widgets.scroll_view.scrollOffset(sv);
    // NavBar: click the 3rd destination
    const x3 = nb.x + nb.w * 2.5 / 4;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = x3, .y = nb.y + nb.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = x3, .y = nb.y + nb.h / 2 - sy });
    try std.testing.expectEqual(@as(usize, 2), g.nav_selected.peek());
    // Tabs: click the 2nd tab
    const tb = g.refs.tabs.bounds;
    const x2 = tb.x + tb.w * 1.5 / 3;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = x2, .y = tb.y + tb.h / 2 - sy });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = x2, .y = tb.y + tb.h / 2 - sy });
    try std.testing.expectEqual(@as(usize, 1), g.tabs_selected.peek());
    // Drawer: the open button opens it; a scrim click closes it. Bottom-align
    // the drawer box in the viewport so the button and the scrim are on screen.
    const dr = g.refs.drawer.bounds;
    _ = widgets.scroll_view.setScrollOffset(sv, @max(0.0, dr.y + dr.h - (sv_b.y + sv_b.h)));
    const sy2 = widgets.scroll_view.scrollOffset(sv);
    try std.testing.expect(!g.drawer_open.peek());
    const b = g.refs.drawer_btn.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = b.x + b.w / 2, .y = b.y + b.h / 2 - sy2 });
    try std.testing.expect(g.drawer_open.peek());
    // the panel is 360 wide on the start side: click the scrim right of it
    const sx = dr.x + dr.w - 20;
    const scrim_y = dr.y + 60 - sy2;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = sx, .y = scrim_y });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = sx, .y = scrim_y });
    try std.testing.expect(!g.drawer_open.peek());
}

test "gallery: feedback — tooltip, bottom sheet, dialog and snackbar are wired" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    var g = try Gallery.init(std.testing.allocator);
    defer g.deinit();
    g.root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(WINDOW_W), .h = @floatFromInt(WINDOW_H) });
    // The Feedback section sits below the fold. Font metrics are
    // platform-dependent, so each target is scrolled to the top of the
    // viewport before interaction (window = content - scroll_y).
    const scrollTo = struct {
        fn f(gg: *Gallery, y: f32) f32 {
            _ = widgets.scroll_view.setScrollOffset(gg.refs.scroll_view, @max(0.0, y - gg.refs.scroll_view.bounds.y));
            return widgets.scroll_view.scrollOffset(gg.refs.scroll_view);
        }
    }.f;
    // Tooltip: hover shows the bubble (the button is the anchor), leave hides
    // it. The bubble is the tooltip node's FIRST child (internal chrome).
    const tb = g.refs.tooltip_btn.bounds;
    const sy = scrollTo(g, tb.y);
    const tip = g.refs.tooltip_btn.parent.?; // the tooltip wrapper
    const bubble = tip.children.items[0];
    try std.testing.expect(!bubble.visible);
    router.dispatchPointer(g.root, .{ .phase = .move, .x = tb.x + tb.w / 2, .y = tb.y + tb.h / 2 - sy });
    try std.testing.expect(bubble.visible);
    // leave: move off the tree content (the header area)
    router.dispatchPointer(g.root, .{ .phase = .move, .x = 10, .y = 10 });
    try std.testing.expect(!bubble.visible);
    // Bottom sheet: the open button opens it; a scrim click closes it.
    const shb = g.refs.sheet_btn.bounds;
    const sy2 = scrollTo(g, shb.y);
    router.dispatchPointer(g.root, .{ .phase = .down, .x = shb.x + shb.w / 2, .y = shb.y + shb.h / 2 - sy2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = shb.x + shb.w / 2, .y = shb.y + shb.h / 2 - sy2 });
    try std.testing.expect(g.sheet_open.peek());
    const sh = g.refs.sheet.bounds;
    // the sheet is 240 high in the bounded box; the panel is bottom-anchored —
    // click the scrim near the top of the box
    router.dispatchPointer(g.root, .{ .phase = .down, .x = sh.x + sh.w / 2, .y = sh.y + 10 - sy2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = sh.x + sh.w / 2, .y = sh.y + 10 - sy2 });
    try std.testing.expect(!g.sheet_open.peek());
    // Dialog: the open button opens it; a scrim click (outside the centered
    // panel) closes it.
    const dlb = g.refs.dialog_btn.bounds;
    const sy3 = scrollTo(g, dlb.y);
    router.dispatchPointer(g.root, .{ .phase = .down, .x = dlb.x + dlb.w / 2, .y = dlb.y + dlb.h / 2 - sy3 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = dlb.x + dlb.w / 2, .y = dlb.y + dlb.h / 2 - sy3 });
    try std.testing.expect(g.dialog_open.peek());
    const dg = g.refs.dialog.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = dg.x + 10, .y = dg.y + 10 - sy3 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = dg.x + 10, .y = dg.y + 10 - sy3 });
    try std.testing.expect(!g.dialog_open.peek());
    // SnackBar: the show button reveals it (the snackbar overlays the window
    // bottom — its bounds are window coords, no scroll mapping); the dismiss
    // icon (last child) hides it.
    const snb = g.refs.snack_btn.bounds;
    const sy4 = scrollTo(g, snb.y);
    router.dispatchPointer(g.root, .{ .phase = .down, .x = snb.x + snb.w / 2, .y = snb.y + snb.h / 2 - sy4 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = snb.x + snb.w / 2, .y = snb.y + snb.h / 2 - sy4 });
    try std.testing.expect(g.snack_visible.peek());
    const snack = g.refs.snackbar;
    try std.testing.expect(snack.visible);
    const dismiss_btn = snack.children.items[snack.children.items.len - 1];
    const db = dismiss_btn.bounds;
    router.dispatchPointer(g.root, .{ .phase = .down, .x = db.x + db.w / 2, .y = db.y + db.h / 2 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = db.x + db.w / 2, .y = db.y + db.h / 2 });
    try std.testing.expect(!g.snack_visible.peek());
    // auto-dismiss: with a timeline the ticker hides it after timeout_ms
    // (the gallery snackbar uses the 4000ms M3 default)
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    router.dispatchPointer(g.root, .{ .phase = .down, .x = snb.x + snb.w / 2, .y = snb.y + snb.h / 2 - sy4 });
    router.dispatchPointer(g.root, .{ .phase = .up, .x = snb.x + snb.w / 2, .y = snb.y + snb.h / 2 - sy4 });
    try std.testing.expect(g.snack_visible.peek());
    tl.tick(0); // show tween start; the ticker arms the deadline (0 + 4000)
    tl.tick(250); // the slide tween (200ms) settled: shown
    try std.testing.expect(snack.visible);
    tl.tick(4001); // deadline passed: the snackbar hides itself
    try std.testing.expect(!g.snack_visible.peek());
    tl.tick(4300); // the hide tween settled
    try std.testing.expect(!snack.visible);
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
    try std.testing.expectEqual(theme_mod.dark.colors.surface, f.pixelAt(2, 2));
    try std.testing.expectEqual(theme_mod.dark.colors.surface_container, f.pixelAt(500, 70));
    // title ink inside the header card
    try std.testing.expect(f.countNotIn(.{ .x = 28, .y = 20, .w = 220, .h = 26 }, theme_mod.dark.colors.surface_container) > 0);
    // the Input section's accent button is visible below the header
    const b = g.refs.demo_button.bounds;
    try std.testing.expectEqual(theme_mod.dark.colors.primary, f.pixelAt(@intFromFloat(b.x + 4), @intFromFloat(b.y + b.h / 2)));
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
