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
/// M3E text field, filled / outlined).
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

/// M3E text field (2d.2 PR C2): a non-null "value" option drives a ctx-owned
/// text signal (the live current text, mirrored both ways); without it, the
/// text starts at the "initial" option. The widget is a leaf — document
/// children never serialize.
fn buildTextField(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!BuildResult {
    const topts = try value_mod.optionsFromValue(text_field_w.TextFieldOptions, opts, null, null);
    // a null "value" means the field default (no live signal)
    const has_value = if (opts.get("value")) |v| v != .null else false;
    if (has_value) {
        const initial: []const u8 = switch (opts.get("value").?) {
            .string => |s| s,
            else => "",
        };
        const sig = try state.Signal(text_field_w.TextBuf).init(allocator, text_field_w.bufFromText(initial));
        try ctx.track(sig, deinitTextSignal);
        const n = try text_field_w.textField(allocator, sig, null, null, topts);
        return .{ .node = n, .live = .{ .signal = sig, .field = "value", .read = readTextSignal } };
    }
    return .{ .node = try text_field_w.textField(allocator, null, null, null, topts) };
}

fn readTextSignal(allocator: std.mem.Allocator, p: *anyopaque) anyerror!Value {
    const s: *state.Signal(text_field_w.TextBuf) = @ptrCast(@alignCast(p));
    const v = s.peek();
    const len = std.mem.indexOfScalar(u8, &v, 0) orelse v.len;
    return .{ .string = try allocator.dupe(u8, v[0..len]) }; // owned (Value.set takes ownership)
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
    try std.testing.expectEqual(@as(usize, 27), widgets.len);
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
    // plain: no "value" → fixed initial text, no live binding
    const plain_doc = "{\"name\":\"text_field\",\"options\":{\"variant\":\"filled\",\"initial\":\"Hi\"}}";
    const plain = try treeFromJson(&ctx, std.testing.allocator, plain_doc);
    defer plain.deinit();
    const plain_out = try treeToJson(&ctx, plain, std.testing.allocator);
    defer std.testing.allocator.free(plain_out);
    try std.testing.expectEqualStrings(plain_doc, plain_out);
    try std.testing.expectEqualStrings("Hi", plain.semantics.?.value);
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
