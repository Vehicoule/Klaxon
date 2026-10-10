// Registry — widget registry + tree serialization (Phase 2d-0.6, no-code enabler).
//
// A tree Value: {"name": "column", "options": {...}, "children": [...]}. The
// registry maps names to widget factories; treeFromValue builds a live node
// tree from data, treeToValue describes a live tree back into data. The
// no-code designer (Phase 2e) edits the data; the framework renders it with
// the real widgets (WYSIWYG by construction).
//
// Ownership: BuildCtx owns (a) one options snapshot per built node — nodes
// BORROW option strings from their snapshot, so the tree must be deinit'd
// BEFORE ctx.reset/deinit — and (b) signals created for signal-driven
// widgets (toggle/checkbox/slider), which the widgets themselves do not own.
//
// Entries may define extra well-known option fields beyond the widget's
// options struct: "text" (text node), "icon" (icon node). They are preserved
// verbatim in the snapshot and round-trip unchanged.
const std = @import("std");
const ui = @import("ui.zig");
const value_mod = ui.value;
const Value = value_mod.Value;
const Node = ui.node.Node;
const state = ui.state;
const layout_w = @import("widgets/layout.zig");
const text_w = @import("widgets/text.zig");
const icon_w = @import("widgets/icon.zig");
const divider_w = @import("widgets/divider.zig");
const input_w = @import("widgets/input.zig");
const button_w = @import("widgets/button.zig");
const icon_button_w = @import("widgets/icon_button.zig");
const checkbox_w = @import("widgets/checkbox.zig");
const radio_w = @import("widgets/radio.zig");
const switch_w = @import("widgets/switch.zig");
const slider_w = @import("widgets/slider.zig");
const chip_w = @import("widgets/chip.zig");
const text_field_w = @import("widgets/text_field.zig");
const card_w = @import("widgets/card.zig");
const list_item_w = @import("widgets/list_item.zig");
const menu_w = @import("widgets/menu.zig");
const segmented_button_w = @import("widgets/segmented_button.zig");
const split_button_w = @import("widgets/split_button.zig");
const search_bar_w = @import("widgets/search_bar.zig");
const navigation_rail_w = @import("widgets/navigation_rail.zig");
const side_sheet_w = @import("widgets/side_sheet.zig");
const pull_to_refresh_w = @import("widgets/pull_to_refresh.zig");
const loading_indicator_w = @import("widgets/loading_indicator.zig");
const date_picker_w = @import("widgets/date_picker.zig");
const time_picker_w = @import("widgets/time_picker.zig");
const color_picker_w = @import("widgets/color_picker.zig");
const avatar_w = @import("widgets/avatar.zig");
const expansion_panel_w = @import("widgets/expansion_panel.zig");
const stepper_w = @import("widgets/stepper.zig");
const calendar_w = @import("widgets/calendar.zig");
const table_w = @import("widgets/table.zig");
const app_bar_w = @import("widgets/app_bar.zig");
const nav_bar_w = @import("widgets/nav_bar.zig");
const drawer_w = @import("widgets/drawer.zig");
const tabs_w = @import("widgets/tabs.zig");
const progress_w = @import("widgets/progress.zig");
const badge_w = @import("widgets/badge.zig");
const tooltip_w = @import("widgets/tooltip.zig");
const bottom_sheet_w = @import("widgets/bottom_sheet.zig");
const dialog_w = @import("widgets/dialog.zig");
const snackbar_w = @import("widgets/snackbar.zig");
const golden = @import("golden.zig"); // tests

/// Options type for widgets without options.
pub const NoOptions = struct {};

/// A live, signal-driven value that round-trips through serialization
/// (toggle/checkbox "checked", slider "value"): initialized from the options
/// on build, exported as the CURRENT signal value.
pub const LiveBinding = struct {
    signal: *anyopaque,
    field: []const u8, // well-known serialized field name
    /// Read the live value as an OWNED Value (strings are duped — Value.set
    /// takes ownership).
    read: *const fn (allocator: std.mem.Allocator, signal: *anyopaque) anyerror!Value,
};

pub const BuildResult = struct {
    node: *Node,
    live: ?LiveBinding = null,
    /// True when the node's children are internal chrome (e.g. the drawer's
    /// scrim/panel): the document has no children for this widget — content
    /// passes through option slots, preserved verbatim in the snapshot.
    skip_children: bool = false,
};

pub const BuildFn = *const fn (allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult;

pub const SchemaFn = *const fn (allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema;

pub const WidgetEntry = struct {
    name: []const u8,
    category: []const u8, // "layout" | "display" | "input" | ...
    build: BuildFn,
    schema: SchemaFn, // options type -> inspector schema (comptime-generated)
};

/// Registry: layout + display + input (v1) + navigation chrome (v2, batch
/// 2d.1 PR A: app_bar, nav_bar, drawer, tabs — M3E) + feedback batch
/// (2d.1 PR B: bottom_sheet, dialog, progress, badge, badged_box, tooltip,
/// snackbar — M3E) + buttons (2d.2 PR A: the M3E button replaces the P0
/// button entry — the P0 stays in widgets/input.zig for legacy use) + icon
/// button (2d.2 PR B1: M3E icon button, plain + toggle) + selection controls
/// (2d.2 PR B2: checkbox / radio / switch / slider M3E replace the P0
/// checkbox/toggle/slider entries — the P0 fixtures stay in input.zig) +
/// chips (2d.2 PR C1: the 5 M3E chip variants) + text field (2d.2 PR C2: the
/// M3E text field, filled / outlined) + cards (2d.3 PR D1: the 3 M3E card
/// variants) + list item (2d.3 PR D1: the M3E list item, 1-3 lines) +
/// menu (2d.3 PR D2: the M3E dropdown menu — anchor slot + item rows) +
/// segmented button (2d.3 PR D3: the M3E single-choice segmented button
/// row) + split button (2d.3 PR D3: the M3E split button, filled, 5 sizes) +
/// search bar (2d.3 PR D4: the M3E collapsed search bar — pill, text entry,
/// clear button) + navigation rail (2d.3 PR D4: the M3E navigation rail —
/// collapsed circle indicator / expanded pill, live selection) + side sheet
/// (2d.3 PR D5: the M3E side sheet — standard coplanar / modal + scrim,
/// start/end anchored) + pull-to-refresh (2d.3 PR D5: the M3E PTR container
/// — pull gesture + arc indicator, live refreshing signal).
/// Batch 1+ widgets self-register here.
pub const widgets = [_]WidgetEntry{
    .{ .name = "column", .category = "layout", .build = buildColumn, .schema = schemaColumn },
    .{ .name = "row", .category = "layout", .build = buildRow, .schema = schemaRow },
    .{ .name = "padding", .category = "layout", .build = buildPadding, .schema = schemaPadding },
    .{ .name = "center", .category = "layout", .build = buildCenter, .schema = schemaCenter },
    .{ .name = "constrained_box", .category = "layout", .build = buildConstrainedBox, .schema = schemaConstrainedBox },
    .{ .name = "divider", .category = "display", .build = buildDivider, .schema = schemaDivider },
    .{ .name = "text", .category = "display", .build = buildText, .schema = schemaText },
    .{ .name = "icon", .category = "display", .build = buildIcon, .schema = schemaIcon },
    .{ .name = "button", .category = "input", .build = buildButton, .schema = schemaButton },
    .{ .name = "icon_button", .category = "input", .build = buildIconButton, .schema = schemaIconButton },
    .{ .name = "switch", .category = "input", .build = buildSwitch, .schema = schemaSwitch },
    .{ .name = "checkbox", .category = "input", .build = buildCheckbox, .schema = schemaCheckbox },
    .{ .name = "radio", .category = "input", .build = buildRadio, .schema = schemaRadio },
    .{ .name = "slider", .category = "input", .build = buildSlider, .schema = schemaSlider },
    .{ .name = "chip", .category = "input", .build = buildChip, .schema = schemaChip },
    .{ .name = "text_field", .category = "input", .build = buildTextField, .schema = schemaTextField },
    .{ .name = "card", .category = "display", .build = buildCard, .schema = schemaCard },
    .{ .name = "list_item", .category = "display", .build = buildListItem, .schema = schemaListItem },
    .{ .name = "menu", .category = "display", .build = buildMenu, .schema = schemaMenu },
    .{ .name = "segmented_button", .category = "input", .build = buildSegmentedButton, .schema = schemaSegmentedButton },
    .{ .name = "split_button", .category = "input", .build = buildSplitButton, .schema = schemaSplitButton },
    .{ .name = "search_bar", .category = "input", .build = buildSearchBar, .schema = schemaSearchBar },
    .{ .name = "navigation_rail", .category = "navigation", .build = buildNavigationRail, .schema = schemaNavigationRail },
    .{ .name = "side_sheet", .category = "navigation", .build = buildSideSheet, .schema = schemaSideSheet },
    .{ .name = "pull_to_refresh", .category = "input", .build = buildPullToRefresh, .schema = schemaPullToRefresh },
    .{ .name = "loading_indicator", .category = "feedback", .build = buildLoadingIndicator, .schema = schemaLoadingIndicator },
    .{ .name = "date_picker", .category = "input", .build = buildDatePicker, .schema = schemaDatePicker },
    .{ .name = "time_picker", .category = "input", .build = buildTimePicker, .schema = schemaTimePicker },
    .{ .name = "color_picker", .category = "input", .build = buildColorPicker, .schema = schemaColorPicker },
    .{ .name = "avatar", .category = "display", .build = buildAvatar, .schema = schemaAvatar },
    .{ .name = "expansion_panel", .category = "layout", .build = buildExpansionPanel, .schema = schemaExpansionPanel },
    .{ .name = "stepper", .category = "navigation", .build = buildStepper, .schema = schemaStepper },
    .{ .name = "calendar", .category = "input", .build = buildCalendar, .schema = schemaCalendar },
    .{ .name = "table", .category = "display", .build = buildTable, .schema = schemaTable },
    .{ .name = "app_bar", .category = "navigation", .build = buildAppBar, .schema = schemaAppBar },
    .{ .name = "nav_bar", .category = "navigation", .build = buildNavBar, .schema = schemaNavBar },
    .{ .name = "drawer", .category = "navigation", .build = buildDrawer, .schema = schemaDrawer },
    .{ .name = "tabs", .category = "navigation", .build = buildTabs, .schema = schemaTabs },
    .{ .name = "bottom_sheet", .category = "navigation", .build = buildBottomSheet, .schema = schemaBottomSheet },
    .{ .name = "dialog", .category = "feedback", .build = buildDialog, .schema = schemaDialog },
    .{ .name = "progress", .category = "feedback", .build = buildProgress, .schema = schemaProgress },
    .{ .name = "badge", .category = "display", .build = buildBadge, .schema = schemaBadge },
    .{ .name = "badged_box", .category = "display", .build = buildBadgedBox, .schema = schemaBadgedBox },
    .{ .name = "tooltip", .category = "feedback", .build = buildTooltip, .schema = schemaTooltip },
    .{ .name = "snackbar", .category = "feedback", .build = buildSnackBar, .schema = schemaSnackBar },
};

pub fn byName(name: []const u8) ?WidgetEntry {
    for (widgets) |w| if (std.mem.eql(u8, w.name, name)) return w;
    return null;
}

// --- BuildCtx: owns snapshots + designer-created signals ---

pub const BuildCtx = struct {
    allocator: std.mem.Allocator,
    records: std.AutoHashMap(*Node, Record),
    tracked: std.array_list.Managed(Tracked),
    journal: std.array_list.Managed(JournalEntry), // per-build rollback log
    /// Radio groups: radios sharing a "group" name share ONE selection
    /// signal (a group = one selection). The keys are owned dupes.
    radio_groups: std.StringHashMap(*state.Signal(usize)),

    const Record = struct {
        entry_name: []const u8,
        opts: Value, // owned snapshot — nodes borrow strings from it
        live: ?LiveBinding = null,
        skip_children: bool = false,
    };
    const Tracked = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque) void, // Signal.deinit frees itself
    };
    const JournalEntry = union(enum) {
        record: *Node,
        signal: Tracked,
    };

    pub fn init(allocator: std.mem.Allocator) BuildCtx {
        return .{
            .allocator = allocator,
            .records = std.AutoHashMap(*Node, Record).init(allocator),
            .tracked = std.array_list.Managed(Tracked).init(allocator),
            .journal = std.array_list.Managed(JournalEntry).init(allocator),
            .radio_groups = std.StringHashMap(*state.Signal(usize)).init(allocator),
        };
    }

    pub fn deinit(ctx: *BuildCtx) void {
        ctx.clear();
        ctx.records.deinit();
        ctx.tracked.deinit();
        ctx.journal.deinit();
        ctx.radio_groups.deinit();
    }

    /// Free every record + tracked allocation; the ctx stays usable. The tree
    /// built from this ctx must be deinit'd FIRST (records key live nodes).
    pub fn reset(ctx: *BuildCtx) void {
        ctx.clear();
    }

    fn clear(ctx: *BuildCtx) void {
        var it = ctx.records.valueIterator();
        while (it.next()) |rec| rec.opts.deinit(ctx.allocator);
        ctx.records.clearRetainingCapacity();
        var git = ctx.radio_groups.keyIterator();
        while (git.next()) |k| ctx.allocator.free(k.*);
        ctx.radio_groups.clearRetainingCapacity(); // the signals live in `tracked`
        for (ctx.tracked.items) |t| t.deinit_fn(t.ptr);
        ctx.tracked.clearRetainingCapacity();
        ctx.journal.clearRetainingCapacity();
    }

    /// Undo every record/signal created after `mark` — a failed build leaves
    /// no stale records keyed by dead nodes (their addresses can be reused).
    fn rollback(ctx: *BuildCtx, mark: usize) void {
        while (ctx.journal.items.len > mark) {
            const e = ctx.journal.pop() orelse break;
            switch (e) {
                .record => |n| {
                    if (ctx.records.fetchRemove(n)) |kv| kv.value.opts.deinit(ctx.allocator);
                },
                .signal => |t| {
                    for (ctx.tracked.items, 0..) |tr, i| {
                        if (tr.ptr == t.ptr) {
                            _ = ctx.tracked.swapRemove(i);
                            break;
                        }
                    }
                    t.deinit_fn(t.ptr);
                },
            }
        }
    }

    fn track(ctx: *BuildCtx, ptr: *anyopaque, deinit_fn: *const fn (*anyopaque) void) !void {
        const t = Tracked{ .ptr = ptr, .deinit_fn = deinit_fn };
        try ctx.tracked.append(t);
        ctx.journal.append(.{ .signal = t }) catch {
            deinit_fn(ptr);
            _ = ctx.tracked.pop();
        };
    }

    /// Stores the snapshot + live binding (owns `opts` — frees it on failure).
    fn recordAdopt(ctx: *BuildCtx, n: *Node, entry_name: []const u8, opts: Value, live: ?LiveBinding, skip_children: bool) !void {
        ctx.records.put(n, .{ .entry_name = entry_name, .opts = opts, .live = live, .skip_children = skip_children }) catch |e| {
            opts.deinit(ctx.allocator);
            return e;
        };
        ctx.journal.append(.{ .record = n }) catch |e| {
            if (ctx.records.fetchRemove(n)) |kv| kv.value.opts.deinit(ctx.allocator);
            return e;
        };
    }
};

