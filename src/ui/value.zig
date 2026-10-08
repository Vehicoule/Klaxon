// Value — serializable data model for the widget registry (Phase 2d-0.6).
//
// The no-code designer manipulates widget trees as plain data. This module is
// that data model: a JSON-shaped Value tree, conversion to/from typed widget
// options via comptime reflection (@typeInfo — the ADR-0001 argument), and
// schema generation for auto-built inspector forms.
//
// Ownership: every Value owns its strings/arrays/objects — deinit recursively.
// Exception: typed options BORROW strings from the Value they were built from
// (optionsFromValue does not copy); the source Value must outlive the options.
// The registry's BuildCtx owns the snapshots that back built nodes.
//
// JSON: parseJson (std.json) / toJson (hand-rolled writer). Non-finite floats
// (inf/nan) serialize as null; a null field in an options object means "use the
// field default".
const std = @import("std");
const node_mod = @import("node.zig");

const Node = node_mod.Node;

pub const Field = struct {
    name: []const u8, // owned
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8, // owned
    array: []Value, // owned
    object: []Field, // owned

    pub fn deinit(v: Value, allocator: std.mem.Allocator) void {
        switch (v) {
            .null, .bool, .int, .float => {},
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |x| x.deinit(allocator);
                allocator.free(arr);
            },
            .object => |fields| {
                for (fields) |f| {
                    allocator.free(f.name);
                    f.value.deinit(allocator);
                }
                allocator.free(fields);
            },
        }
    }

    pub fn dupe(v: Value, allocator: std.mem.Allocator) !Value {
        switch (v) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .int => |i| return .{ .int = i },
            .float => |f| return .{ .float = f },
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                const items = try allocator.alloc(Value, arr.len);
                errdefer allocator.free(items);
                var i: usize = 0;
                while (i < arr.len) : (i += 1) {
                    items[i] = dupe(arr[i], allocator) catch |e| {
                        for (items[0..i]) |y| y.deinit(allocator);
                        return e;
                    };
                }
                return .{ .array = items };
            },
            .object => |fields| {
                const out = try allocator.alloc(Field, fields.len);
                errdefer allocator.free(out);
                var i: usize = 0;
                while (i < fields.len) : (i += 1) {
                    const name = allocator.dupe(u8, fields[i].name) catch |e| {
                        for (out[0..i]) |f| {
                            allocator.free(f.name);
                            f.value.deinit(allocator);
                        }
                        return e;
                    };
                    const val = dupe(fields[i].value, allocator) catch |e| {
                        allocator.free(name);
                        for (out[0..i]) |f| {
                            allocator.free(f.name);
                            f.value.deinit(allocator);
                        }
                        return e;
                    };
                    out[i] = .{ .name = name, .value = val };
                }
                return .{ .object = out };
            },
        }
    }

    /// Object field lookup (linear — options objects are small).
    pub fn get(v: Value, name: []const u8) ?Value {
        if (v != .object) return null;
        for (v.object) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    /// Deep equality. Numbers compare numerically across int/float (JSON has
    /// one number type); objects compare order-insensitively.
    pub fn eql(a: Value, b: Value) bool {
        if (a == .null or b == .null) return a == .null and b == .null;
        if (isNum(a) and isNum(b)) return numF(a) == numF(b);
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .bool => |x| return x == b.bool,
            .string => |x| return std.mem.eql(u8, x, b.string),
            .array => |x| {
                const y = b.array;
                if (x.len != y.len) return false;
                for (x, 0..) |xi, i| if (!eql(xi, y[i])) return false;
                return true;
            },
            .object => |x| {
                const y = b.object;
                if (x.len != y.len) return false;
                for (x) |f| {
                    const obj = Value{ .object = y };
                    const g = obj.get(f.name) orelse return false;
                    if (!eql(f.value, g)) return false;
                }
                return true;
            },
            else => unreachable, // null and numbers handled above
        }
    }
};

fn isNum(v: Value) bool {
    return switch (v) {
        .int, .float => true,
        else => false,
    };
}

fn numF(v: Value) f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
}

// --- JSON ---

pub fn parseJson(allocator: std.mem.Allocator, json: []const u8) !Value {
    // Convert inside an arena (error paths free themselves), then hand the
    // caller an owned copy.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const v = try fromStdJson(a, parsed.value);
    return v.dupe(allocator);
}

