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
const golden = @import("golden.zig"); // tests

/// Options type for widgets without options.
pub const NoOptions = struct {};

pub const BuildFn = *const fn (allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node;

pub const WidgetEntry = struct {
    name: []const u8,
    category: []const u8, // "layout" | "display" | "input" | ...
    build: BuildFn,
};

/// Registry v1: layout + display + input. Batch 1+ widgets self-register here.
pub const widgets = [_]WidgetEntry{
    .{ .name = "column", .category = "layout", .build = buildColumn },
    .{ .name = "row", .category = "layout", .build = buildRow },
    .{ .name = "padding", .category = "layout", .build = buildPadding },
    .{ .name = "center", .category = "layout", .build = buildCenter },
    .{ .name = "constrained_box", .category = "layout", .build = buildConstrainedBox },
    .{ .name = "divider", .category = "display", .build = buildDivider },
    .{ .name = "text", .category = "display", .build = buildText },
    .{ .name = "icon", .category = "display", .build = buildIcon },
    .{ .name = "button", .category = "input", .build = buildButton },
    .{ .name = "toggle", .category = "input", .build = buildToggle },
    .{ .name = "checkbox", .category = "input", .build = buildCheckbox },
    .{ .name = "slider", .category = "input", .build = buildSlider },
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

    const Record = struct {
        entry_name: []const u8,
        opts: Value, // owned snapshot — nodes borrow strings from it
    };
    const Tracked = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque) void, // Signal.deinit frees itself
    };

    pub fn init(allocator: std.mem.Allocator) BuildCtx {
        return .{
            .allocator = allocator,
            .records = std.AutoHashMap(*Node, Record).init(allocator),
            .tracked = std.array_list.Managed(Tracked).init(allocator),
        };
    }

    pub fn deinit(ctx: *BuildCtx) void {
        ctx.clear();
        ctx.records.deinit();
        ctx.tracked.deinit();
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
        for (ctx.tracked.items) |t| t.deinit_fn(t.ptr);
        ctx.tracked.clearRetainingCapacity();
    }

    fn track(ctx: *BuildCtx, ptr: *anyopaque, deinit_fn: *const fn (*anyopaque) void) !void {
        try ctx.tracked.append(.{ .ptr = ptr, .deinit_fn = deinit_fn });
    }

    /// Stores the snapshot (takes ownership on success).
    fn recordAdopt(ctx: *BuildCtx, n: *Node, entry_name: []const u8, opts: Value) !void {
        ctx.records.put(n, .{ .entry_name = entry_name, .opts = opts }) catch |e| return e;
    }
};

// --- tree <-> data ---