// --- tree <-> data ---

pub fn treeFromValue(ctx: *BuildCtx, v: Value) !*Node {
    const mark = ctx.journal.items.len;
    return treeFromValueInner(ctx, v) catch |e| {
        ctx.rollback(mark); // failed build: no stale records/signals
        return e;
    };
}

fn treeFromValueInner(ctx: *BuildCtx, v: Value) !*Node {
    const name_v = v.get("name") orelse return error.MissingName;
    const name = switch (name_v) {
        .string => |s| s,
        else => return error.ExpectedString,
    };
    const entry = byName(name) orelse return error.UnknownWidget;
    var opts = v.get("options") orelse Value.null;
    if (opts == .null) opts = .{ .object = &.{} }; // absent/null options = all defaults
    // The snapshot backs the node's borrowed strings — build from the
    // ctx-owned copy, not from the caller's Value.
    const snapshot = try opts.dupe(ctx.allocator);
    const res = entry.build(ctx.allocator, snapshot, ctx) catch |e| {
        snapshot.deinit(ctx.allocator); // build failed: no record yet
        return e;
    };
    const node = res.node;
    errdefer node.deinit();
    try ctx.recordAdopt(node, entry.name, snapshot, res.live, res.skip_children);
    if (v.get("children")) |c| {
        // Slot widgets (app_bar, drawer) own their children as internal
        // chrome: document children would build but never serialize
        // (treeToValue skips them) — reject instead of losing them silently.
        if (res.skip_children) return error.ChildrenNotSupported;
        switch (c) {
            .array => |arr| for (arr) |cv| {
                const child = try treeFromValueInner(ctx, cv);
                node.add(child);
            },
            else => return error.ExpectedArray,
        }
    }
    return node;
}

pub fn treeToValue(ctx: *BuildCtx, root: *Node, allocator: std.mem.Allocator) !Value {
    const rec = ctx.records.get(root) orelse return error.UnregisteredNode;
    var fields = std.array_list.Managed(value_mod.Field).init(allocator);
    errdefer {
        for (fields.items) |f| {
            allocator.free(f.name); // names are owned (duped below)
            f.value.deinit(allocator);
        }
        fields.deinit();
    }
    try fields.append(.{ .name = try allocator.dupe(u8, "name"), .value = .{ .string = try allocator.dupe(u8, rec.entry_name) } });
    // Canonical form: empty options / children are omitted (round-trip
    // exact) — unless a live value must round-trip: signal widgets always
    // carry their current value.
    if (rec.live) |lb| {
        var obj = if (rec.opts == .object) try rec.opts.dupe(allocator) else Value{ .object = &.{} };
        try obj.set(allocator, lb.field, try lb.read(allocator, lb.signal));
        try fields.append(.{ .name = try allocator.dupe(u8, "options"), .value = obj });
    } else if (rec.opts == .object and rec.opts.object.len > 0) {
        try fields.append(.{ .name = try allocator.dupe(u8, "options"), .value = try rec.opts.dupe(allocator) });
    }
    var children = std.array_list.Managed(Value).init(allocator);
    errdefer {
        for (children.items) |c| c.deinit(allocator);
        children.deinit();
    }
    if (!rec.skip_children) {
        for (root.children.items) |child| {
            if (child.internal) continue; // widget-owned chrome, not document data
            try children.append(try treeToValue(ctx, child, allocator));
        }
    }
    if (children.items.len > 0) {
        const children_slice = try children.toOwnedSlice();
        fields.append(.{ .name = try allocator.dupe(u8, "children"), .value = .{ .array = children_slice } }) catch |e| {
            allocator.free(children_slice);
            return e;
        };
    }
    return .{ .object = try fields.toOwnedSlice() };
}

pub fn treeFromJson(ctx: *BuildCtx, allocator: std.mem.Allocator, json: []const u8) !*Node {
    const v = try value_mod.parseJson(allocator, json);
    defer v.deinit(allocator);
    return treeFromValue(ctx, v);
}

pub fn treeToJson(ctx: *BuildCtx, root: *Node, allocator: std.mem.Allocator) ![]u8 {
    const v = try treeToValue(ctx, root, allocator);
    defer v.deinit(allocator);
    return value_mod.toJson(allocator, v);
}

// --- per-widget build wrappers ---

fn buildColumn(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    return .{ .node = try layout_w.column(allocator, try value_mod.optionsFromValue(layout_w.FlexOptions, opts, null, null)) };
}

fn buildRow(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    return .{ .node = try layout_w.row(allocator, try value_mod.optionsFromValue(layout_w.FlexOptions, opts, null, null)) };
}

fn buildPadding(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    return .{ .node = try layout_w.padding(allocator, try value_mod.optionsFromValue(ui.layout.EdgeInsets, opts, null, null)) };
}

fn buildCenter(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = opts;
    _ = ctx;
    return .{ .node = try layout_w.center(allocator) };
}

fn buildConstrainedBox(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    return .{ .node = try layout_w.constrainedBox(allocator, try value_mod.optionsFromValue(layout_w.ConstrainedBoxOptions, opts, null, null)) };
}

fn buildDivider(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    return .{ .node = try divider_w.divider(allocator, try value_mod.optionsFromValue(divider_w.DividerOptions, opts, null, null)) };
}

fn buildText(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const topts = try value_mod.optionsFromValue(text_w.TextOptions, opts, null, null);
    const str: []const u8 = if (opts.get("text")) |t| switch (t) {
        .string => |s| s,
        else => "",
    } else "";
    return .{ .node = try text_w.text(allocator, str, topts) };
}

fn buildIcon(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const iopts = try value_mod.optionsFromValue(icon_w.IconOptions, opts, null, null);
    const name_str: []const u8 = if (opts.get("icon")) |t| switch (t) {
        .string => |s| s,
        else => "star",
    } else "star";
    const iname = std.meta.stringToEnum(icon_w.IconName, name_str) orelse return error.UnknownIcon;
    return .{ .node = try icon_w.icon(allocator, iname, iopts) };
}

/// M3E button (2d.2 PR A): the label and icon are data fields in the
/// options (built as internal chrome by the factory) — document children
/// would never serialize.
fn buildButton(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const bopts = try value_mod.optionsFromValue(button_w.ButtonOptions, opts, null, null);
    return .{ .node = try button_w.button(allocator, null, bopts), .skip_children = true };
}

/// M3E icon button (2d.2 PR B1): a "selected" option makes it a toggle (a
/// ctx-owned bool signal drives the checked state); without it, a plain
/// button. The icon is internal chrome — document children never serialize.
fn buildIconButton(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const iopts = try value_mod.optionsFromValue(icon_button_w.IconButtonOptions, opts, null, null);
    if (opts.get("selected") != null) {
        const sig = try buildBoolSignal(allocator, opts, ctx, "selected");
        const n = try icon_button_w.iconButton(allocator, sig, null, iopts);
        return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readBoolSignal }, .skip_children = true };
    }
    return .{ .node = try icon_button_w.iconButton(allocator, null, null, iopts), .skip_children = true };
}

/// M3E switch (2d.2 PR B2, replaces the P0 toggle entry): a "checked" option
/// drives a ctx-owned bool signal.
fn buildSwitch(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(switch_w.SwitchOptions, opts, null, null);
    const sig = try buildBoolSignal(allocator, opts, ctx, "checked");
    const n = try switch_w.@"switch"(allocator, sig, null, sopts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "checked", .read = readBoolSignal } };
}

fn readBoolSignal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(bool) = @ptrCast(@alignCast(p));
    return .{ .bool = s.peek() };
}

fn deinitBoolSignal(p: *anyopaque) void {
    const s: *state.Signal(bool) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

/// M3E checkbox (2d.2 PR B2, replaces the P0 checkbox entry): a "checked"
/// option drives a ctx-owned bool signal.
fn buildCheckbox(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const copts = try value_mod.optionsFromValue(checkbox_w.CheckboxOptions, opts, null, null);
    const sig = try buildBoolSignal(allocator, opts, ctx, "checked");
    const n = try checkbox_w.checkbox(allocator, sig, null, copts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "checked", .read = readBoolSignal } };
}

/// M3E radio (2d.2 PR B2, new entry): an "index" option + a "selected" signal
/// (the group value; checked = selected == index). Radios sharing a "group"
/// name share ONE selection signal (a group = one selection).
fn buildRadio(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const ropts = try value_mod.optionsFromValue(radio_w.RadioOptions, opts, null, null);
    const index: u32 = if (opts.get("index")) |x| switch (x) {
        .int => |i| std.math.cast(u32, i) orelse return error.ValueOutOfRange,
        .float => |f| blk: {
            if (!std.math.isFinite(f) or f < 0) return error.ValueOutOfRange;
            break :blk std.math.cast(u32, @as(i128, @intFromFloat(@trunc(f)))) orelse return error.ValueOutOfRange;
        },
        else => 0,
    } else 0;
    const group: []const u8 = if (opts.get("group")) |g| switch (g) {
        .string => |s| s,
        else => "default",
    } else "default";
    const sig = blk: {
        if (ctx.radio_groups.get(group)) |s| break :blk s; // shared group signal
        const s = try buildUsizeSignal(allocator, opts, ctx); // "selected"
        ctx.radio_groups.put(try allocator.dupe(u8, group), s) catch |e| {
            s.deinit();
            return e;
        };
        break :blk s;
    };
    const n = try radio_w.radio(allocator, sig, index, ropts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readUsizeSignal } };
}

/// M3E slider (2d.2 PR B2, replaces the P0 slider entry): a "value" option
/// drives a ctx-owned f32 signal (0..1).
fn buildSlider(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(slider_w.SliderOptions, opts, null, null);
    const val: f32 = if (opts.get("value")) |x| switch (x) {
        .float => |f| @floatCast(f),
        .int => |i| @floatFromInt(i),
        else => 0.5,
    } else 0.5;
    const sig = try state.Signal(f32).init(allocator, val); // *Signal(f32)
    try ctx.track(sig, deinitF32Signal);
    const n = try slider_w.slider(allocator, sig, null, sopts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "value", .read = readF32Signal } };
}

fn readF32Signal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(f32) = @ptrCast(@alignCast(p));
    return .{ .float = s.peek() };
}

fn deinitF32Signal(p: *anyopaque) void {
    const s: *state.Signal(f32) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

/// M3E chip (2d.2 PR C1): a "selected" option makes it a toggle (a ctx-owned
/// bool signal drives the selected state); without it, an action chip (or a
/// fixed selected state). The label and icons are internal chrome — document
/// children never serialize.
fn buildChip(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const copts = try value_mod.optionsFromValue(chip_w.ChipOptions, opts, null, null);
    // a null "selected" means the field default (an action chip), not a toggle
    const has_selected = if (opts.get("selected")) |v| v != .null else false;
    if (has_selected) {
        const sig = try buildBoolSignal(allocator, opts, ctx, "selected");
        const n = try chip_w.chip(allocator, sig, null, copts);
        return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readBoolSignal }, .skip_children = true };
    }
    return .{ .node = try chip_w.chip(allocator, null, null, copts), .skip_children = true };
}