fn fromStdJson(allocator: std.mem.Allocator, v: std.json.Value) !Value {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |i| return .{ .int = i } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
            return error.InvalidNumber;
        },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            const items = try allocator.alloc(Value, arr.items.len);
            errdefer allocator.free(items);
            var i: usize = 0;
            while (i < arr.items.len) : (i += 1) {
                items[i] = fromStdJson(allocator, arr.items[i]) catch |e| {
                    for (items[0..i]) |y| y.deinit(allocator);
                    return e;
                };
            }
            return .{ .array = items };
        },
        .object => |obj| {
            var fields = std.array_list.Managed(Field).init(allocator);
            errdefer {
                for (fields.items) |f| {
                    allocator.free(f.name);
                    f.value.deinit(allocator);
                }
                fields.deinit();
            }
            var it = obj.iterator();
            while (it.next()) |e| {
                try fields.append(.{
                    .name = try allocator.dupe(u8, e.key_ptr.*),
                    .value = try fromStdJson(allocator, e.value_ptr.*),
                });
            }
            return .{ .object = try fields.toOwnedSlice() };
        },
    }
}

pub fn toJson(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try writeJsonValue(&buf, allocator, v);
    return buf.toOwnedSlice();
}

fn writeJsonValue(buf: *std.array_list.Managed(u8), allocator: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .null => try buf.appendSlice("null"),
        .bool => |b| try buf.appendSlice(if (b) "true" else "false"),
        .int => |i| try writeNum(buf, allocator, i),
        .float => |f| {
            // inf/nan have no JSON form — null means "use the field default"
            if (!std.math.isFinite(f)) return buf.appendSlice("null");
            try writeNum(buf, allocator, f);
        },
        .string => |s| try writeJsonString(buf, s),
        .array => |arr| {
            try buf.append('[');
            for (arr, 0..) |x, i| {
                if (i > 0) try buf.append(',');
                try writeJsonValue(buf, allocator, x);
            }
            try buf.append(']');
        },
        .object => |fields| {
            try buf.append('{');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.append(',');
                try writeJsonString(buf, f.name);
                try buf.append(':');
                try writeJsonValue(buf, allocator, f.value);
            }
            try buf.append('}');
        },
    }
}

fn writeNum(buf: *std.array_list.Managed(u8), allocator: std.mem.Allocator, x: anytype) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{d}", .{x});
    defer allocator.free(tmp);
    try buf.appendSlice(tmp);
}

fn writeJsonString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    try buf.append('"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice("\\\""),
        '\\' => try buf.appendSlice("\\\\"),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        '\t' => try buf.appendSlice("\\t"),
        else => |ch| {
            if (ch < 0x20) {
                const tmp = try std.fmt.allocPrint(buf.allocator, "\\u{x:0>4}", .{ch});
                defer buf.allocator.free(tmp);
                try buf.appendSlice(tmp);
            } else try buf.append(ch);
        },
    };
    try buf.append('"');
}

// --- Typed options <-> Value (comptime adapters) ---

/// Builds a node slot (a ?*Node / *Node options field) from a subtree Value.
pub const SlotBuilder = *const fn (userdata: ?*anyopaque, v: Value) anyerror!*Node;
/// Describes a live node back into a tree Value (for slot fields).
pub const DescribeNodeFn = *const fn (userdata: ?*anyopaque, n: *Node) anyerror!Value;

/// Typed options from a Value object. Missing fields keep their defaults;
/// null fields mean "default"; unknown fields are ignored. Strings are
/// BORROWED from `v` (see the file header).
pub fn optionsFromValue(comptime T: type, v: Value, slot_builder: ?SlotBuilder, slot_userdata: ?*anyopaque) !T {
    if (v != .object) return error.ExpectedObject;
    var opts: T = .{};
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        if (v.get(name)) |fv| {
            // no `continue` here: it is comptime control flow inside a
            // runtime block (the if) — invert the condition instead
            if (fv != .null) {
                @field(opts, name) = try fieldFromValue(FT, fv, slot_builder, slot_userdata);
            }
        }
    }
    return opts;
}