pub fn treeFromValue(ctx: *BuildCtx, v: Value) !*Node {
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
    const node = entry.build(ctx.allocator, snapshot, ctx) catch |e| {
        snapshot.deinit(ctx.allocator); // build failed: no record yet
        return e;
    };
    errdefer node.deinit();
    ctx.recordAdopt(node, entry.name, snapshot) catch |e| {
        snapshot.deinit(ctx.allocator);
        return e;
    };
    if (v.get("children")) |c| {
        switch (c) {
            .array => |arr| for (arr) |cv| {
                const child = try treeFromValue(ctx, cv);
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
    // Canonical form: empty options / children are omitted (round-trip exact).
    if (rec.opts == .object and rec.opts.object.len > 0) {
        try fields.append(.{ .name = try allocator.dupe(u8, "options"), .value = try rec.opts.dupe(allocator) });
    }
    var children = std.array_list.Managed(Value).init(allocator);
    errdefer {
        for (children.items) |c| c.deinit(allocator);
        children.deinit();
    }
    for (root.children.items) |child| try children.append(try treeToValue(ctx, child, allocator));
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

fn buildColumn(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return layout_w.column(allocator, try value_mod.optionsFromValue(layout_w.FlexOptions, opts, null, null));
}

fn buildRow(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return layout_w.row(allocator, try value_mod.optionsFromValue(layout_w.FlexOptions, opts, null, null));
}

fn buildPadding(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return layout_w.padding(allocator, try value_mod.optionsFromValue(ui.layout.EdgeInsets, opts, null, null));
}

fn buildCenter(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = opts;
    _ = ctx;
    return layout_w.center(allocator);
}

fn buildConstrainedBox(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return layout_w.constrainedBox(allocator, try value_mod.optionsFromValue(layout_w.ConstrainedBoxOptions, opts, null, null));
}

fn buildDivider(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return divider_w.divider(allocator, try value_mod.optionsFromValue(divider_w.DividerOptions, opts, null, null));
}

fn buildText(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    const topts = try value_mod.optionsFromValue(text_w.TextOptions, opts, null, null);
    const str: []const u8 = if (opts.get("text")) |t| switch (t) {
        .string => |s| s,
        else => "",
    } else "";
    return text_w.text(allocator, str, topts);
}

fn buildIcon(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    const iopts = try value_mod.optionsFromValue(icon_w.IconOptions, opts, null, null);
    const name_str: []const u8 = if (opts.get("icon")) |t| switch (t) {
        .string => |s| s,
        else => "star",
    } else "star";
    const iname = std.meta.stringToEnum(icon_w.IconName, name_str) orelse return error.UnknownIcon;
    return icon_w.icon(allocator, iname, iopts);
}

fn buildButton(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    _ = ctx;
    return input_w.button(allocator, null, try value_mod.optionsFromValue(input_w.ButtonOptions, opts, null, null));
}

fn buildToggle(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    const topts = try value_mod.optionsFromValue(input_w.ToggleOptions, opts, null, null);
    const sig = try state.Signal(bool).init(allocator, false); // *Signal(bool)
    try ctx.track(sig, deinitBoolSignal);
    return input_w.toggle(allocator, sig, null, topts);
}

fn deinitBoolSignal(p: *anyopaque) void {
    const s: *state.Signal(bool) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
}

fn buildCheckbox(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    const copts = try value_mod.optionsFromValue(input_w.CheckboxOptions, opts, null, null);
    const sig = try state.Signal(bool).init(allocator, false); // *Signal(bool)
    try ctx.track(sig, deinitBoolSignal);
    return input_w.checkbox(allocator, sig, null, copts);
}

fn buildSlider(allocator: std.mem.Allocator, opts: Value, ctx: *BuildCtx) anyerror!*Node {
    const sopts = try value_mod.optionsFromValue(input_w.SliderOptions, opts, null, null);
    const sig = try state.Signal(f32).init(allocator, 0.5); // *Signal(f32)
    try ctx.track(sig, deinitF32Signal);
    return input_w.slider(allocator, sig, null, sopts);
}

fn deinitF32Signal(p: *anyopaque) void {
    const s: *state.Signal(f32) = @ptrCast(@alignCast(p));
    s.deinit(); // Signal.deinit frees itself (state.zig)
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
    try std.testing.expect(byName("nope") == null);
    try std.testing.expectEqual(@as(usize, 12), widgets.len);
}

test "registry: builds a node with defaults from a minimal value" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\"}");
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 0), node.children.items.len);
}

test "registry: tree round-trip preserves the document" {
    const doc = "{\"name\":\"column\",\"options\":{\"gap\":8,\"main_align\":\"center\"},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"Hello\",\"size\":20,\"color\":16777215}},{\"name\":\"button\",\"options\":{\"bg\":287454020,\"radius\":4},\"children\":[{\"name\":\"text\",\"options\":{\"text\":\"OK\"}}]}]}";
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
    const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":[{\"name\":\"toggle\"},{\"name\":\"checkbox\"},{\"name\":\"slider\"}]}");
    defer node.deinit();
    try std.testing.expectEqual(@as(usize, 3), node.children.items.len);
    try std.testing.expectEqual(@as(usize, 3), ctx.tracked.items.len);
}

test "registry: reset frees records and signals between builds" {
    var ctx = BuildCtx.init(std.testing.allocator);
    defer ctx.deinit();
    {
        const node = try treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"toggle\"}");
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
    try std.testing.expectError(error.ExpectedArray, treeFromJson(&ctx, std.testing.allocator, "{\"name\":\"column\",\"children\":{}}"));
    const alien = try golden.solidBox(std.testing.allocator, 4, 4, 0xFF);
    defer alien.deinit();
    try std.testing.expectError(error.UnregisteredNode, treeToValue(&ctx, alien, std.testing.allocator));
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