/// M3E text field (2d.2 PR C2): every registry field is editable, so every
/// field gets a live binding — the serialized text is always the CURRENT
/// buffer, read losslessly from the node (the fixed-size signal is only the
/// two-way channel; reading it would truncate past 255 bytes). The live field
/// is "value" when the document has one, "initial" when it only has that,
/// else "value" (materialized on save — the checkbox convention). The widget
/// is a leaf — document children never serialize.
fn buildTextField(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const topts = try value_mod.optionsFromValue(text_field_w.TextFieldOptions, opts, null, null);
    const value_v = opts.get("value");
    const initial_v = opts.get("initial");
    const has_value = value_v != null and value_v.? != .null;
    const has_initial = initial_v != null and initial_v.? != .null;
    const field: []const u8 = if (has_value) "value" else if (has_initial) "initial" else "value";
    const initial: []const u8 = if (has_value)
        switch (value_v.?) {
            .string => |s| s,
            else => "",
        }
    else if (has_initial)
        switch (initial_v.?) {
            .string => |s| s,
            else => "",
        }
    else
        "";
    const sig = try state.Signal(text_field_w.TextBuf).init(allocator, text_field_w.bufFromText(initial));
    try ctx.track(sig, deinitTextSignal);
    const n = try text_field_w.textField(allocator, sig, null, null, topts);
    // The signal mirror caps at 255 bytes (TextBuf = [256]u8, the two-way
    // channel); the buffer is lossless — re-seed it when the initial text
    // exceeds the mirror.
    if (initial.len >= 256) text_field_w.setText(n, initial);
    return .{ .node = n, .live = .{ .signal = @ptrCast(n), .field = field, .read = readTextFieldNode } };
}

/// The live text: the widget's CURRENT buffer (lossless), as an owned string.
fn readTextFieldNode(allocator: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const n: *Node = @ptrCast(@alignCast(p));
    return .{ .string = try allocator.dupe(u8, text_field_w.text(n)) }; // owned (Value.set takes ownership)
}

/// M3E search bar (2d.3 PR D4): a leaf — the pill is internal chrome. The
/// text is ALWAYS live (like the text field, PR #26): the "value" (or
/// "initial") option seeds a TextBuf signal mirrored both ways; the current
/// text round-trips. The live read is the widget's buffer (lossless — the
/// signal mirror caps at 255 bytes, TextBuf = [256]u8).
fn buildSearchBar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(search_bar_w.SearchBarOptions, opts, null, null);
    const value_v = opts.get("value");
    const initial_v = opts.get("initial");
    const has_value = value_v != null and value_v.? != .null;
    const has_initial = initial_v != null and initial_v.? != .null;
    const field: []const u8 = if (has_value) "value" else if (has_initial) "initial" else "value";
    const initial: []const u8 = if (has_value)
        switch (value_v.?) {
            .string => |s| s,
            else => "",
        }
    else if (has_initial)
        switch (initial_v.?) {
            .string => |s| s,
            else => "",
        }
    else
        "";
    const sig = try state.Signal(search_bar_w.TextBuf).init(allocator, search_bar_w.bufFromText(initial));
    try ctx.track(sig, deinitTextSignal);
    const n = try search_bar_w.searchBar(allocator, sig, null, null, sopts);
    // The signal mirror caps at 255 bytes (TextBuf = [256]u8, the two-way
    // channel); the buffer is lossless — re-seed it when the initial text
    // exceeds the mirror.
    if (initial.len >= 256) search_bar_w.setText(n, initial);
    return .{ .node = n, .live = .{ .signal = @ptrCast(n), .field = field, .read = readSearchBarNode } };
}

/// The live search bar text: the widget's CURRENT buffer (lossless).
fn readSearchBarNode(allocator: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const n: *Node = @ptrCast(@alignCast(p));
    return .{ .string = try allocator.dupe(u8, search_bar_w.text(n)) }; // owned (Value.set takes ownership)
}

/// M3E card (2d.3 PR D1): a container — the children ARE document data.
fn buildCard(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const copts = try value_mod.optionsFromValue(card_w.CardOptions, opts, null, null);
    return .{ .node = try card_w.card(allocator, null, copts) };
}

/// M3E list item (2d.3 PR D1): a "selected" option drives a ctx-owned bool
/// signal (selection is external — the document's children never serialize:
/// the chrome is built from the options).
fn buildListItem(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const lopts = try value_mod.optionsFromValue(list_item_w.ListItemOptions, opts, null, null);
    // a null "selected" means the field default (unselected, fixed)
    const has_selected = if (opts.get("selected")) |v| v != .null else false;
    if (has_selected) {
        const sig = try buildBoolSignal(allocator, opts, ctx, "selected");
        const n = try list_item_w.listItem(allocator, sig, null, lopts);
        return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readBoolSignal }, .skip_children = true };
    }
    return .{ .node = try list_item_w.listItem(allocator, null, null, lopts), .skip_children = true };
}

/// M3E dropdown menu (2d.3 PR D2): the anchor is a factory slot (a subtree
/// document); the item rows are internal chrome — document children never
/// serialize. A non-null "open" option drives a ctx-owned bool signal (the
/// live open state round-trips). "items" is an option array parsed manually
/// (optionsFromValue cannot map []MenuItem).
fn buildMenu(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const mopts = try value_mod.optionsFromValue(menu_w.MenuOptions, opts, null, null);
    const anchor = try buildSlotNode(ctx, opts.get("anchor") orelse return error.MissingSlot);
    errdefer anchor.deinit();
    const items = try parseMenuItems(allocator, opts.get("items") orelse Value.null);
    errdefer allocator.free(items);
    const has_open = if (opts.get("open")) |v| v != .null else false;
    if (has_open) {
        const sig = try buildBoolSignal(allocator, opts, ctx, "open");
        const n = try menu_w.menu(allocator, anchor, items, sig, null, mopts);
        allocator.free(items); // the factory copies the strings
        return .{ .node = n, .live = .{ .signal = sig, .field = "open", .read = readBoolSignal }, .skip_children = true };
    }
    const n = try menu_w.menu(allocator, anchor, items, null, null, mopts);
    allocator.free(items); // the factory copies the strings
    return .{ .node = n, .skip_children = true };
}

/// Parse the "items" option: an array of {label, leading_icon?,
/// trailing_text?, enabled?} objects. The strings are BORROWED from the
/// options snapshot (the menu factory copies them).
fn parseMenuItems(allocator: std.mem.Allocator, v: Value) ![]menu_w.MenuItem {
    switch (v) {
        .null => return allocator.alloc(menu_w.MenuItem, 0),
        .array => |arr| {
            const items = try allocator.alloc(menu_w.MenuItem, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |iv, i| {
                if (iv != .object) return error.ExpectedObject;
                const label: []const u8 = if (iv.get("label")) |lv| switch (lv) {
                    .string => |s| s,
                    else => "",
                } else "";
                const leading: ?icon_w.IconName = if (iv.get("leading_icon")) |lv| switch (lv) {
                    .string => |s| std.meta.stringToEnum(icon_w.IconName, s) orelse return error.UnknownIcon,
                    else => null,
                } else null;
                const trailing: []const u8 = if (iv.get("trailing_text")) |tv| switch (tv) {
                    .string => |s| s,
                    else => "",
                } else "";
                const enabled: bool = if (iv.get("enabled")) |ev| switch (ev) {
                    .bool => |b| b,
                    else => true,
                } else true;
                items[i] = .{ .label = label, .leading_icon = leading, .trailing_text = trailing, .enabled = enabled };
            }
            return items;
        },
        else => return error.ExpectedArray,
    }
}

/// M3E segmented button (2d.3 PR D3): the segments are internal chrome —
/// document children never serialize. The selection is ALWAYS live (like
/// the text field, PR #26): a plain document keeps the default 0 and clicks
/// round-trip. "items" is an option array parsed manually (optionsFromValue
/// cannot map []SegmentedItem).
fn buildSegmentedButton(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(segmented_button_w.SegmentedButtonOptions, opts, null, null);
    const items = try parseSegmentedItems(allocator, opts.get("items") orelse Value.null);
    errdefer allocator.free(items);
    const sig = try buildUsizeSignal(allocator, opts, ctx); // "selected" (default 0)
    const n = try segmented_button_w.segmentedButton(allocator, items, sig, null, sopts);
    allocator.free(items); // the factory copies the labels
    return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readUsizeSignal }, .skip_children = true };
}

/// Parse the "items" option: an array of {label, icon?, enabled?} objects.
/// The strings are BORROWED from the options snapshot (the factory copies
/// them).
fn parseSegmentedItems(allocator: std.mem.Allocator, v: Value) ![]segmented_button_w.SegmentedItem {
    switch (v) {
        .null => return allocator.alloc(segmented_button_w.SegmentedItem, 0),
        .array => |arr| {
            const items = try allocator.alloc(segmented_button_w.SegmentedItem, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |iv, i| {
                if (iv != .object) return error.ExpectedObject;
                const label: []const u8 = if (iv.get("label")) |lv| switch (lv) {
                    .string => |s| s,
                    else => "",
                } else "";
                const icon: ?icon_w.IconName = if (iv.get("icon")) |lv| switch (lv) {
                    .string => |s| std.meta.stringToEnum(icon_w.IconName, s) orelse return error.UnknownIcon,
                    else => null,
                } else null;
                const enabled: bool = if (iv.get("enabled")) |ev| switch (ev) {
                    .bool => |b| b,
                    else => true,
                } else true;
                items[i] = .{ .label = label, .icon = icon, .enabled = enabled };
            }
            return items;
        },
        else => return error.ExpectedArray,
    }
}

/// M3E split button (2d.3 PR D3): a leaf — the two halves are internal
/// chrome (the label/icon are options data); document children never
/// serialize. Clicks are app callbacks (not serializable).
fn buildSplitButton(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const sopts = try value_mod.optionsFromValue(split_button_w.SplitButtonOptions, opts, null, null);
    return .{ .node = try split_button_w.splitButton(allocator, null, null, sopts), .skip_children = true };
}

/// M3E navigation rail (2d.3 PR D4): the items are internal chrome —
/// document children never serialize. The selection is ALWAYS live (like
/// the segmented button, PR #29): a plain document keeps the default 0 and
/// clicks round-trip. "items" is an option array parsed manually
/// (optionsFromValue cannot map []NavRailItem).
fn buildNavigationRail(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const ropts = try value_mod.optionsFromValue(navigation_rail_w.NavigationRailOptions, opts, null, null);
    const items = try parseNavRailItems(allocator, opts.get("items") orelse Value.null);
    errdefer allocator.free(items);
    const sig = try buildUsizeSignal(allocator, opts, ctx); // "selected" (default 0)
    const n = try navigation_rail_w.navigationRail(allocator, items, sig, null, ropts);
    allocator.free(items); // the factory copies the labels
    return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readUsizeSignal }, .skip_children = true };
}

/// M3E side sheet (2d.3 PR D5): like the bottom sheet — the body/content
/// are factory slots (subtree documents); the node's children (body slot +
/// internal scrim/panel) are not document children. "open" is ALWAYS live
/// (round-trips, like bottom_sheet).
fn buildSideSheet(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(side_sheet_w.SideSheetOptions, opts, buildSlotNode, ctx);
    errdefer deinitSlot2(sopts.content, sopts.body);
    const sig = try buildBoolSignal(allocator, opts, ctx, "open");
    const n = try side_sheet_w.sideSheet(allocator, sig, null, sopts);
    // the node's children (body slot + internal scrim/panel) are not document
    // children — content passes through the option slots
    return .{ .node = n, .live = .{ .signal = sig, .field = "open", .read = readBoolSignal }, .skip_children = true };
}

/// M3E pull-to-refresh (2d.3 PR D5): a container — the content IS a document
/// child (attached by the framework after the build, like nav_bar's items).
/// "refreshing" is ALWAYS live (round-trips).
fn buildPullToRefresh(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const popts = try value_mod.optionsFromValue(pull_to_refresh_w.PullToRefreshOptions, opts, null, null);
    const sig = try buildBoolSignal(allocator, opts, ctx, "refreshing");
    const n = try pull_to_refresh_w.pullToRefresh(allocator, sig, null, popts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "refreshing", .read = readBoolSignal } };
}

/// M3E loading indicator (2d.4 PR #32): a LEAF (skip_children — a document
/// child would be accepted but never laid out). "progress" (0..1) present AND
/// non-null → determinate (a ctx-owned f32 signal, ALWAYS live — round-trips);
/// absent or explicit null → the indeterminate morph loop (no live field; an
/// explicit null round-trips unchanged).
fn buildLoadingIndicator(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const lopts = try value_mod.optionsFromValue(loading_indicator_w.LoadingIndicatorOptions, opts, null, null);
    const determinate = if (opts.get("progress")) |v| switch (v) {
        .null => false, // explicit null = indeterminate (kept in the snapshot)
        else => true,
    } else false;
    if (determinate) {
        const val: f32 = switch (opts.get("progress").?) {
            .float => |f| @floatCast(f),
            .int => |i| @floatFromInt(i),
            else => 0.5,
        };
        const sig = try state.Signal(f32).init(allocator, val); // *Signal(f32)
        try ctx.track(sig, deinitF32Signal);
        const n = try loading_indicator_w.loadingIndicator(allocator, sig, lopts);
        return .{ .node = n, .live = .{ .signal = sig, .field = "progress", .read = readF32Signal }, .skip_children = true };
    }
    const n = try loading_indicator_w.loadingIndicator(allocator, null, lopts);
    return .{ .node = n, .skip_children = true };
}