fn fieldFromValue(comptime FT: type, v: Value, slot_builder: ?SlotBuilder, slot_userdata: ?*anyopaque) !FT {
    switch (@typeInfo(FT)) {
        .bool => return switch (v) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },
        .int => return switch (v) {
            .int => |i| @intCast(i),
            .float => |f| @intFromFloat(f),
            else => error.TypeMismatch,
        },
        .float => return switch (v) {
            .float => |f| @floatCast(f),
            .int => |i| @floatFromInt(i),
            else => error.TypeMismatch,
        },
        .@"enum" => return switch (v) {
            .string => |s| std.meta.stringToEnum(FT, s) orelse return error.UnknownEnumTag,
            else => error.TypeMismatch,
        },
        .optional => |o| {
            if (v == .null) return null;
            // slots (*Node) are handled by the .pointer arm below
            return try fieldFromValue(o.child, v, slot_builder, slot_userdata);
        },
        .pointer => {
            // comptime ifs: the dead branches must not type-check against FT
            if (comptime isByteSlice(FT)) {
                return switch (v) {
                    .string => |s| s,
                    else => error.TypeMismatch,
                };
            }
            if (comptime isNodePtr(FT)) return try buildSlot(v, slot_builder, slot_userdata);
            return error.UnsupportedFieldType;
        },
        .@"struct" => return try optionsFromValue(FT, v, slot_builder, slot_userdata),
        else => return error.UnsupportedFieldType,
    }
}

/// Typed options to a Value object (owned — caller deinits). Slot fields are
/// described via `describe_node` (or become null without one).
pub fn valueFromOptions(allocator: std.mem.Allocator, comptime T: type, opts: T, describe_node: ?DescribeNodeFn, userdata: ?*anyopaque) !Value {
    var fields = std.array_list.Managed(Field).init(allocator);
    errdefer {
        for (fields.items) |f| {
            allocator.free(f.name); // names are owned (duped below)
            f.value.deinit(allocator);
        }
        fields.deinit();
    }
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        const fv = try valueOfField(allocator, FT, @field(opts, name), describe_node, userdata);
        try fields.append(.{ .name = try allocator.dupe(u8, name), .value = fv });
    }
    return .{ .object = try fields.toOwnedSlice() };
}

fn valueOfField(allocator: std.mem.Allocator, comptime FT: type, val: FT, describe_node: ?DescribeNodeFn, userdata: ?*anyopaque) !Value {
    switch (@typeInfo(FT)) {
        .bool => return .{ .bool = val },
        .int => return .{ .int = val },
        .float => return .{ .float = val },
        .@"enum" => return .{ .string = try allocator.dupe(u8, @tagName(val)) },
        .optional => |o| {
            if (val == null) return .null;
            return try valueOfField(allocator, o.child, val.?, describe_node, userdata);
        },
        .pointer => {
            if (comptime isByteSlice(FT)) return .{ .string = try allocator.dupe(u8, val) };
            if (comptime isNodePtr(FT)) {
                const d = describe_node orelse return .null;
                return try d(userdata, val);
            }
            return error.UnsupportedFieldType;
        },
        .@"struct" => return try valueFromOptions(allocator, FT, val, describe_node, userdata),
        else => return error.UnsupportedFieldType,
    }
}

fn isNodePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and p.child == Node,
        else => false,
    };
}

fn isByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

fn buildSlot(v: Value, slot_builder: ?SlotBuilder, slot_userdata: ?*anyopaque) !*Node {
    const b = slot_builder orelse return error.UnsupportedFieldType;
    return b(slot_userdata, v);
}

// --- Inspector schema (auto-generated property forms) ---

pub const EditorKind = enum { toggle, number, text, color, select, insets, slot, unsupported };

pub const PropSchema = struct {
    name: []const u8, // comptime (field name) — not owned
    kind: EditorKind,
    enum_tags: []const []const u8, // owned slice; the strings are comptime
    default: Value, // owned

    pub fn deinit(p: *PropSchema, allocator: std.mem.Allocator) void {
        p.default.deinit(allocator);
        allocator.free(p.enum_tags);
    }
};