/// A checked float→int conversion for option values: truncates toward zero
/// and rejects non-finite values and values outside the target type's range
/// (a finite float beyond i128 would trap @intFromFloat, so the bounds are
/// checked in f64 first — every i32 is exact in f64, and i64's max + 1 rounds
/// to the exact 2^63 boundary).
fn floatToInt(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (t < @as(f64, @floatFromInt(std.math.minInt(T)))) return null;
    if (t >= @as(f64, @floatFromInt(std.math.maxInt(T))) + 1) return null;
    return @intFromFloat(t);
}

/// M3E date picker (2d.4 PR #33): a LEAF panel (skip_children).
/// "selected" is ALWAYS live (a Signal(?i64) of UTC epoch days; null = no
/// selection — round-trips). "displayed" is the INITIAL displayed month (not
/// live — transient UI state): the option, else the month of
/// (selected ?? today). "today" is injected (else the system clock, UTC).
/// All three days are clamped to the supported civil-date range (1900..2100)
/// and "displayed" is normalized to the month's 1st.
fn buildDatePicker(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const dopts = try value_mod.optionsFromValue(date_picker_w.DatePickerOptions, opts, null, null);
    const sel = try buildOptI64Signal(allocator, opts, ctx, "selected");
    if (sel.peek()) |d| sel.set(date_picker_w.clampDay(d));
    const today = date_picker_w.clampDay(date_picker_w.todayDay(dopts.today));
    const def_disp = date_picker_w.firstOfMonthOf(sel.peek() orelse today);
    const disp_val: i64 = if (opts.get("displayed")) |x| switch (x) {
        .int => |i| date_picker_w.firstOfMonthOf(date_picker_w.clampDay(i)),
        .float => |f| date_picker_w.firstOfMonthOf(date_picker_w.clampDay(floatToInt(i64, f) orelse return error.ValueOutOfRange)),
        else => def_disp,
    } else def_disp;
    const disp = try state.Signal(i64).init(allocator, disp_val);
    try ctx.track(disp, deinitI64Signal);
    const n = try date_picker_w.datePicker(allocator, sel, disp, null, null, dopts);
    return .{ .node = n, .live = .{ .signal = sel, .field = "selected", .read = readOptI64Signal }, .skip_children = true };
}

/// A nullable i64 signal builder (the date picker's "selected": null = no
/// selection, a number = a UTC epoch day).
fn buildOptI64Signal(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx, field: []const u8) anyerror!*state.Signal(?i64) {
    const v: ?i64 = if (opts.get(field)) |x| switch (x) {
        .null => null,
        .int => |i| i,
        .float => |f| floatToInt(i64, f) orelse return error.ValueOutOfRange,
        else => null,
    } else null;
    const sig = try state.Signal(?i64).init(allocator, v);
    try ctx.track(sig, deinitOptI64Signal);
    return sig;
}

fn readOptI64Signal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(?i64) = @ptrCast(@alignCast(p));
    const v = s.peek();
    return if (v) |d| .{ .int = d } else .null;
}

fn deinitOptI64Signal(p: *anyopaque) void {
    const s: *state.Signal(?i64) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

fn deinitI64Signal(p: *anyopaque) void {
    const s: *state.Signal(i64) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

/// M3E time picker (2d.4 PR #33): a LEAF panel (skip_children). "time" is
/// ALWAYS live (a Signal(i32) of minutes since midnight, clamped 0..1439 —
/// round-trips).
fn buildTimePicker(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const topts = try value_mod.optionsFromValue(time_picker_w.TimePickerOptions, opts, null, null);
    const raw: i32 = if (opts.get("time")) |x| switch (x) {
        .int => |i| std.math.cast(i32, i) orelse return error.ValueOutOfRange,
        .float => |f| floatToInt(i32, f) orelse return error.ValueOutOfRange,
        else => 630, // 10:30
    } else 630;
    const val = std.math.clamp(raw, 0, 1439); // the picker displays 0..1439
    const sig = try state.Signal(i32).init(allocator, val);
    try ctx.track(sig, deinitI32Signal);
    const n = try time_picker_w.timePicker(allocator, sig, null, null, topts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "time", .read = readI32Signal }, .skip_children = true };
}

fn readI32Signal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(i32) = @ptrCast(@alignCast(p));
    // Save what the picker displays: the time is clamped to 0..1439.
    return .{ .int = @as(i64, std.math.clamp(s.peek(), 0, 1439)) };
}

fn deinitI32Signal(p: *anyopaque) void {
    const s: *state.Signal(i32) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

/// M3E color picker (2d.4 PR #34): a LEAF panel (skip_children). "color" is
/// ALWAYS live (a Signal(Color) of 0xRRGGBBAA, alpha forced to 0xFF —
/// round-trips).
fn buildColorPicker(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const copts = try value_mod.optionsFromValue(color_picker_w.ColorPickerOptions, opts, null, null);
    const raw: u32 = if (opts.get("color")) |x| switch (x) {
        .int => |i| std.math.cast(u32, i) orelse return error.ValueOutOfRange,
        .float => |f| floatToInt(u32, f) orelse return error.ValueOutOfRange,
        else => 0xFF0000FF, // opaque red
    } else 0xFF0000FF;
    // Force alpha to 0xFF (v1: no alpha slider).
    const val = (raw & 0xFFFFFF00) | 0xFF;
    const sig = try state.Signal(u32).init(allocator, val);
    try ctx.track(sig, deinitColorSignal);
    const n = try color_picker_w.colorPicker(allocator, sig, null, copts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "color", .read = readColorSignal }, .skip_children = true };
}

fn readColorSignal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(u32) = @ptrCast(@alignCast(p));
    // Save what the picker displays: alpha forced to 0xFF.
    return .{ .int = @as(i64, (s.peek() & 0xFFFFFF00) | 0xFF) };
}

fn deinitColorSignal(p: *anyopaque) void {
    const s: *state.Signal(u32) = @ptrCast(@alignCast(p));
    s.deinit();
}

/// M3E avatar (4d P2): a circular display element (initials/icon/image).
fn buildAvatar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const aopts = try value_mod.optionsFromValue(avatar_w.AvatarOptions, opts, null, null);
    const n = try avatar_w.avatar(allocator, null, aopts);
    return .{ .node = n, .skip_children = true };
}

fn schemaAvatar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(avatar_w.AvatarOptions, allocator);
}

/// M3E expansion panel (4d P2): a collapsible panel with a tappable header.
/// "expanded" is a live Signal(bool). The child is the content (a document
/// child, visible when expanded).
fn buildExpansionPanel(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const eopts = try value_mod.optionsFromValue(expansion_panel_w.ExpansionPanelOptions, opts, null, null);
    const raw: bool = if (opts.get("expanded")) |x| switch (x) {
        .bool => |b| b,
        .int => |i| i != 0,
        else => false,
    } else false;
    const sig = try state.Signal(bool).init(allocator, raw);
    try ctx.track(sig, deinitBoolSignal);
    const n = try expansion_panel_w.expansionPanel(allocator, sig, null, eopts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "expanded", .read = readBoolSignal } };
}

fn schemaExpansionPanel(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(expansion_panel_w.ExpansionPanelOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "expanded", .toggle, &.{}, .{ .bool = false });
}

fn buildStepper(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const raw: usize = if (opts.get("current")) |x| switch (x) {
        .int => |i| if (i < 0) 0 else @as(usize, @intCast(i)),
        .float => |f| floatToInt(usize, f) orelse return error.ValueOutOfRange,
        else => 0,
    } else 0;
    const sig = try state.Signal(usize).init(allocator, raw);
    try ctx.track(sig, deinitUsizeSignal);
    var steps: std.array_list.Managed(stepper_w.StepperStep) = .init(allocator);
    defer steps.deinit();
    if (opts.get("steps")) |sv| switch (sv) {
        .array => |arr| for (arr) |iv| {
            if (iv.get("label")) |lv| switch (lv) {
                .string => |s| try steps.append(.{ .label = s }),
                else => {},
            } else try steps.append(.{ .label = "" });
        },
        else => {},
    };
    const n = try stepper_w.stepper(allocator, sig, steps.items, .{});
    return .{ .node = n, .live = .{ .signal = sig, .field = "current", .read = readUsizeSignal }, .skip_children = true };
}

fn schemaStepper(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(stepper_w.StepperOptions, allocator);
}

fn buildCalendar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const copts = try value_mod.optionsFromValue(calendar_w.CalendarOptions, opts, null, null);
    const sel = try buildOptI64Signal(allocator, opts, ctx, "selected");
    if (sel.peek()) |d| sel.set(date_picker_w.clampDay(d));
    const today = date_picker_w.clampDay(date_picker_w.todayDay(copts.today));
    const disp_val = sel.peek() orelse today;
    const disp = try state.Signal(i64).init(allocator, date_picker_w.firstOfMonthOf(disp_val));
    try ctx.track(disp, deinitI64Signal);
    const n = try calendar_w.calendar(allocator, sel, disp, copts);
    return .{ .node = n, .live = .{ .signal = sel, .field = "selected", .read = readOptI64Signal }, .skip_children = true };
}

fn schemaCalendar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(calendar_w.CalendarOptions, allocator);
}

fn buildTable(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const topts = try value_mod.optionsFromValue(table_w.TableOptions, opts, null, null);
    // Parse columns + rows arrays (borrowed from the snapshot).
    var cols: std.array_list.Managed([]const u8) = .init(allocator);
    defer cols.deinit();
    var rows: std.array_list.Managed([]const []const u8) = .init(allocator);
    defer rows.deinit();
    var row_cells: std.array_list.Managed([][]const u8) = .init(allocator);
    defer {
        for (row_cells.items) |cells| allocator.free(cells);
        row_cells.deinit();
    }
    if (opts.get("columns")) |cv| switch (cv) {
        .array => |arr| for (arr) |iv| switch (iv) {
            .string => |s| try cols.append(s),
            else => try cols.append(""),
        },
        else => {},
    };
    if (opts.get("rows")) |rv| switch (rv) {
        .array => |arr| for (arr) |row_v| switch (row_v) {
            .array => |cells_v| {
                const cells = try allocator.alloc([]const u8, cells_v.len);
                for (cells_v, 0..) |cv2, ci| switch (cv2) {
                    .string => |s| cells[ci] = s,
                    else => cells[ci] = "",
                };
                try row_cells.append(cells);
                try rows.append(cells);
            },
            else => {},
        },
        else => {},
    };
    const n = try table_w.table(allocator, cols.items, rows.items, null, topts);
    return .{ .node = n, .skip_children = true };
}

fn schemaTable(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(table_w.TableOptions, allocator);
}

/// Parse the "items" option: an array of {label, icon?, enabled?} objects.
/// The strings are BORROWED from the options snapshot (the rail factory
/// copies them).
fn parseNavRailItems(allocator: std.mem.Allocator, v: Value) ![]navigation_rail_w.NavRailItem {
    switch (v) {
        .null => return allocator.alloc(navigation_rail_w.NavRailItem, 0),
        .array => |arr| {
            const items = try allocator.alloc(navigation_rail_w.NavRailItem, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |iv, i| {
                if (iv != .object) return error.ExpectedObject;
                const label: []const u8 = if (iv.get("label")) |lv| switch (lv) {
                    .string => |s| s,
                    else => "",
                } else "";
                const icon: icon_w.IconName = if (iv.get("icon")) |lv| switch (lv) {
                    .string => |s| std.meta.stringToEnum(icon_w.IconName, s) orelse return error.UnknownIcon,
                    else => .home,
                } else .home;
                const enabled: bool = if (iv.get("enabled")) |ev| switch (ev) {
                    .bool => |b| b,
                    else => true,
                } else true;
                items[i] = .{ .label = label, .icon = icon, .enabled = enabled };
            }
            return items;
        },
        else => return error.ExpectedArray,
    }
}

fn deinitTextSignal(p: *anyopaque) void {
    const s: *state.Signal(text_field_w.TextBuf) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

// --- batch 2d.1 PR A: navigation chrome (M3E) ---

/// Slot builder for the registry builds: a slot Value is a subtree document
/// built through the same ctx (records + rollback apply to slot subtrees).
fn buildSlotNode(userdata: ?*anyopaque, v: Value) anyerror!*Node {
    const ctx: *BuildCtx = @ptrCast(@alignCast(userdata.?));
    return treeFromValueInner(ctx, v);
}

/// Free option slots built by optionsFromValue when the widget factory fails
/// (the slots are not attached to any node yet — the tree owns nothing).
fn deinitSlot2(a: ?*Node, b: ?*Node) void {
    if (a) |n| n.deinit();
    if (b) |n| n.deinit();
}

fn deinitSlot3(a: ?*Node, b: ?*Node, c: ?*Node) void {
    deinitSlot2(a, b);
    if (c) |n| n.deinit();
}

fn buildAppBar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const aopts = try value_mod.optionsFromValue(app_bar_w.AppBarOptions, opts, buildSlotNode, ctx);
    errdefer deinitSlot3(aopts.leading, aopts.title, aopts.actions);
    // the node's children are the slots (leading/title/actions) — content
    // passes through the option slots, preserved verbatim in the snapshot
    return .{ .node = try app_bar_w.appBar(allocator, aopts), .skip_children = true };
}

/// usize signal (nav_bar / tabs "selected"): initialized from the options,
/// exported as the CURRENT selection.
fn buildUsizeSignal(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*state.Signal(usize) {
    const sel: usize = if (opts.get("selected")) |x| switch (x) {
        .int => |i| std.math.cast(usize, i) orelse return error.ValueOutOfRange,
        .float => |f| blk: {
            if (!std.math.isFinite(f) or f < 0) return error.ValueOutOfRange;
            break :blk std.math.cast(usize, @as(i128, @intFromFloat(@trunc(f)))) orelse return error.ValueOutOfRange;
        },
        else => 0,
    } else 0;
    const sig = try state.Signal(usize).init(allocator, sel);
    try ctx.track(sig, deinitUsizeSignal);
    return sig;
}

fn readUsizeSignal(_: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(usize) = @ptrCast(@alignCast(p));
    return .{ .int = @intCast(s.peek()) };
}

fn deinitUsizeSignal(p: *anyopaque) void {
    const s: *state.Signal(usize) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

fn buildNavBar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const nopts = try value_mod.optionsFromValue(nav_bar_w.NavBarOptions, opts, null, null);
    const sig = try buildUsizeSignal(allocator, opts, ctx);
    const n = try nav_bar_w.navBar(allocator, sig, nopts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readUsizeSignal } };
}

fn buildTabs(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const topts = try value_mod.optionsFromValue(tabs_w.TabsOptions, opts, null, null);
    const sig = try buildUsizeSignal(allocator, opts, ctx);
    const n = try tabs_w.tabs(allocator, sig, topts);
    return .{ .node = n, .live = .{ .signal = sig, .field = "selected", .read = readUsizeSignal } };
}

fn buildDrawer(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const dopts = try value_mod.optionsFromValue(drawer_w.DrawerOptions, opts, buildSlotNode, ctx);
    errdefer deinitSlot2(dopts.content, dopts.body);
    const sig = try buildBoolSignal(allocator, opts, ctx, "open");
    const n = try drawer_w.drawer(allocator, sig, null, dopts);
    // the node's children (body slot + internal scrim/panel) are not document
    // children — content passes through the option slots
    return .{ .node = n, .live = .{ .signal = sig, .field = "open", .read = readBoolSignal }, .skip_children = true };
}

// --- batch 2d.1 PR B: feedback widgets (M3E) ---

/// bool signal (drawer/bottom_sheet/dialog "open", snackbar "visible"):
/// initialized from the options, exported as the CURRENT state.
fn buildBoolSignal(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx, field: []const u8) anyerror!*state.Signal(bool) {
    const initial: bool = if (opts.get(field)) |x| switch (x) {
        .bool => |b| b,
        else => false,
    } else false;
    const sig = try state.Signal(bool).init(allocator, initial);
    try ctx.track(sig, deinitBoolSignal);
    return sig;
}

fn deinitSlot4(a: ?*Node, b: ?*Node, c: ?*Node, d: ?*Node) void {
    deinitSlot3(a, b, c);
    if (d) |n| n.deinit();
}

fn buildBottomSheet(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(bottom_sheet_w.BottomSheetOptions, opts, buildSlotNode, ctx);
    errdefer deinitSlot2(sopts.content, sopts.body);
    const sig = try buildBoolSignal(allocator, opts, ctx, "open");
    const n = try bottom_sheet_w.bottomSheet(allocator, sig, null, sopts);
    // the node's children (body slot + internal scrim/panel) are not document
    // children — content passes through the option slots
    return .{ .node = n, .live = .{ .signal = sig, .field = "open", .read = readBoolSignal }, .skip_children = true };
}

fn buildDialog(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const dopts = try value_mod.optionsFromValue(dialog_w.DialogOptions, opts, buildSlotNode, ctx);
    errdefer deinitSlot4(dopts.icon, dopts.title, dopts.content, dopts.actions);
    const sig = try buildBoolSignal(allocator, opts, ctx, "open");
    const n = try dialog_w.dialog(allocator, sig, null, dopts);
    // the node's children (internal scrim/panel + the slot column) are not
    // document children — content passes through the option slots
    return .{ .node = n, .live = .{ .signal = sig, .field = "open", .read = readBoolSignal }, .skip_children = true };
}

fn buildProgress(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const popts = try value_mod.optionsFromValue(progress_w.ProgressOptions, opts, null, null);
    // a leaf: no children (document children are rejected — skip_children)
    return .{ .node = try progress_w.progressIndicator(allocator, popts), .skip_children = true };
}

fn buildBadge(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const bopts = try value_mod.optionsFromValue(badge_w.BadgeOptions, opts, null, null);
    // the node's child (the label text) is internal chrome
    return .{ .node = try badge_w.badge(allocator, bopts), .skip_children = true };
}

fn buildBadgedBox(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const xopts = try value_mod.optionsFromValue(badge_w.BadgedBoxOptions, opts, null, null);
    // content + badge are factory slots (built from the option values); the
    // anchor is required
    const content = buildSlotNode(ctx, opts.get("content") orelse return error.MissingSlot) catch |e| return e;
    var badge_node: ?*Node = null;
    if (opts.get("badge")) |bv| badge_node = buildSlotNode(ctx, bv) catch |e| {
        content.deinit();
        return e;
    };
    const node = badge_w.badgedBox(allocator, content, badge_node, xopts) catch |e| {
        content.deinit();
        if (badge_node) |b| b.deinit();
        return e;
    };
    return .{ .node = node, .skip_children = true };
}

fn buildTooltip(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    _ = ctx;
    const topts = try value_mod.optionsFromValue(tooltip_w.TooltipOptions, opts, null, null);
    // the anchor is a document child (added by treeFromValueInner); the bubble
    // is internal chrome (skipped by treeToValue via Node.internal)
    return .{ .node = try tooltip_w.tooltipShell(allocator, topts), .skip_children = false };
}

fn buildSnackBar(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const sopts = try value_mod.optionsFromValue(snackbar_w.SnackBarOptions, opts, null, null);
    const sig = try buildBoolSignal(allocator, opts, ctx, "visible");
    const n = try snackbar_w.snackBar(allocator, sig, null, null, sopts);
    // the node's children (internal bg + content) are not document children
    return .{ .node = n, .live = .{ .signal = sig, .field = "visible", .read = readBoolSignal }, .skip_children = true };
}

// --- per-widget inspector schemas (comptime-generated from options types) ---

fn schemaColumn(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(layout_w.FlexOptions, allocator);
}

fn schemaRow(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(layout_w.FlexOptions, allocator);
}

fn schemaPadding(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(ui.layout.EdgeInsets, allocator);
}

fn schemaCenter(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(NoOptions, allocator);
}

fn schemaConstrainedBox(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(layout_w.ConstrainedBoxOptions, allocator);
}

fn schemaDivider(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(divider_w.DividerOptions, allocator);
}

fn schemaText(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(text_w.TextOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "text", .text, &.{}, .{ .string = "" });
}

fn schemaIcon(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(icon_w.IconOptions, allocator);
    const ei = @typeInfo(icon_w.IconName).@"enum";
    var buf: [ei.field_names.len][]const u8 = undefined;
    inline for (ei.field_names, 0..) |fname, i| buf[i] = fname;
    return value_mod.appendSchemaProp(base, allocator, "icon", .select, &buf, .{ .string = "star" });
}

fn schemaButton(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // variant/size/shape (select), enabled (toggle), label (text),
    // icon (select) — all automatic from the options type; theme is
    // unsupported (global token set)
    return value_mod.schemaOf(button_w.ButtonOptions, allocator);
}

fn schemaIconButton(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // variant/size/width/shape (select), enabled (toggle), a11y_label (text),
    // icon (select) — automatic; "selected" makes the registry build a toggle
    const base = try value_mod.schemaOf(icon_button_w.IconButtonOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "selected", .toggle, &.{}, .{ .bool = false });
}

fn schemaSwitch(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // enabled (toggle), a11y_label (text) — automatic; "checked" is live
    const base = try value_mod.schemaOf(switch_w.SwitchOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "checked", .toggle, &.{}, .{ .bool = false });
}

fn schemaCheckbox(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // enabled/error (toggle), a11y_label (text) — automatic; "checked" is live
    const base = try value_mod.schemaOf(checkbox_w.CheckboxOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "checked", .toggle, &.{}, .{ .bool = false });
}

fn schemaRadio(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // enabled (toggle), a11y_label (text) — automatic; "selected" is live
    var base = try value_mod.schemaOf(radio_w.RadioOptions, allocator);
    base = try value_mod.appendSchemaProp(base, allocator, "selected", .number, &.{}, .{ .int = 0 });
    base = try value_mod.appendSchemaProp(base, allocator, "index", .number, &.{}, .{ .int = 0 });
    return value_mod.appendSchemaProp(base, allocator, "group", .text, &.{}, .{ .string = "default" });
}

fn schemaSlider(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // enabled (toggle), default_width (number), a11y_label (text) — automatic
    const base = try value_mod.schemaOf(slider_w.SliderOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "value", .number, &.{}, .{ .float = 0.5 });
}

fn schemaChip(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // variant (select), enabled/selected (toggle), label (text),
    // leading_icon/trailing_icon (select, nullable) — all automatic from
    // the options type; theme is unsupported (global token set)
    return value_mod.schemaOf(chip_w.ChipOptions, allocator);
}

fn schemaTextField(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // variant (select), enabled/error (toggle), label/placeholder/initial/
    // supporting (text), leading_icon/trailing_icon (select) — automatic;
    // "value" is the live text
    const base = try value_mod.schemaOf(text_field_w.TextFieldOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "value", .text, &.{}, .{ .string = "" });
}

fn schemaCard(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // variant (select), enabled (toggle), padding (insets), gap (number) —
    // all automatic from the options type; theme is unsupported (global)
    return value_mod.schemaOf(card_w.CardOptions, allocator);
}

fn schemaListItem(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // lines (select), enabled (toggle), headline/supporting/overline/
    // trailing_text (text), leading_icon/trailing_icon (select) — automatic;
    // "selected" is live
    const base = try value_mod.schemaOf(list_item_w.ListItemOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "selected", .toggle, &.{}, .{ .bool = false });
}

fn schemaMenu(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // the anchor is a factory slot; "items" is a structured array the
    // inspector cannot edit generically yet (unsupported); "open" is live
    var base = try value_mod.schemaOf(menu_w.MenuOptions, allocator);
    base = try value_mod.appendSchemaProp(base, allocator, "anchor", .slot, &.{}, .null);
    base = try value_mod.appendSchemaProp(base, allocator, "items", .unsupported, &.{}, .null);
    return value_mod.appendSchemaProp(base, allocator, "open", .toggle, &.{}, .{ .bool = false });
}

fn schemaSegmentedButton(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // "items" is a structured array the inspector cannot edit generically
    // yet (unsupported); "selected" (usize) is automatic (a number) and live
    const base = try value_mod.schemaOf(segmented_button_w.SegmentedButtonOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "items", .unsupported, &.{}, .null);
}

fn schemaSplitButton(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // size (select), enabled (toggle), label (text), leading_icon/
    // trailing_icon (select) — all automatic from the options type; theme is
    // unsupported (global token set)
    return value_mod.schemaOf(split_button_w.SplitButtonOptions, allocator);
}

fn schemaSearchBar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // enabled (toggle), placeholder/initial (text) — automatic;
    // "value" is the live text
    const base = try value_mod.schemaOf(search_bar_w.SearchBarOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "value", .text, &.{}, .{ .string = "" });
}

fn schemaNavigationRail(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // expanded (toggle), selected (number) — automatic; "items" is a
    // structured array the inspector cannot edit generically yet
    // (unsupported); theme is unsupported (global token set)
    const base = try value_mod.schemaOf(navigation_rail_w.NavigationRailOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "items", .unsupported, &.{}, .null);
}

fn schemaSideSheet(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // body/content (slot), side (select), modal (toggle), width (number),
    // label (text) — automatic; "open" is live
    const base = try value_mod.schemaOf(side_sheet_w.SideSheetOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "open", .toggle, &.{}, .{ .bool = false });
}

fn schemaPullToRefresh(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // label (text) — automatic; "refreshing" is live; theme is unsupported
    const base = try value_mod.schemaOf(pull_to_refresh_w.PullToRefreshOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "refreshing", .toggle, &.{}, .{ .bool = false });
}

fn schemaLoadingIndicator(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // contained (toggle) — automatic; "progress" is live when present; theme
    // is unsupported (global token set)
    const base = try value_mod.schemaOf(loading_indicator_w.LoadingIndicatorOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "progress", .number, &.{}, .{ .float = 0.5 });
}