/// Options type → inspector schema (one PropSchema per editable field).
/// Unsupported fields (callbacks, arbitrary pointers, nested structs) are
/// skipped — the designer edits data fields only.
pub fn schemaOf(comptime T: type, allocator: std.mem.Allocator) ![]PropSchema {
    const info = @typeInfo(T).@"struct";
    var list = std.array_list.Managed(PropSchema).init(allocator);
    errdefer {
        for (list.items) |*p| p.deinit(allocator);
        list.deinit();
    }
    inline for (info.field_names, info.field_types) |name, FT| {
        const kind = editorKindOf(FT, name);
        // no `continue` inside inline for (comptime control flow in a runtime
        // block) — wrap the body in the inverted condition instead
        if (kind != .unsupported) {
            var ps = PropSchema{ .name = name, .kind = kind, .enum_tags = &.{}, .default = .null };
            errdefer ps.deinit(allocator);
            const def_opts: T = .{};
            ps.default = try valueOfField(allocator, FT, @field(def_opts, name), null, null);
            const U = unwrapOptional(FT);
            if (@typeInfo(U) == .@"enum") {
                const ei = @typeInfo(U).@"enum";
                var buf: [ei.field_names.len][]const u8 = undefined;
                inline for (ei.field_names, 0..) |fname, i| buf[i] = fname;
                ps.enum_tags = try allocator.dupe([]const u8, &buf);
            }
            try list.append(ps);
        }
    }
    return list.toOwnedSlice();
}

fn editorKindOf(comptime FT: type, name: []const u8) EditorKind {
    const U = unwrapOptional(FT);
    switch (@typeInfo(U)) {
        .bool => return .toggle,
        .int, .float => return if (looksLikeColor(name)) .color else .number,
        .@"enum" => return .select,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return .text;
            if (p.size == .one and p.child == Node) return .slot;
            return .unsupported;
        },
        .@"struct" => return if (isInsetsStruct(U)) .insets else .unsupported,
        else => return .unsupported,
    }
}

fn unwrapOptional(comptime FT: type) type {
    return switch (@typeInfo(FT)) {
        .optional => |o| o.child,
        else => FT,
    };
}

/// Color fields are detected by name (Color is a u32 alias — indistinguishable
/// from a plain int at comptime). Heuristic for the inspector only.
fn looksLikeColor(name: []const u8) bool {
    const hints = [_][]const u8{ "color", "bg", "track", "fill", "knob", "ring", "dot", "check", "accent", "scrim", "tint", "shadow", "border", "outline", "surface", "primary", "secondary", "tertiary", "error", "inverse", "on_" };
    for (hints) |h| if (std.mem.indexOf(u8, name, h) != null) return true;
    return false;
}

fn isInsetsStruct(comptime T: type) bool {
    const info = @typeInfo(T).@"struct";
    if (info.field_names.len != 4) return false;
    var has: usize = 0;
    inline for (info.field_names) |n| {
        if (std.mem.eql(u8, n, "left") or std.mem.eql(u8, n, "top") or std.mem.eql(u8, n, "right") or std.mem.eql(u8, n, "bottom")) has += 1;
    }
    return has == 4;
}

// --- tests ---

const TestAlign = enum { start, center, end };
const TestInsets = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };
const TestOpts = struct {
    bg: u32 = 0x3B5BDBFF,
    radius: f32 = 8,
    label: []const u8 = "hi",
    text_align: TestAlign = .start,
    pad: TestInsets = .{},
    knob_on: ?u32 = null,
};