fn schemaDatePicker(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // title (text), width (number), today (number) — automatic; "selected"
    // is live (null = no selection); "displayed" is the initial month (not
    // live); theme is unsupported (global token set)
    const base = try value_mod.schemaOf(date_picker_w.DatePickerOptions, allocator);
    const with_sel = try value_mod.appendSchemaProp(base, allocator, "selected", .number, &.{}, .null);
    return value_mod.appendSchemaProp(with_sel, allocator, "displayed", .number, &.{}, .{ .int = 0 });
}

fn schemaTimePicker(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // is_24h (toggle), width (number) — automatic; "time" is live; theme is
    // unsupported (global token set)
    const base = try value_mod.schemaOf(time_picker_w.TimePickerOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "time", .number, &.{}, .{ .int = 630 });
}

fn schemaColorPicker(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // width (number) — automatic; "color" is live; theme is unsupported
    const base = try value_mod.schemaOf(color_picker_w.ColorPickerOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "color", .number, &.{}, .{ .int = 0xFF0000FF });
}

// --- batch 2d.1 PR A schemas ---

fn schemaAppBar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // leading/title/actions are slots; theme is unsupported (global token set)
    return value_mod.schemaOf(app_bar_w.AppBarOptions, allocator);
}

fn schemaNavBar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(nav_bar_w.NavBarOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "selected", .number, &.{}, .{ .int = 0 });
}

fn schemaTabs(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(tabs_w.TabsOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "selected", .number, &.{}, .{ .int = 0 });
}

fn schemaDrawer(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(drawer_w.DrawerOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "open", .toggle, &.{}, .{ .bool = false });
}

// --- batch 2d.1 PR B schemas ---

fn schemaBottomSheet(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(bottom_sheet_w.BottomSheetOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "open", .toggle, &.{}, .{ .bool = false });
}

fn schemaDialog(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(dialog_w.DialogOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "open", .toggle, &.{}, .{ .bool = false });
}

fn schemaProgress(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // kind (select: linear/circular), progress (number, nullable =
    // indeterminate), wavy (toggle) — all automatic from the options type
    return value_mod.schemaOf(progress_w.ProgressOptions, allocator);
}

fn schemaBadge(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(badge_w.BadgeOptions, allocator); // label (text, nullable = dot)
}

fn schemaBadgedBox(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    // content + badge are factory slots, not option fields — appended manually
    var base = try value_mod.schemaOf(badge_w.BadgedBoxOptions, allocator);
    base = try value_mod.appendSchemaProp(base, allocator, "content", .slot, &.{}, .null);
    return value_mod.appendSchemaProp(base, allocator, "badge", .slot, &.{}, .null);
}

fn schemaTooltip(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    return value_mod.schemaOf(tooltip_w.TooltipOptions, allocator); // text
}

fn schemaSnackBar(allocator: std.mem.Allocator) anyerror![]value_mod.PropSchema {
    const base = try value_mod.schemaOf(snackbar_w.SnackBarOptions, allocator);
    return value_mod.appendSchemaProp(base, allocator, "visible", .toggle, &.{}, .{ .bool = false });
}

// --- tests ---

fn slotBuilder(userdata: ?*anyopaque, v: Value) anyerror!*Node {
    _ = userdata;
    _ = v;
    return golden.solidBox(std.testing.allocator, 8, 8, 0xFF0000FF);
}

test "registry: byName finds entries, rejects unknown" {
    try std.testing.expect(byName("column") != null);
    try std.testing.expect(byName("slider") != null);
    try std.testing.expect(byName("snackbar") != null);
    try std.testing.expect(byName("nope") == null);
    try std.testing.expectEqual(@as(usize, 45), widgets.len);
}

test "registry: builds a node with defaults from a minimal value" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\"}");
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 0), node.children.items.len);
}

test "registry: tree round-trip preserves the document" {
    // the M3E button's label/icon are options data (internal chrome), not children
    const doc = "{\"name\":\"column\",\"options\":{\"gap\":8,\"main_align\":\"center\"},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"Hello\",\"size\":20,\"color\":16777215}},{\"name\":\"button\",\"options\":{\"label\":\"OK\",\"variant\":\"outlined\"}}]}";
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 2), node.children.items.len);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: treeFromJson / treeToJson wrappers" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"row\",\"options\":{\"gap\":4}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: signal widgets build with a ctx-owned signal (no leak)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":[{\"name\":\"switch\"},{\"name\":\"checkbox\"},{\"name\":\"slider\"}]}");
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 3), node.children.items.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.tracked.items.len);
}

test "registry: reset frees records and signals between builds" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    {
        const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"switch\"}");
        node.deinit();
    }
    ctx.reset();
    try std.testing.expectEqual(@as(usize, 0), ctx.tracked.items.len);
    {
        const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"checkbox\"}");
        node.deinit();
    }
    ctx.reset();
}

test "registry: errors — unknown widget, missing name, type mismatch, unregistered node" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    try std.testing.expectError(error.UnknownWidget, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"nope\"}"));
    try std.testing.expectError(error.MissingName, treeFromJson(&ctx, std.testing.allocator, "{\"options\":{}}"));
    try std.testing.expectError(error.TypeMismatch, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"text\",\"options\":{\"size\":\"big\"}}"));
    try std.testing.expectError(error.ValueOutOfRange, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"divider\",\"options\":{\"color\":-1}}"));
    try std.testing.expectError(error.ExpectedArray, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":{}}"));
    const alien = try golden.solidBox(std.testing.allocator, 4, 4, 0xFF);
    defer alien.deinit();
    try std.testing.expectError(error.UnregisteredNode, treeToValue(&ctx, alien, std.testing.allocator));
}

test "registry: a failed build leaves no stale records or signals" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // column[ text, unknown ] — fails on the second child
    try std.testing.expectError(error.UnknownWidget, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"ok\"}},{\"name\":\"nope\"}]}"));
    try std.testing.expectEqual(@as(usize, 0), ctx.records.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.tracked.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.journal.items.len);
    // column[ toggle, unknown ] — fails after a signal was created
    try std.testing.expectError(error.UnknownWidget, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":[{\"name\":\"switch\"},{\"name\":\"nope\"}]}"));
    try std.testing.expectEqual(@as(usize, 0), ctx.records.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.tracked.items.len);
    // the ctx is still usable afterwards
    const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"row\"}");
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"name\":\"row\"}", out);
}

test "registry: signal widgets round-trip their live value" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"column\",\"children\":[{\"name\":\"switch\",\"options\":{\"checked\":true}},{\"name\":\"slider\",\"options\":{\"value\":0.25}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: nav_bar round-trips with its selection and item children" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"nav_bar\",\"options\":{\"selected\":1},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"One\"}},{\"name\":\"text\",\"options\":{\"text\":\"Two\"}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 2), node.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.tracked.items.len); // the selection signal
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: tabs round-trips with its selection" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"tabs\",\"options\":{\"selected\":0},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"One\"}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: drawer round-trips with its open state and slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"drawer\",\"options\":{\"open\":true,\"width\":280,\"body\":{\"name\":\"text\",\"options\":{\"text\":\"Body\"}},\"content\":{\"name\":\"text\",\"options\":{\"text\":\"Panel\"}}}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: app_bar round-trips with its slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"app_bar\",\"options\":{\"title\":{\"name\":\"text\",\"options\":{\"text\":\"Hello\"}},\"leading\":{\"name\":\"icon\",\"options\":{\"icon\":\"menu\"}}}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 2), node.children.items.len); // leading + title
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: slot widgets reject document children (they would never serialize)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // app_bar's children are its internal slots; a document child would build
    // but be dropped by treeToValue — rejected at load instead.
    const doc = "{\"name\":\"app_bar\",\"options\":{},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, doc));
    // same for the drawer
    const doc2 = "{\"name\":\"drawer\",\"options\":{},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, doc2));
    // and for a leaf widget (progress)
    const doc3 = "{\"name\":\"progress\",\"options\":{},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, doc3));
}

test "registry: bottom_sheet round-trips with its open state and slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"bottom_sheet\",\"options\":{\"open\":false,\"drag_handle\":true,\"body\":{\"name\":\"text\",\"options\":{\"text\":\"Body\"}},\"content\":{\"name\":\"text\",\"options\":{\"text\":\"Sheet\"}}}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: dialog round-trips with its open state and slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"dialog\",\"options\":{\"open\":true,\"title\":{\"name\":\"text\",\"options\":{\"text\":\"Delete?\"}},\"content\":{\"name\":\"text\",\"options\":{\"text\":\"This cannot be undone.\"}}}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: progress round-trips (kind, determinate value, wavy)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"progress\",\"options\":{\"kind\":\"circular\",\"progress\":0.5,\"wavy\":false}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: badge + badged_box round-trip with their slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"badge\",\"options\":{\"label\":\"3\"}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    const doc2 = "{\"name\":\"badged_box\",\"options\":{\"content\":{\"name\":\"icon\",\"options\":{\"icon\":\"star\"}},\"badge\":{\"name\":\"badge\",\"options\":{\"label\":\"9\"}}}}";
    const node2 = try treeFromJson(&ctx, std.testing.allocator, doc2);
    defer node2.deinit();
    try std.testing.expectEqual(@as(usize, 2), node2.children.items.len); // content + badge
    const out2 = try treeToJson(&ctx, node2, std.testing.allocator);
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings(doc2, out2);
}

test "registry: tooltip round-trips with the anchor child (bubble is internal)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"tooltip\",\"options\":{\"text\":\"Save\"},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"Hi\"}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    // the internal bubble (child 0, from the shell) + the anchor (child 1,
    // added by treeFromValueInner): serialization keeps only the anchor
    try std.testing.expectEqual(@as(usize, 2), node.children.items.len);
    try std.testing.expect(node.children.items[0].internal);
    try std.testing.expect(!node.children.items[1].internal);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: snackbar round-trips with its visible state" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"snackbar\",\"options\":{\"visible\":true,\"text\":\"Saved\",\"action_label\":\"Undo\",\"timeout_ms\":4000}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}

test "registry: icon_button round-trips (toggle with its selected state, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // toggle: the "selected" option drives a live bool signal
    const doc = "{\"name\":\"icon_button\",\"options\":{\"variant\":\"filled\",\"a11y_label\":\"Favorite\",\"icon\":\"heart\",\"selected\":true}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "selected" option -> no signal, no live binding
    const plain_doc = "{\"name\":\"icon_button\",\"options\":{\"variant\":\"outlined\",\"a11y_label\":\"Search\",\"icon\":\"search\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
}

test "registry: chip (M3E) round-trips (toggle with its selected state, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // toggle: the "selected" option drives a live bool signal
    const doc = "{\"name\":\"chip\",\"options\":{\"variant\":\"filter\",\"label\":\"News\",\"selected\":true}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.toggle, node.semantics.?.role);
    try std.testing.expectEqual(true, node.semantics.?.checked.?); // the signal
    // plain: no "selected" option -> no signal, no live binding
    const plain_doc = "{\"name\":\"chip\",\"options\":{\"variant\":\"suggestion\",\"label\":\"Nearby\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    try std.testing.expectEqual(ui.semantics.Role.button, plain.semantics.?.role);
    try std.testing.expect(plain.semantics.?.checked == null);
    // null = the field default: no signal (an action chip), and the null
    // round-trips verbatim
    const null_doc = "{\"name\":\"chip\",\"options\":{\"label\":\"Add\",\"selected\":null}}";
    const nullnode = try treeFromJson(&ctx, std.testing.allocator, null_doc);
    defer nullnode.deinit();
    const null_out = try treeToJson(&ctx, nullnode, std.testing.allocator);
    defer std.testing.allocator.free(null_out);
    try std.testing.expectEqualStrings(null_doc, null_out);
    try std.testing.expectEqual(ui.semantics.Role.button, nullnode.semantics.?.role);
    try std.testing.expect(nullnode.semantics.?.checked == null);
}

test "registry: chip (M3E) schema exposes the right editor kinds" {
    const chip_schema = try byName("chip").?.schema(std.testing.allocator);
    defer {
        for (chip_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(chip_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(chip_schema, "variant").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(chip_schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(chip_schema, "label").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(chip_schema, "selected").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(chip_schema, "leading_icon").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(chip_schema, "trailing_icon").?);
    try std.testing.expect(findProp(chip_schema, "theme") == null); // global token set
}

test "registry: text_field (M3E) round-trips (live value, and plain initial)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // live: the "value" option drives a text signal; the current text round-trips
    const doc = "{\"name\":\"text_field\",\"options\":{\"variant\":\"outlined\",\"label\":\"Email\",\"value\":\"a@b.c\"}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.text_field, node.semantics.?.role);
    try std.testing.expectEqualStrings("a@b.c", node.semantics.?.value);
    // the live value follows edits (type → the serialized value changes)
    var router = ui.input.InputRouter{};
    ui.input.setCurrent(&router);
    defer ui.input.setCurrent(null);
    router.focus(node);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const out2 = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"value\":\"a@b.c!\"") != null);
    // plain: "initial" is the live field — it round-trips AND edits are saved
    const plain_doc = "{\"name\":\"text_field\",\"options\":{\"variant\":\"filled\",\"initial\":\"Hi\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    try std.testing.expectEqualStrings("Hi", plain.semantics.?.value);
    router.focus(plain);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const plain_out2 = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out2);
    try std.testing.expect(std.mem.indexOf(u8, plain_out2, "\"initial\":\"Hi!\"") != null);
    // no value/initial: the live "value" materializes on save (the checkbox
    // convention: state fields appear once the tree is serialized)
    const bare_doc = "{\"name\":\"text_field\",\"options\":{\"label\":\"Email\"}}";
    const bare = try treeFromJson(&ctx, std.testing.allocator, bare_doc);
    defer bare.deinit();
    const bare_out = try treeToJson(&ctx, bare, std.testing.allocator);
    defer std.testing.allocator.free(bare_out);
    try std.testing.expectEqualStrings("{\"name\":\"text_field\",\"options\":{\"label\":\"Email\",\"value\":\"\"}}", bare_out);
    // long text round-trips losslessly (the live value reads the widget's
    // buffer, not the fixed-size signal mirror)
    const long_text = blk: {
        var t: [300]u8 = undefined;
        @memset(&t, 'a');
        break :blk &t;
    };
    const long_doc = try std.fmt.allocPrint(std.testing.allocator, "{{\"name\":\"text_field\",\"options\":{{\"value\":\"{s}\"}}}}", .{long_text});
    defer std.testing.allocator.free(long_doc);
    const long_node = try treeFromJson(&ctx, std.testing.allocator, long_doc);
    defer long_node.deinit();
    const long_out = try treeToJson(&ctx, long_node, std.testing.allocator);
    defer std.testing.allocator.free(long_out);
    try std.testing.expectEqualStrings(long_doc, long_out);
}

test "registry: search_bar (M3E) round-trips (live value, and plain initial)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // live: the "value" option drives a text signal; the current text round-trips
    const doc = "{\"name\":\"search_bar\",\"options\":{\"placeholder\":\"Search\",\"value\":\"query\"}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.text_field, node.semantics.?.role);
    try std.testing.expectEqualStrings("query", node.semantics.?.value);
    try std.testing.expectEqualStrings("query", search_bar_w.text(node));
    // the live value follows edits (type → the serialized value changes)
    var router = ui.input.InputRouter{};
    ui.input.setCurrent(&router);
    defer ui.input.setCurrent(null);
    router.focus(node);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const out2 = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"value\":\"query!\"") != null);
    // plain: "initial" is the live field — it round-trips AND edits are saved
    const plain_doc = "{\"name\":\"search_bar\",\"options\":{\"initial\":\"Hi\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    try std.testing.expectEqualStrings("Hi", plain.semantics.?.value);
    router.focus(plain);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "!" });
    const plain_out2 = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out2);
    try std.testing.expect(std.mem.indexOf(u8, plain_out2, "\"initial\":\"Hi!\"") != null);
    // no value/initial: the live "value" materializes on save (the text
    // field convention: state fields appear once the tree is serialized)
    const bare_doc = "{\"name\":\"search_bar\",\"options\":{\"placeholder\":\"Search\"}}";
    const bare = try treeFromJson(&ctx, std.testing.allocator, bare_doc);
    defer bare.deinit();
    const bare_out = try treeToJson(&ctx, bare, std.testing.allocator);
    defer std.testing.allocator.free(bare_out);
    try std.testing.expectEqualStrings("{\"name\":\"search_bar\",\"options\":{\"placeholder\":\"Search\",\"value\":\"\"}}", bare_out);
}

test "registry: text_field (M3E) schema exposes the right editor kinds" {
    const schema = try byName("text_field").?.schema(std.testing.allocator);
    defer {
        for (schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(schema, "variant").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(schema, "error").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(schema, "label").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(schema, "placeholder").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(schema, "value").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(schema, "leading_icon").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(schema, "trailing_icon").?);
    try std.testing.expect(findProp(schema, "theme") == null); // global token set
}

test "registry: card (M3E) round-trips with its document children" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // a card is a container: the children are document data
    const doc = "{\"name\":\"card\",\"options\":{\"variant\":\"elevated\"},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"Hi\",\"size\":16,\"color\":16777215}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 1), node.children.items.len);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
}

test "registry: list_item (M3E) round-trips (selected with its live state, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // selected: the option drives a live bool signal
    const doc = "{\"name\":\"list_item\",\"options\":{\"headline\":\"Row\",\"selected\":true}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.list_item, node.semantics.?.role);
    try std.testing.expectEqual(true, node.semantics.?.checked.?);
    // plain: no "selected" option -> fixed state, no live binding
    const plain_doc = "{\"name\":\"list_item\",\"options\":{\"headline\":\"Row\",\"supporting\":\"Sub\",\"lines\":\"two\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    try std.testing.expect(plain.semantics.?.checked == null or !plain.semantics.?.checked.?);
}

test "registry: menu (M3E) round-trips (anchor slot + items, live open state, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // live: the "open" option drives a bool signal; the current state
    // round-trips; the anchor + items are option slots preserved verbatim
    const doc = "{\"name\":\"menu\",\"options\":{\"anchor\":{\"name\":\"button\",\"options\":{\"label\":\"Actions\"}},\"items\":[{\"label\":\"Copy\"},{\"label\":\"Paste\",\"leading_icon\":\"star\",\"trailing_text\":\"Ctrl+V\",\"enabled\":false}],\"open\":true}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expect(menu_w.isOpen(node)); // applied at build
    try std.testing.expectEqual(@as(usize, 3), node.children.items.len); // anchor + 2 item rows (internal)
    try std.testing.expectEqual(ui.semantics.Role.menu, node.semantics.?.role);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "open" option -> closed, nothing live to serialize
    const plain_doc = "{\"name\":\"menu\",\"options\":{\"anchor\":{\"name\":\"button\",\"options\":{\"label\":\"Actions\"}},\"items\":[{\"label\":\"Copy\"}]}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    try std.testing.expect(!menu_w.isOpen(plain));
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
}

test "registry: segmented_button + split_button (M3E) round-trip (items + live selection, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // segmented_button: the "selected" option drives a live usize signal;
    // the current selection round-trips; the items are preserved verbatim
    const doc = "{\"name\":\"segmented_button\",\"options\":{\"items\":[{\"label\":\"Day\"},{\"label\":\"Week\",\"icon\":\"star\",\"enabled\":false}],\"selected\":1}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 1), segmented_button_w.selectedIndex(node));
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
    try std.testing.expectEqualStrings("Week", node.semantics.?.value);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "selected" option -> the default 0 is live and round-trips
    // (the export carries the current selection, like the text field)
    const plain_doc = "{\"name\":\"segmented_button\",\"options\":{\"items\":[{\"label\":\"Day\"}]}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 0), segmented_button_w.selectedIndex(plain));
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings("{\"name\":\"segmented_button\",\"options\":{\"items\":[{\"label\":\"Day\"}],\"selected\":0}}", plain_out);
    // split_button: every field is options data (no live state)
    const sdoc = "{\"name\":\"split_button\",\"options\":{\"size\":\"medium\",\"enabled\":false,\"label\":\"Save\",\"leading_icon\":\"star\",\"trailing_icon\":\"arrow_down\"}}";
    const snode = try treeFromJson(&ctx, std.testing.allocator, sdoc);
    defer snode.deinit();
    try std.testing.expectEqual(ui.semantics.Role.button, snode.semantics.?.role);
    try std.testing.expect(snode.semantics.?.disabled);
    const sout = try treeToJson(&ctx, snode, std.testing.allocator);
    defer std.testing.allocator.free(sout);
    try std.testing.expectEqualStrings(sdoc, sout);
}

test "registry: navigation_rail (M3E) round-trips (items + live selection, and plain)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // the "selected" option drives a live usize signal; the current
    // selection round-trips; the items are preserved verbatim
    const doc = "{\"name\":\"navigation_rail\",\"options\":{\"expanded\":true,\"items\":[{\"label\":\"Home\",\"icon\":\"home\"},{\"label\":\"Music\",\"icon\":\"play\",\"enabled\":false}],\"selected\":1}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 1), navigation_rail_w.selectedIndex(node));
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
    try std.testing.expectEqualStrings("Music", node.semantics.?.value);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "selected" option -> the default 0 is live and round-trips
    const plain_doc = "{\"name\":\"navigation_rail\",\"options\":{\"items\":[{\"label\":\"Home\",\"icon\":\"home\"}]}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 0), navigation_rail_w.selectedIndex(plain));
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings("{\"name\":\"navigation_rail\",\"options\":{\"items\":[{\"label\":\"Home\",\"icon\":\"home\"}],\"selected\":0}}", plain_out);
}

test "registry: side_sheet (M3E) round-trips with its open state and slots" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"side_sheet\",\"options\":{\"side\":\"start\",\"modal\":true,\"width\":320,\"open\":true,\"body\":{\"name\":\"text\",\"options\":{\"text\":\"Body\"}},\"content\":{\"name\":\"text\",\"options\":{\"text\":\"Filters\"}}}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    try std.testing.expectEqual(ui.semantics.Role.group, node.children.items[2].semantics.?.role); // the panel
}

test "registry: pull_to_refresh (M3E) round-trips (live refreshing + the content child)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // the content is a document child (not a slot): it serializes as a child
    const doc = "{\"name\":\"pull_to_refresh\",\"options\":{\"refreshing\":true},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"List\"}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 1), node.children.items.len); // the content child
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "refreshing" option -> the default false is live and round-trips
    const plain_doc = "{\"name\":\"pull_to_refresh\",\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"List\"}}]}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings("{\"name\":\"pull_to_refresh\",\"options\":{\"refreshing\":false},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"List\"}}]}", plain_out);
}