test "value: dupe + eql + deinit" {
    const a = try parseJson(std.testing.allocator, "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{\"d\":2.5}}");
    defer a.deinit(std.testing.allocator);
    const b = try a.dupe(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(Value.eql(a, b));
    // numeric equality across int/float; order-insensitive objects
    const c = try parseJson(std.testing.allocator, "{\"c\":{\"d\":2.5},\"b\":[true,null,\"x\"],\"a\":1.0}");
    defer c.deinit(std.testing.allocator);
    try std.testing.expect(Value.eql(a, c));
    try std.testing.expect(!Value.eql(a, Value{ .int = 1 }));
}

test "value: JSON round-trip is stable" {
    const doc = "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{\"d\":2.5},\"e\":\"quote\\\"and\\\\slash\"}";
    const v = try parseJson(std.testing.allocator, doc);
    defer v.deinit(std.testing.allocator);
    const out = try toJson(std.testing.allocator, v);
    defer std.testing.allocator.free(out);
    const v2 = try parseJson(std.testing.allocator, out);
    defer v2.deinit(std.testing.allocator);
    try std.testing.expect(Value.eql(v, v2));
    // field access
    try std.testing.expectEqual(@as(i64, 1), v.get("a").?.int);
    try std.testing.expectEqual(@as(f64, 2.5), v.get("c").?.get("d").?.float);
}

test "value: optionsFromValue applies defaults, overrides, null-means-default" {
    // empty object → all defaults
    const empty = try parseJson(std.testing.allocator, "{}");
    defer empty.deinit(std.testing.allocator);
    const d = try optionsFromValue(TestOpts, empty, null, null);
    try std.testing.expectEqual(@as(u32, 0x3B5BDBFF), d.bg);
    try std.testing.expectEqual(@as(f32, 8), d.radius);
    try std.testing.expectEqualStrings("hi", d.label);
    try std.testing.expect(d.knob_on == null);
    // overrides
    const full = try parseJson(std.testing.allocator, "{\"bg\":255,\"radius\":4.5,\"label\":\"yo\",\"text_align\":\"end\",\"pad\":{\"left\":2},\"knob_on\":7}");
    defer full.deinit(std.testing.allocator);
    const o = try optionsFromValue(TestOpts, full, null, null);
    try std.testing.expectEqual(@as(u32, 255), o.bg);
    try std.testing.expectEqual(@as(f32, 4.5), o.radius);
    try std.testing.expectEqualStrings("yo", o.label);
    try std.testing.expectEqual(TestAlign.end, o.text_align);
    try std.testing.expectEqual(@as(f32, 2), o.pad.left);
    try std.testing.expectEqual(@as(u32, 7), o.knob_on.?);
    // null field → default
    const nulled = try parseJson(std.testing.allocator, "{\"radius\":null}");
    defer nulled.deinit(std.testing.allocator);
    const n = try optionsFromValue(TestOpts, nulled, null, null);
    try std.testing.expectEqual(@as(f32, 8), n.radius);
}

test "value: options round-trip valueFromOptions ∘ optionsFromValue" {
    const opts: TestOpts = .{ .bg = 42, .radius = 3.25, .label = "round", .text_align = .center, .pad = .{ .top = 6 }, .knob_on = 99 };
    const v = try valueFromOptions(std.testing.allocator, TestOpts, opts, null, null);
    defer v.deinit(std.testing.allocator);
    const back = try optionsFromValue(TestOpts, v, null, null);
    try std.testing.expectEqual(opts.bg, back.bg);
    try std.testing.expectEqual(opts.radius, back.radius);
    try std.testing.expectEqualStrings(opts.label, back.label);
    try std.testing.expectEqual(opts.text_align, back.text_align);
    try std.testing.expectEqual(opts.pad.top, back.pad.top);
    try std.testing.expectEqual(opts.knob_on, back.knob_on);
}

test "value: type mismatch errors" {
    const bad = try parseJson(std.testing.allocator, "{\"radius\":\"big\"}");
    defer bad.deinit(std.testing.allocator);
    try std.testing.expectError(error.TypeMismatch, optionsFromValue(TestOpts, bad, null, null));
    const bad_enum = try parseJson(std.testing.allocator, "{\"text_align\":\"nope\"}");
    defer bad_enum.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownEnumTag, optionsFromValue(TestOpts, bad_enum, null, null));
    try std.testing.expectError(error.ExpectedObject, optionsFromValue(TestOpts, Value{ .int = 5 }, null, null));
}

test "value: schemaOf kinds, enum tags, defaults" {
    const schema = try schemaOf(TestOpts, std.testing.allocator);
    defer {
        for (schema) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(schema);
    }
    try std.testing.expectEqual(@as(usize, 6), schema.len);
    try std.testing.expectEqual(EditorKind.color, schema[0].kind); // bg
    try std.testing.expectEqual(EditorKind.number, schema[1].kind); // radius
    try std.testing.expectEqual(EditorKind.text, schema[2].kind); // label
    try std.testing.expectEqual(EditorKind.select, schema[3].kind); // align
    try std.testing.expectEqual(@as(usize, 3), schema[3].enum_tags.len);
    try std.testing.expectEqualStrings("center", schema[3].enum_tags[1]);
    try std.testing.expectEqual(EditorKind.insets, schema[4].kind); // pad
    try std.testing.expectEqual(EditorKind.color, schema[5].kind); // knob_on (?u32 unwrapped)
    try std.testing.expect(schema[5].default == .null);
    try std.testing.expectEqual(@as(i64, 0x3B5BDBFF), schema[0].default.int);
}