test "registry: side_sheet + pull_to_refresh (M3E) schemas expose the right editor kinds" {
    const ss_schema = try byName("side_sheet").?.schema(std.testing.allocator);
    defer {
        for (ss_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(ss_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(ss_schema, "body").?);
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(ss_schema, "content").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(ss_schema, "side").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(ss_schema, "modal").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(ss_schema, "width").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(ss_schema, "open").?);
    try std.testing.expect(findProp(ss_schema, "theme") == null); // global token set
    const ptr_schema = try byName("pull_to_refresh").?.schema(std.testing.allocator);
    defer {
        for (ptr_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(ptr_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(ptr_schema, "refreshing").?);
    try std.testing.expect(findProp(ptr_schema, "theme") == null); // global token set
}

test "registry: loading_indicator (M3E) round-trips (determinate progress + plain indeterminate)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // determinate: the progress signal is ALWAYS live and round-trips
    const doc = "{\"name\":\"loading_indicator\",\"options\":{\"contained\":true,\"progress\":0.75}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(ui.semantics.Role.progress, node.semantics.?.role);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: no "progress" option → the indeterminate loop, no live field
    const plain_doc = "{\"name\":\"loading_indicator\"}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    // an EXPLICIT null progress stays indeterminate and round-trips unchanged
    const null_doc = "{\"name\":\"loading_indicator\",\"options\":{\"progress\":null}}";
    const nullnode = try treeFromJson(&ctx, std.testing.allocator, null_doc);
    defer nullnode.deinit();
    const null_out = try treeToJson(&ctx, nullnode, std.testing.allocator);
    defer std.testing.allocator.free(null_out);
    try std.testing.expectEqualStrings(null_doc, null_out);
}

test "registry: loading_indicator (a leaf) rejects document children in both modes" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"loading_indicator\",\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, doc));
    const det_doc = "{\"name\":\"loading_indicator\",\"options\":{\"progress\":0.5},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, det_doc));
}

test "registry: loading_indicator (M3E) schema exposes the right editor kinds" {
    const li_schema = try byName("loading_indicator").?.schema(std.testing.allocator);
    defer {
        for (li_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(li_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(li_schema, "contained").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(li_schema, "progress").?);
    try std.testing.expect(findProp(li_schema, "theme") == null); // global token set
}

test "registry: date_picker (M3E) round-trips (live selected; displayed is the initial month)" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // the selected day is ALWAYS live and round-trips (20735 = 2026-10-09;
    // today = 20734 = 2026-10-08, injected for determinism)
    const doc = "{\"name\":\"date_picker\",\"options\":{\"today\":20734,\"selected\":20735}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // no selection: selected = null round-trips; displayed defaults to the
    // month of today (20734 = 2026-10-08 → October 2026) but is not live
    const plain_doc = "{\"name\":\"date_picker\",\"options\":{\"today\":20734}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings("{\"name\":\"date_picker\",\"options\":{\"today\":20734,\"selected\":null}}", plain_out);
    // an explicit displayed month is kept in the snapshot
    const disp_doc = "{\"name\":\"date_picker\",\"options\":{\"today\":20734,\"selected\":20735,\"displayed\":19510}}";
    const disp = try treeFromJson(&ctx, std.testing.allocator, disp_doc);
    defer disp.deinit();
    const disp_out = try treeToJson(&ctx, disp, std.testing.allocator);
    defer std.testing.allocator.free(disp_out);
    try std.testing.expectEqualStrings(disp_doc, disp_out); // 19510 = 2023-06-02
    // a mid-month displayed value is normalized to the month's 1st (the grid's
    // weekday column comes from the month's 1st); the snapshot echoes the input
    const mid_doc = "{\"name\":\"date_picker\",\"options\":{\"today\":20734,\"selected\":20735,\"displayed\":19523}}"; // 19523 = 2023-06-15
    const mid = try treeFromJson(&ctx, std.testing.allocator, mid_doc);
    defer mid.deinit();
    try std.testing.expectEqual(@as(i64, 19509), date_picker_w.displayedMonth(mid)); // 2023-06-01
    const mid_out = try treeToJson(&ctx, mid, std.testing.allocator);
    defer std.testing.allocator.free(mid_out);
    try std.testing.expectEqualStrings(mid_doc, mid_out);
    // an extreme selected day is clamped to the supported range (no overflow):
    // 2100-12-31 = 47846
    const extreme_doc = "{\"name\":\"date_picker\",\"options\":{\"selected\":9223372036854775807}}";
    const extreme = try treeFromJson(&ctx, std.testing.allocator, extreme_doc);
    defer extreme.deinit();
    const extreme_out = try treeToJson(&ctx, extreme, std.testing.allocator);
    defer std.testing.allocator.free(extreme_out);
    try std.testing.expectEqualStrings("{\"name\":\"date_picker\",\"options\":{\"selected\":47846}}", extreme_out);
    // a finite float beyond i128 is rejected, not a trap
    const huge_doc = "{\"name\":\"date_picker\",\"options\":{\"selected\":1e100}}";
    try std.testing.expectError(error.ValueOutOfRange, treeFromJson(&ctx, std.testing.allocator, huge_doc));
}

test "registry: date_picker (M3E) schema exposes the right editor kinds + rejects children" {
    const dp_schema = try byName("date_picker").?.schema(std.testing.allocator);
    defer {
        for (dp_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(dp_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(dp_schema, "title").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(dp_schema, "width").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(dp_schema, "today").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(dp_schema, "selected").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(dp_schema, "displayed").?);
    try std.testing.expect(findProp(dp_schema, "theme") == null); // global token set
    // a leaf panel: a document child is rejected
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"date_picker\",\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, doc));
}

test "registry: time_picker (M3E) round-trips (live time) + schema + rejects children" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // the time is ALWAYS live and round-trips (630 = 10:30)
    const doc = "{\"name\":\"time_picker\",\"options\":{\"is_24h\":true,\"time\":1325}}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    defer node.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, node.semantics.?.role);
    const out = try treeToJson(&ctx, node, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
    // plain: the default 10:30 is live and round-trips
    const plain_doc = "{\"name\":\"time_picker\"}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings("{\"name\":\"time_picker\",\"options\":{\"time\":630}}", plain_out);
    // an out-of-range time is clamped to what the picker displays (0..1439)
    const clamped_doc = "{\"name\":\"time_picker\",\"options\":{\"time\":2000}}";
    const clamped = try treeFromJson(&ctx, std.testing.allocator, clamped_doc);
    defer clamped.deinit();
    const clamped_out = try treeToJson(&ctx, clamped, std.testing.allocator);
    defer std.testing.allocator.free(clamped_out);
    try std.testing.expectEqualStrings("{\"name\":\"time_picker\",\"options\":{\"time\":1439}}", clamped_out);
    // a finite float beyond i128 is rejected, not a trap
    const huge_doc = "{\"name\":\"time_picker\",\"options\":{\"time\":1e100}}";
    try std.testing.expectError(error.ValueOutOfRange, treeFromJson(&ctx, std.testing.allocator, huge_doc));
    // the schema
    const tp_schema = try byName("time_picker").?.schema(std.testing.allocator);
    defer {
        for (tp_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(tp_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(tp_schema, "is_24h").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(tp_schema, "width").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(tp_schema, "time").?);
    try std.testing.expect(findProp(tp_schema, "theme") == null); // global token set
    // a leaf panel: a document child is rejected
    const cdoc = "{\"name\":\"time_picker\",\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"hi\"}}]}";
    try std.testing.expectError(error.ChildrenNotSupported, treeFromJson(&ctx, std.testing.allocator, cdoc));
}

test "registry: search_bar + navigation_rail (M3E) schemas expose the right editor kinds" {
    const sb_schema = try byName("search_bar").?.schema(std.testing.allocator);
    defer {
        for (sb_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(sb_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(sb_schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(sb_schema, "placeholder").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(sb_schema, "initial").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(sb_schema, "value").?); // the live text
    try std.testing.expect(findProp(sb_schema, "theme") == null); // global token set
    const nr_schema = try byName("navigation_rail").?.schema(std.testing.allocator);
    defer {
        for (nr_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(nr_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(nr_schema, "expanded").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(nr_schema, "selected").?);
    try std.testing.expectEqual(value_mod.EditorKind.unsupported, findProp(nr_schema, "items").?);
    try std.testing.expect(findProp(nr_schema, "theme") == null); // global token set
}

test "registry: card + list_item + menu + segmented_button + split_button (M3E) schemas expose the right editor kinds" {
    const card_schema = try byName("card").?.schema(std.testing.allocator);
    defer {
        for (card_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(card_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(card_schema, "variant").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(card_schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.insets, findProp(card_schema, "padding").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(card_schema, "gap").?);
    const li_schema = try byName("list_item").?.schema(std.testing.allocator);
    defer {
        for (li_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(li_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(li_schema, "lines").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(li_schema, "headline").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(li_schema, "selected").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(li_schema, "leading_icon").?);
    try std.testing.expect(findProp(li_schema, "theme") == null); // global token set
    const menu_schema = try byName("menu").?.schema(std.testing.allocator);
    defer {
        for (menu_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(menu_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(menu_schema, "anchor").?);
    try std.testing.expectEqual(value_mod.EditorKind.unsupported, findProp(menu_schema, "items").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(menu_schema, "open").?);
    try std.testing.expect(findProp(menu_schema, "theme") == null); // global token set
    const seg_schema = try byName("segmented_button").?.schema(std.testing.allocator);
    defer {
        for (seg_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(seg_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.unsupported, findProp(seg_schema, "items").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(seg_schema, "selected").?);
    try std.testing.expect(findProp(seg_schema, "theme") == null); // global token set
    const split_schema = try byName("split_button").?.schema(std.testing.allocator);
    defer {
        for (split_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(split_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(split_schema, "size").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(split_schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(split_schema, "label").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(split_schema, "leading_icon").?);
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(split_schema, "trailing_icon").?);
    try std.testing.expect(findProp(split_schema, "theme") == null); // global token set
}

test "registry: checkbox / slider / radio (M3E) round-trip with their live values" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    // checkbox: "checked" drives a live bool signal
    const cb_doc = "{\"name\":\"checkbox\",\"options\":{\"checked\":true,\"a11y_label\":\"Accept\",\"error\":true}}";
    const cb = try treeFromJson(&ctx, std.testing.allocator, cb_doc);
    defer cb.deinit();
    const cb_out = try treeToJson(&ctx, cb, std.testing.allocator);
    defer std.testing.allocator.free(cb_out);
    try std.testing.expectEqualStrings(cb_doc, cb_out);
    // slider: "value" drives a live f32 signal
    const sl_doc = "{\"name\":\"slider\",\"options\":{\"value\":0.25,\"a11y_label\":\"Volume\",\"default_width\":200}}";
    const sl = try treeFromJson(&ctx, std.testing.allocator, sl_doc);
    defer sl.deinit();
    const sl_out = try treeToJson(&ctx, sl, std.testing.allocator);
    defer std.testing.allocator.free(sl_out);
    try std.testing.expectEqualStrings(sl_doc, sl_out);
    // radio: "selected" drives a live usize signal; "index" selects this radio
    const rd_doc = "{\"name\":\"radio\",\"options\":{\"a11y_label\":\"Two\",\"selected\":2,\"index\":2}}";
    const rd = try treeFromJson(&ctx, std.testing.allocator, rd_doc);
    defer rd.deinit();
    const rd_out = try treeToJson(&ctx, rd, std.testing.allocator);
    defer std.testing.allocator.free(rd_out);
    try std.testing.expectEqualStrings(rd_doc, rd_out);
    try std.testing.expectEqual(true, rd.semantics.?.checked.?); // selected == index
}

test "registry: radios in the same group share one selection signal" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const doc = "{\"name\":\"column\",\"children\":[{\"name\":\"radio\",\"options\":{\"group\":\"g\",\"index\":0,\"selected\":0}},{\"name\":\"radio\",\"options\":{\"group\":\"g\",\"index\":1,\"selected\":0}}]}";
    const node = try treeFromJson(&ctx, std.testing.allocator, doc);
    // one shared signal for the whole group
    try std.testing.expectEqual(@as(usize, 1), ctx.tracked.items.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.radio_groups.count());
    const r0 = node.children.items[0];
    const r1 = node.children.items[1];
    try std.testing.expectEqual(true, r0.semantics.?.checked.?);
    try std.testing.expectEqual(false, r1.semantics.?.checked.?);
    // selecting r1 unchecks r0 (the shared signal)
    _ = r1.vtable.on_pointer.?(r1, .{ .phase = .down, .x = 10, .y = 10, .raw_x = 10, .raw_y = 10 });
    _ = r1.vtable.on_pointer.?(r1, .{ .phase = .up, .x = 10, .y = 10, .raw_x = 10, .raw_y = 10 });
    try std.testing.expectEqual(false, r0.semantics.?.checked.?);
    try std.testing.expectEqual(true, r1.semantics.?.checked.?);
    // a decimal index is accepted (not silently zeroed)
    const dec = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"radio\",\"options\":{\"group\":\"g2\",\"index\":1.0,\"selected\":1}}");
    try std.testing.expectEqual(true, dec.semantics.?.checked.?); // index 1.0 == 1
    // the trees must be deinit'd BEFORE reset (the ctx owns the signals)
    dec.deinit();
    node.deinit();
    ctx.reset();
    try std.testing.expectEqual(@as(usize, 0), ctx.radio_groups.count());
    try std.testing.expectEqual(@as(usize, 0), ctx.tracked.items.len);
}

test "registry: PR B schemas expose the right editor kinds" {
    const progress_schema = try byName("progress").?.schema(std.testing.allocator);
    defer {
        for (progress_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(progress_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.select, findProp(progress_schema, "kind").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(progress_schema, "progress").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(progress_schema, "wavy").?);
    const snackbar_schema = try byName("snackbar").?.schema(std.testing.allocator);
    defer {
        for (snackbar_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(snackbar_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(snackbar_schema, "text").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(snackbar_schema, "visible").?);
    const box_schema = try byName("badged_box").?.schema(std.testing.allocator);
    defer {
        for (box_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(box_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(box_schema, "content").?);
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(box_schema, "badge").?);
}

test "registry: navigation chrome schemas expose slots and live fields" {
    const app_bar_schema = try byName("app_bar").?.schema(std.testing.allocator);
    defer {
        for (app_bar_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(app_bar_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(app_bar_schema, "leading").?);
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(app_bar_schema, "title").?);
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(app_bar_schema, "height").?);
    try std.testing.expect(findProp(app_bar_schema, "theme") == null); // global tokens, not per-widget
    const nav_schema = try byName("nav_bar").?.schema(std.testing.allocator);
    defer {
        for (nav_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(nav_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.number, findProp(nav_schema, "selected").?);
    const drawer_schema = try byName("drawer").?.schema(std.testing.allocator);
    defer {
        for (drawer_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(drawer_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(drawer_schema, "open").?);
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(drawer_schema, "content").?);
    try std.testing.expectEqual(value_mod.EditorKind.slot, findProp(drawer_schema, "body").?);
}

fn findProp(schema: []const value_mod.PropSchema, name: []const u8) ?value_mod.EditorKind {
    for (schema) |p| if (std.mem.eql(u8, p.name, name)) return p.kind;
    return null;
}

test "registry: every entry exposes an inspector schema" {
    for (widgets) |w| {
        const schema = try w.schema(std.testing.allocator);
        for (schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(schema);
    }
    const text_schema = try byName("text").?.schema(std.testing.allocator);
    defer {
        for (text_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(text_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(text_schema, "text").?);
    try std.testing.expectEqual(value_mod.EditorKind.color, findProp(text_schema, "color").?);
    const switch_schema = try byName("switch").?.schema(std.testing.allocator);
    defer {
        for (switch_schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(switch_schema);
    }
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(switch_schema, "checked").?);
    try std.testing.expectEqual(value_mod.EditorKind.toggle, findProp(switch_schema, "enabled").?);
    try std.testing.expectEqual(value_mod.EditorKind.text, findProp(switch_schema, "a11y_label").?);
}

test "registry: slot options build subtrees via the slot builder" {
    const SlotOpts = struct { leading: ?*Node = null, color: u32 = 0xFF };
    const v = try value_mod.parseJson(std.testing.allocator, "{\"leading\":{\"name\":\"divider\"},\"color\":255}");
    defer v.deinit(std.testing.allocator);
    const opts = try value_mod.optionsFromValue(SlotOpts, v, slotBuilder, null);
    try std.testing.expect(opts.leading != null);
    opts.leading.?.deinit();
    // without a builder: unsupported
    try std.testing.expectError(error.UnsupportedFieldType, value_mod.optionsFromValue(SlotOpts, v, null, null));
}
