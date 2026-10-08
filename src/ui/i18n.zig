// Internationalization (Phase 2b) — locales, translation, interpolation,
// ARB plural rules, number/date formatting, and the text direction (RTL).
//
//   - Locales are loaded from ARB files (JSON): `addArb(tag, json, dir)`.
//     Keys starting with '@' are metadata and skipped.
//   - `tr(key)` resolves a message in the current locale, falling back to
//     the fallback locale, then to the key itself. Borrowed slice (no alloc).
//   - Interpolation: ARB placeholders `{name}` are filled from a comptime
//     args struct (`trArgs(i18n, alloc, key, .{ .name = "Léa" })`).
//   - Pluralization: ARB plural blocks `{count, plural, =0 {...} one {...}
//     other {...}}` with CLDR category rules (en/fr/ja/ar built in; the
//     default rule is one/other). `#` and `{count}` expand to the count.
//   - Number/date formatting: per-locale tables (separators, date patterns,
//     month names) for en/fr/ja/ar. Pure Zig — the ICU binding (full CLDR
//     tables, native digits) is the documented upgrade path.
//   - Direction: the current locale's direction is process-global
//     (`direction()`, like the input router / timeline) — the layout layer
//     mirrors horizontal flex, alignment and start/end insets/text-align.
//   - Runtime switching: `setLocale` flips a signal — localized widgets
//     re-render; when the direction flips, `on_direction_changed` fires so
//     the app can mark the root layout-dirty (RTL re-mirrors the layout).
const std = @import("std");
const state_mod = @import("state.zig");

/// Text direction (drives the layout mirror, Phase 2b.2).
pub const Direction = enum { ltr, rtl };

// --- Locale ---

pub const Date = struct { year: i32, month: u8, day: u8 }; // month 1..12

pub const DateKind = enum { short, medium, long };

pub const NumberOptions = struct {
    /// Fixed fraction digits (null = shortest round-trip representation).
    decimals: ?u8 = null,
    percent: bool = false,
    grouping: bool = true,
};

pub const Locale = struct {
    allocator: std.mem.Allocator,
    tag: []const u8, // owned ("fr-FR")
    direction: Direction = .ltr,
    messages: std.StringHashMap([]const u8), // key → message (both owned)
    // Number formatting.
    decimal_sep: []const u8 = ".",
    group_sep: []const u8 = ",",
    // Date formatting (pattern tokens: y, M, d — repeats set the width).
    date_short: []const u8 = "M/d/yy",
    date_medium: []const u8 = "MMM d, y",
    date_long: []const u8 = "MMMM d, y",
    month_long: [12][]const u8 = .{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
    month_short: [12][]const u8 = .{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
    months_owned: bool = false, // month names were duped (applyFormatData)

    pub fn init(allocator: std.mem.Allocator, tag: []const u8) !*Locale {
        const loc = try allocator.create(Locale);
        loc.* = .{
            .allocator = allocator,
            .tag = try allocator.dupe(u8, tag),
            .messages = std.StringHashMap([]const u8).init(allocator),
        };
        return loc;
    }

    pub fn deinit(loc: *Locale) void {
        var it = loc.messages.iterator();
        while (it.next()) |entry| {
            // keys and values are both owned (duped at parse time)
            loc.allocator.free(entry.key_ptr.*);
            loc.allocator.free(entry.value_ptr.*);
        }
        loc.messages.deinit();
        loc.allocator.free(loc.tag);
        if (loc.months_owned) {
            for (loc.month_long) |m| loc.allocator.free(m);
            for (loc.month_short) |m| loc.allocator.free(m);
        }
        loc.allocator.destroy(loc);
    }

    /// Parse an ARB document (JSON) into the message table. '@'-prefixed
    /// keys (@@locale, @key metadata) are skipped.
    pub fn parseArb(loc: *Locale, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, loc.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArb;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len == 0 or key[0] == '@') continue;
            const value = entry.value_ptr.*;
            if (value != .string) continue;
            // StringHashMap stores the key slice as-is: dupe it (owned).
            try loc.messages.put(try loc.allocator.dupe(u8, key), try loc.allocator.dupe(u8, value.string));
        }
    }

    /// Format a number per the locale (grouping, separators, percent).
    pub fn formatNumber(loc: *const Locale, allocator: std.mem.Allocator, value: f64, opts: NumberOptions) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        var v = value;
        if (v < 0) {
            try buf.append('-');
            v = -v;
        }
        if (opts.percent) v *= 100;
        // Shortest round-trip digits, then split integer/fraction.
        var digits_buf: [64]u8 = undefined;
        const all = try std.fmt.bufPrint(&digits_buf, "{d}", .{v});
        var int_part = all;
        var frac_part: []const u8 = "";
        if (std.mem.indexOfScalar(u8, all, '.')) |dot| {
            int_part = all[0..dot];
            frac_part = all[dot + 1 ..];
        }
        // Group the integer part (groups of 3, from the right).
        if (opts.grouping and int_part.len > 3) {
            const len = int_part.len;
            const rem = len % 3;
            const first_n = if (rem == 0) 3 else rem;
            try buf.appendSlice(int_part[0..first_n]);
            var pos = first_n;
            while (pos < len) {
                try buf.appendSlice(loc.group_sep);
                try buf.appendSlice(int_part[pos .. pos + 3]);
                pos += 3;
            }
        } else {
            try buf.appendSlice(int_part);
        }
        if (opts.decimals) |d| {
            // Exactly d fraction digits, zero-padded (any precision — the
            // digits go straight into the output buffer).
            if (d > 0) {
                try buf.appendSlice(loc.decimal_sep);
                var i: usize = 0;
                while (i < d) : (i += 1) {
                    try buf.append(if (i < frac_part.len) frac_part[i] else '0');
                }
            }
        } else if (frac_part.len > 0) {
            try buf.appendSlice(loc.decimal_sep);
            try buf.appendSlice(frac_part);
        }
        if (opts.percent) try buf.append('%');
        return buf.toOwnedSlice();
    }

    /// Format a date per the locale and kind (pattern tokens y/M/d).
    pub fn formatDate(loc: *const Locale, allocator: std.mem.Allocator, date: Date, kind: DateKind) ![]u8 {
        const pattern = switch (kind) {
            .short => loc.date_short,
            .medium => loc.date_medium,
            .long => loc.date_long,
        };
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        var year_buf: [8]u8 = undefined;
        var num_buf: [8]u8 = undefined;
        var i: usize = 0;
        while (i < pattern.len) {
            const ch = pattern[i];
            if (ch != 'y' and ch != 'M' and ch != 'd') {
                try buf.append(ch);
                i += 1;
                continue;
            }
            var j = i;
            while (j < pattern.len and pattern[j] == ch) j += 1;
            const n = j - i;
            switch (ch) {
                'y' => {
                    // CLDR: y = full year, yy = 2-digit year (zero-padded,
                    // correct for years < 10 too).
                    if (n == 2) {
                        // @mod is euclidean (always >= 0) — cast to unsigned:
                        // Zig 0.17 pads signed ints with an explicit sign.
                        const yy: u32 = @intCast(@mod(date.year, 100));
                        try buf.appendSlice(try std.fmt.bufPrint(&num_buf, "{d:0>2}", .{yy}));
                    } else {
                        try buf.appendSlice(try std.fmt.bufPrint(&year_buf, "{d}", .{date.year}));
                    }
                },
                'M' => {
                    const m = date.month - 1; // 0-based
                    switch (n) {
                        1 => try buf.appendSlice(try std.fmt.bufPrint(&num_buf, "{d}", .{date.month})),
                        2 => try buf.appendSlice(try std.fmt.bufPrint(&num_buf, "{d:0>2}", .{date.month})),
                        3 => try buf.appendSlice(loc.month_short[m]),
                        else => try buf.appendSlice(loc.month_long[m]),
                    }
                },
                'd' => {
                    try buf.appendSlice(if (n >= 2)
                        try std.fmt.bufPrint(&num_buf, "{d:0>2}", .{date.day})
                    else
                        try std.fmt.bufPrint(&num_buf, "{d}", .{date.day}));
                },
                else => unreachable,
            }
            i = j;
        }
        return buf.toOwnedSlice();
    }
};

// --- Per-locale format data (en/fr/ja/ar built in; ICU is the upgrade path) ---

/// Apply the built-in format data (separators, date patterns, month names)
/// for a known locale tag. Unknown tags keep the English defaults.
pub fn applyFormatData(loc: *Locale) void {
    const base = if (std.mem.indexOfScalar(u8, loc.tag, '-')) |i| loc.tag[0..i] else loc.tag;
    if (std.mem.eql(u8, base, "fr")) {
        loc.decimal_sep = ",";
        loc.group_sep = " ";
        loc.date_short = "dd/MM/y";
        loc.date_medium = "d MMM y";
        loc.date_long = "d MMMM y";
        setMonths(loc, &.{
            "janvier",
            "février",
            "mars",
            "avril",
            "mai",
            "juin",
            "juillet",
            "août",
            "septembre",
            "octobre",
            "novembre",
            "décembre",
        }, &.{
            "janv.",
            "févr.",
            "mars",
            "avr.",
            "mai",
            "juin",
            "juil.",
            "août",
            "sept.",
            "oct.",
            "nov.",
            "déc.",
        });
    } else if (std.mem.eql(u8, base, "ja")) {
        loc.date_short = "y/MM/dd";
        loc.date_medium = "y/MM/dd";
        loc.date_long = "y年M月d日";
        setMonths(loc, &.{
            "1月",
            "2月",
            "3月",
            "4月",
            "5月",
            "6月",
            "7月",
            "8月",
            "9月",
            "10月",
            "11月",
            "12月",
        }, &.{
            "1月",
            "2月",
            "3月",
            "4月",
            "5月",
            "6月",
            "7月",
            "8月",
            "9月",
            "10月",
            "11月",
            "12月",
        });
    } else if (std.mem.eql(u8, base, "ar")) {
        loc.direction = .rtl;
        loc.date_short = "d/M/y";
        loc.date_medium = "d MMM y";
        loc.date_long = "d MMMM y";
        setMonths(loc, &.{
            "يناير",
            "فبراير",
            "مارس",
            "أبريل",
            "مايو",
            "يونيو",
            "يوليو",
            "أغسطس",
            "سبتمبر",
            "أكتوبر",
            "نوفمبر",
            "ديسمبر",
        }, &.{
            "يناير",
            "فبراير",
            "مارس",
            "أبريل",
            "مايو",
            "يونيو",
            "يوليو",
            "أغسطس",
            "سبتمبر",
            "أكتوبر",
            "نوفمبر",
            "ديسمبر",
        });
    }
    // en: defaults
}

fn setMonths(loc: *Locale, long: *const [12][]const u8, short: *const [12][]const u8) void {
    if (loc.months_owned) {
        for (loc.month_long) |m| loc.allocator.free(m);
        for (loc.month_short) |m| loc.allocator.free(m);
    }
    inline for (0..12) |i| {
        loc.month_long[i] = loc.allocator.dupe(u8, long[i]) catch @panic("klaxon: out of memory");
        loc.month_short[i] = loc.allocator.dupe(u8, short[i]) catch @panic("klaxon: out of memory");
    }
    loc.months_owned = true;
}

// --- Plural (ARB `{count, plural, ...}` + CLDR categories) ---

pub const PluralCategory = enum { zero, one, two, few, many, other };

/// CLDR plural category for a locale tag and count (en/fr/ja/ar built in;
/// the default rule is one/other like English).
pub fn pluralCategory(tag: []const u8, n: i64) PluralCategory {
    const base = if (std.mem.indexOfScalar(u8, tag, '-')) |i| tag[0..i] else tag;
    if (std.mem.eql(u8, base, "fr")) {
        // fr: one covers 0 and 1
        return if (n >= 0 and n < 2) .one else .other;
    }
    if (std.mem.eql(u8, base, "ja")) return .other;
    if (std.mem.eql(u8, base, "ar")) {
        if (n == 0) return .zero;
        if (n == 1) return .one;
        if (n == 2) return .two;
        if (n > 0) {
            const m100 = @mod(n, 100);
            if (m100 >= 3 and m100 <= 10) return .few;
            if (m100 >= 11 and m100 <= 99) return .many;
        }
        return .other;
    }
    // en + default: one is exactly 1
    return if (n == 1) .one else .other;
}

pub const PluralBranch = struct {
    exact: ?i64 = null, // `=N` selector
    category: ?PluralCategory = null, // keyword selector
    text: []const u8 = "",
};

pub const PluralMsg = struct {
    branches: [16]PluralBranch = undefined, // up to 10 exact selectors + 6 categories
    len: u32 = 0,
    prefix: []const u8 = "", // text before the block's opening '{'
    suffix: []const u8 = "", // text after the block's closing '}'
};

/// Parse an ARB plural block: `{count, plural, =0 {...} one {...} other {...}}`.
/// Returns null when the message is not a plural block.
pub fn parsePlural(msg: []const u8) ?PluralMsg {
    const p = std.mem.indexOf(u8, msg, ", plural,") orelse return null;
    // The block opens at the '{' before the count name.
    const open = std.mem.lastIndexOfScalar(u8, msg[0..p], '{') orelse return null;
    var out = PluralMsg{};
    out.prefix = msg[0..open];
    var i = p + ", plural,".len;
    while (i < msg.len) {
        // skip whitespace
        while (i < msg.len and msg[i] == ' ') i += 1;
        if (i >= msg.len) return null;
        if (msg[i] == '}') {
            out.suffix = msg[i + 1 ..];
            return if (out.len > 0) out else null; // end of block
        }
        var branch = PluralBranch{};
        if (msg[i] == '=') {
            // exact selector: =N
            i += 1;
            var num: i64 = 0;
            var neg = false;
            if (i < msg.len and msg[i] == '-') {
                neg = true;
                i += 1;
            }
            while (i < msg.len and msg[i] >= '0' and msg[i] <= '9') : (i += 1) {
                num = num * 10 + (msg[i] - '0');
            }
            branch.exact = if (neg) -num else num;
        } else {
            // keyword selector
            const start = i;
            while (i < msg.len and msg[i] != ' ' and msg[i] != '{') i += 1;
            const kw = msg[start..i];
            branch.category = std.meta.stringToEnum(PluralCategory, kw);
        }
        while (i < msg.len and msg[i] == ' ') i += 1;
        if (i >= msg.len or msg[i] != '{') return null;
        // branch text: until the matching '}' (placeholders nest)
        i += 1;
        const text_start = i;
        var depth: u32 = 1;
        while (i < msg.len and depth > 0) : (i += 1) {
            if (msg[i] == '{') depth += 1;
            if (msg[i] == '}') depth -= 1;
        }
        if (depth != 0) return null;
        branch.text = msg[text_start .. i - 1];
        if (out.len >= out.branches.len) return null; // too many branches — reject
        out.branches[out.len] = branch;
        out.len += 1;
    }
    return if (out.len > 0) out else null;
}

/// Select the branch for a count: exact `=N` first, then the CLDR category,
/// then `other`.
pub fn selectPlural(msg: PluralMsg, tag: []const u8, count: i64) ?[]const u8 {
    for (msg.branches[0..msg.len]) |b| {
        if (b.exact) |e| {
            if (e == count) return b.text;
        }
    }
    const cat = pluralCategory(tag, count);
    for (msg.branches[0..msg.len]) |b| {
        if (b.category) |c| {
            if (c == cat) return b.text;
        }
    }
    for (msg.branches[0..msg.len]) |b| {
        if (b.category == .other) return b.text;
    }
    return null;
}

// --- Interpolation ---

fn appendFormatted(buf: *std.array_list.Managed(u8), val: anytype) !void {
    switch (@typeInfo(@TypeOf(val))) {
        .int, .comptime_int => {
            const s = try std.fmt.allocPrint(buf.allocator, "{d}", .{val});
            defer buf.allocator.free(s);
            try buf.appendSlice(s);
        },
        .float, .comptime_float => {
            const s = try std.fmt.allocPrint(buf.allocator, "{d}", .{val});
            defer buf.allocator.free(s);
            try buf.appendSlice(s);
        },
        .bool => try buf.appendSlice(if (val) "true" else "false"),
        .optional => {
            if (val) |v| {
                try appendFormatted(buf, v);
            } else try buf.appendSlice("null");
        },
        .pointer => |p| {
            const child_info = @typeInfo(p.child);
            if (child_info == .array and child_info.array.child == u8) {
                // string literal: *const [N:0]u8
                try buf.appendSlice(val[0..]);
            } else if (p.child == u8) {
                if (p.size == .slice) {
                    try buf.appendSlice(val);
                } else {
                    try buf.appendSlice(std.mem.span(val));
                }
            } else {
                @compileError("l10n arg: unsupported pointer type (use []const u8)");
            }
        },
        else => @compileError("l10n arg: unsupported type"),
    }
}

/// Append the args field named `name` (formatted). Returns false when the
/// struct has no such field. The field's type is known at comptime inside
/// the inline loop, so any supported arg type works.
fn appendField(buf: *std.array_list.Managed(u8), args: anytype, name: []const u8) !bool {
    if (@TypeOf(args) == void) return false;
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |fname| {
        if (std.mem.eql(u8, fname, name)) {
            try appendFormatted(buf, @field(args, fname));
            return true;
        }
    }
    return false;
}

/// Interpolate `{name}` placeholders from a comptime args struct. Unknown
/// placeholders are left as-is.
pub fn interpolate(allocator: std.mem.Allocator, msg: []const u8, args: anytype) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    var i: usize = 0;
    while (i < msg.len) {
        if (msg[i] == '{') {
            if (std.mem.indexOfScalar(u8, msg[i..], '}')) |close| {
                const name = msg[i + 1 .. i + close];
                if (try appendField(&buf, args, name)) {
                    i += close + 1;
                    continue;
                }
            }
        }
        try buf.append(msg[i]);
        i += 1;
    }
    return buf.toOwnedSlice();
}

/// Interpolate a plural branch: `#` and `{count}` expand to the count, other
/// `{name}` placeholders come from the args struct.
fn interpolatePlural(allocator: std.mem.Allocator, branch: []const u8, count: i64, args: anytype) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    var count_buf: [24]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{count});
    var i: usize = 0;
    while (i < branch.len) {
        if (branch[i] == '#') {
            try buf.appendSlice(count_str);
            i += 1;
            continue;
        }
        if (branch[i] == '{') {
            if (std.mem.indexOfScalar(u8, branch[i..], '}')) |close| {
                const name = branch[i + 1 .. i + close];
                if (std.mem.eql(u8, name, "count")) {
                    try buf.appendSlice(count_str);
                    i += close + 1;
                    continue;
                }
                if (try appendField(&buf, args, name)) {
                    i += close + 1;
                    continue;
                }
            }
        }
        try buf.append(branch[i]);
        i += 1;
    }
    return buf.toOwnedSlice();
}

// --- I18n (registry + current locale) ---

pub const I18n = struct {
    allocator: std.mem.Allocator,
    locales: std.StringHashMap(*Locale), // tag → locale (tags owned)
    fallback: []const u8, // owned tag
    current: ?*Locale = null,
    /// Locale-switch signal: localized widgets subscribe and re-render.
    locale_sig: *state_mod.Signal([]const u8),
    /// Fired when a locale switch flips the text direction (the app marks
    /// the root layout-dirty: RTL re-mirrors the layout).
    on_direction_changed: ?state_mod.Callback = null,

    pub fn init(allocator: std.mem.Allocator, fallback_tag: []const u8) !*I18n {
        const self = try allocator.create(I18n);
        self.* = .{
            .allocator = allocator,
            .locales = std.StringHashMap(*Locale).init(allocator),
            .fallback = try allocator.dupe(u8, fallback_tag),
            .locale_sig = try state_mod.Signal([]const u8).init(allocator, ""),
        };
        return self;
    }

    pub fn deinit(i18n: *I18n) void {
        var it = i18n.locales.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit();
        i18n.locales.deinit();
        i18n.allocator.free(i18n.fallback);
        i18n.locale_sig.deinit();
        i18n.allocator.destroy(i18n);
    }

    /// Register a locale (the I18n takes ownership). Re-registering a tag
    /// replaces the locale (hot reload of translations): localized widgets
    /// are invalidated even though the tag is unchanged, and a direction
    /// flip fires `on_direction_changed`.
    pub fn addLocale(i18n: *I18n, loc: *Locale) !void {
        var replaced_current: ?Direction = null;
        if (i18n.locales.get(loc.tag)) |old| {
            // Drop the old entry first: the map key aliases old.tag (owned).
            _ = i18n.locales.remove(loc.tag);
            if (i18n.current == old) {
                replaced_current = old.direction;
                i18n.current = loc;
            }
            old.deinit();
        }
        try i18n.locales.put(loc.tag, loc);
        applyFormatData(loc);
        if (i18n.current == null) i18n.current = loc;
        if (replaced_current) |old_dir| {
            // Hot reload of the active locale: force-notify (Signal.set
            // would suppress an unchanged tag) and fire the direction
            // callback when the direction flipped.
            i18n.locale_sig.notify();
            if (loc.direction != old_dir) {
                if (i18n.on_direction_changed) |cb| cb.fn_ptr(cb.userdata);
            }
        } else if (std.mem.eql(u8, loc.tag, i18n.fallback)) {
            // Replacing the fallback catalog: displayed fallback
            // translations may have changed — invalidate the widgets.
            i18n.locale_sig.notify();
        }
    }

    /// Load a locale from an ARB document (JSON). The direction is explicit
    /// (ARB has no direction field; `applyFormatData` also sets it for ar).
    pub fn addArb(i18n: *I18n, tag: []const u8, arb_json: []const u8, dir: Direction) !void {
        const loc = try Locale.init(i18n.allocator, tag);
        errdefer loc.deinit();
        try loc.parseArb(arb_json);
        loc.direction = dir;
        try i18n.addLocale(loc);
    }

    // Runtime file loading: read the ARB file with your platform's file API
    // (Zig 0.17 moved the fs API to std.Io) and pass the contents to addArb.
    // Locales may also be embedded at compile time (@embedFile) — see the
    // i18n demo (src/locales/*.arb).

    /// Switch the current locale at runtime (no restart). Localized widgets
    /// re-render via the locale signal; a direction flip fires
    /// `on_direction_changed`.
    pub fn setLocale(i18n: *I18n, tag: []const u8) !void {
        const loc = i18n.locales.get(tag) orelse return error.UnknownLocale;
        const old_dir = i18n.direction();
        i18n.current = loc;
        i18n.locale_sig.set(loc.tag); // notifies → widgets re-render
        if (i18n.direction() != old_dir) {
            if (i18n.on_direction_changed) |cb| cb.fn_ptr(cb.userdata);
        }
    }

    pub fn locale(i18n: *const I18n) ?*Locale {
        return i18n.current;
    }

    pub fn direction(i18n: *const I18n) Direction {
        if (i18n.current) |loc| return loc.direction;
        return .ltr;
    }

    /// Resolve a message: current locale → fallback locale → the key.
    /// Borrowed slice (no allocation).
    pub fn tr(i18n: *const I18n, key: []const u8) []const u8 {
        if (i18n.current) |cur| {
            if (cur.messages.get(key)) |msg| return msg;
        }
        if (i18n.locales.get(i18n.fallback)) |fb| {
            if (fb.messages.get(key)) |msg| return msg;
        }
        return key;
    }

    /// Resolve + interpolate (`{name}` placeholders from the args struct).
    pub fn trArgs(i18n: *const I18n, allocator: std.mem.Allocator, key: []const u8, args: anytype) ![]u8 {
        return interpolate(allocator, i18n.tr(key), args);
    }

    /// Resolve a message and the tag of the locale that provided it (plural
    /// rules must follow the message's locale, not the active one).
    fn trTagged(i18n: *const I18n, key: []const u8) struct { msg: []const u8, tag: []const u8 } {
        if (i18n.current) |cur| {
            if (cur.messages.get(key)) |msg| return .{ .msg = msg, .tag = cur.tag };
        }
        if (i18n.locales.get(i18n.fallback)) |fb| {
            if (fb.messages.get(key)) |msg| return .{ .msg = msg, .tag = fb.tag };
        }
        return .{ .msg = key, .tag = if (i18n.current) |c| c.tag else "" };
    }

    /// Resolve a plural message for a count (ARB plural block + CLDR rules).
    /// The block may be embedded in a longer message — the surrounding text
    /// is interpolated around the selected branch.
    pub fn trPlural(i18n: *const I18n, allocator: std.mem.Allocator, key: []const u8, count: i64, args: anytype) ![]u8 {
        const t = i18n.trTagged(key);
        const msg = t.msg;
        if (parsePlural(msg)) |pm| {
            const branch = selectPlural(pm, t.tag, count) orelse return try allocator.dupe(u8, msg);
            if (pm.prefix.len == 0 and pm.suffix.len == 0) {
                return interpolatePlural(allocator, branch, count, args);
            }
            const pre = try interpolate(allocator, pm.prefix, args);
            defer allocator.free(pre);
            const mid = try interpolatePlural(allocator, branch, count, args);
            defer allocator.free(mid);
            const post = try interpolate(allocator, pm.suffix, args);
            defer allocator.free(post);
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();
            try buf.appendSlice(pre);
            try buf.appendSlice(mid);
            try buf.appendSlice(post);
            return buf.toOwnedSlice();
        }
        return interpolate(allocator, msg, args);
    }
};

// --- process-global current i18n (single-window P0, like the router) ---

threadlocal var current_i18n: ?*I18n = null;

pub fn setCurrent(i: ?*I18n) void {
    current_i18n = i;
}

pub fn current() ?*I18n {
    return current_i18n;
}

/// The current text direction (ltr when no i18n is installed).
pub fn direction() Direction {
    if (current_i18n) |i| return i.direction();
    return .ltr;
}

// --- tests ---

const en_arb =
    \\{"@@locale": "en", "greeting": "Hello {name}!", "items": "{count, plural, =0 {No items} one {# item} other {# items}}",
    \\ "plain": "Plain", "@greeting": {"description": "metadata"}, "num": "Number", "solo": "{count, plural, one {# item} other {# items}}"}
;
const fr_arb =
    \\{"@@locale": "fr", "greeting": "Bonjour {name} !", "items": "{count, plural, =0 {Aucun élément} one {# élément} other {# éléments}}",
    \\ "plain": "Simple", "missing_in_fr": "absent"}
;

fn testI18n() !*I18n {
    const i18n = try I18n.init(std.testing.allocator, "en");
    errdefer i18n.deinit();
    try i18n.addArb("en", en_arb, .ltr);
    try i18n.addArb("fr", fr_arb, .ltr);
    try i18n.setLocale("en");
    return i18n;
}

test "arb: messages parsed, @-metadata skipped" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try std.testing.expectEqualStrings("Hello {name}!", i18n.tr("greeting"));
    try std.testing.expectEqualStrings("Plain", i18n.tr("plain"));
    try std.testing.expect(i18n.locale().?.messages.get("@greeting") == null);
    try std.testing.expect(i18n.locale().?.messages.get("@@locale") == null);
}

test "tr: current locale, fallback locale, then the key" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.setLocale("fr");
    try std.testing.expectEqualStrings("Bonjour {name} !", i18n.tr("greeting"));
    // missing in fr → fallback en
    try std.testing.expectEqualStrings("Number", i18n.tr("num"));
    // missing everywhere → the key
    try std.testing.expectEqualStrings("nope", i18n.tr("nope"));
}

test "interpolate: placeholders from the args struct, unknown left as-is" {
    const i18n = try testI18n();
    defer i18n.deinit();
    const s = try i18n.trArgs(std.testing.allocator, "greeting", .{ .name = "Léa" });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("Hello Léa!", s);
    // unknown placeholder stays; multiple args
    const msg = "{a} and {b} and {c}";
    const s2 = try interpolate(std.testing.allocator, msg, .{ .a = 1, .b = "two" });
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("1 and two and {c}", s2);
    // types: int, float, bool
    const s3 = try interpolate(std.testing.allocator, "{i} {f} {b}", .{ .i = 42, .f = @as(f64, 1.5), .b = true });
    defer std.testing.allocator.free(s3);
    try std.testing.expectEqualStrings("42 1.5 true", s3);
}

test "plural: CLDR categories per locale (en/fr/ja/ar)" {
    try std.testing.expectEqual(PluralCategory.one, pluralCategory("en", 1));
    try std.testing.expectEqual(PluralCategory.other, pluralCategory("en", 0));
    try std.testing.expectEqual(PluralCategory.other, pluralCategory("en", 5));
    try std.testing.expectEqual(PluralCategory.one, pluralCategory("fr", 0)); // fr: one covers 0
    try std.testing.expectEqual(PluralCategory.one, pluralCategory("fr", 1));
    try std.testing.expectEqual(PluralCategory.other, pluralCategory("fr", 2));
    try std.testing.expectEqual(PluralCategory.other, pluralCategory("ja", 1));
    try std.testing.expectEqual(PluralCategory.zero, pluralCategory("ar", 0));
    try std.testing.expectEqual(PluralCategory.one, pluralCategory("ar", 1));
    try std.testing.expectEqual(PluralCategory.two, pluralCategory("ar", 2));
    try std.testing.expectEqual(PluralCategory.few, pluralCategory("ar", 3));
    try std.testing.expectEqual(PluralCategory.few, pluralCategory("ar", 10));
    try std.testing.expectEqual(PluralCategory.many, pluralCategory("ar", 11));
    try std.testing.expectEqual(PluralCategory.many, pluralCategory("ar", 99));
    try std.testing.expectEqual(PluralCategory.other, pluralCategory("ar", 100));
    // tag with region
    try std.testing.expectEqual(PluralCategory.one, pluralCategory("fr-FR", 1));
}

fn expectPlural(i18n: *I18n, key: []const u8, count: i64, args: anytype, expected: []const u8) !void {
    const s = try i18n.trPlural(std.testing.allocator, key, count, args);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "plural: parse + select (exact, category, other fallback) + # expansion" {
    const pm = parsePlural("{count, plural, =0 {No items} one {# item} other {# items}}").?;
    try std.testing.expectEqual(@as(u32, 3), pm.len);
    try std.testing.expectEqual(@as(?i64, 0), pm.branches[0].exact);
    try std.testing.expectEqual(PluralCategory.one, pm.branches[1].category.?);
    const i18n = try testI18n();
    defer i18n.deinit();
    // en: =0 exact, one for 1, other otherwise
    try expectPlural(i18n, "items", 0, .{}, "No items");
    try expectPlural(i18n, "items", 1, .{}, "1 item");
    try expectPlural(i18n, "items", 7, .{}, "7 items");
    // fr: =0 exact, one for 1, other otherwise
    try i18n.setLocale("fr");
    try expectPlural(i18n, "items", 0, .{}, "Aucun élément");
    try expectPlural(i18n, "items", 1, .{}, "1 élément");
    try expectPlural(i18n, "items", 7, .{}, "7 éléments");
    // not a plural block: plain interpolation
    try expectPlural(i18n, "greeting", 3, .{ .name = "Léa" }, "Bonjour Léa !");
    // parsePlural returns null for plain messages
    try std.testing.expect(parsePlural("plain") == null);
}

test "plural: branch placeholders interpolate alongside #" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.addArb("en", "{\"cart\": \"{count, plural, one {# item in {who}'s cart} other {# items in {who}'s cart}}\"}", .ltr);
    const s = try i18n.trPlural(std.testing.allocator, "cart", 3, .{ .who = "Léa" });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("3 items in Léa's cart", s);
}

test "plural: 9+ branches parse (exact selectors + categories) + prefix/suffix captured" {
    const pm = parsePlural("{count, plural, =0 {none} =1 {one} =2 {two} zero {z} one {o} two {t} few {f} many {m} other {other}}").?;
    try std.testing.expectEqual(@as(u32, 9), pm.len);
    try std.testing.expectEqualStrings("none", selectPlural(pm, "ar", 0).?);
    try std.testing.expectEqualStrings("other", selectPlural(pm, "ar", 100).?);
    try std.testing.expectEqualStrings("", pm.prefix);
    try std.testing.expectEqualStrings("", pm.suffix);
    // Embedded block: the surrounding text is captured.
    const emb = parsePlural("You have {count, plural, one {# item} other {# items}} left").?;
    try std.testing.expectEqualStrings("You have ", emb.prefix);
    try std.testing.expectEqualStrings(" left", emb.suffix);
}

test "trPlural: embedded plural keeps the surrounding text" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.addArb("en", "{\"left\": \"You have {count, plural, one {# item} other {# items}} left\"}", .ltr);
    try expectPlural(i18n, "left", 1, .{}, "You have 1 item left");
    try expectPlural(i18n, "left", 2, .{}, "You have 2 items left");
}

test "trPlural: fallback message uses the fallback locale's plural rules" {
    const i18n = try testI18n();
    defer i18n.deinit();
    // "solo" exists only in the fallback (en): en rules apply (one = 1,
    // zero → other), not the active fr rules (one covers 0).
    try i18n.setLocale("fr");
    try expectPlural(i18n, "solo", 0, .{}, "0 items");
    try expectPlural(i18n, "solo", 1, .{}, "1 item");
    try expectPlural(i18n, "solo", 5, .{}, "5 items");
}

test "formatNumber: arbitrary precision (decimals > 32)" {
    const i18n = try testI18n();
    defer i18n.deinit();
    const en = i18n.locales.get("en").?;
    const s = try en.formatNumber(std.testing.allocator, 1.5, .{ .decimals = 33 });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1.", s[0..2]);
    try std.testing.expectEqual(@as(usize, 35), s.len); // "1." + 33 digits
    try std.testing.expectEqual(@as(u8, '5'), s[2]);
    for (s[3..]) |c| try std.testing.expectEqual(@as(u8, '0'), c);
}

test "formatDate: 2-digit year is zero-padded for years < 10" {
    const i18n = try testI18n();
    defer i18n.deinit();
    const en = i18n.locales.get("en").?;
    try expectDate(en, .{ .year = 1, .month = 1, .day = 1 }, .short, "1/1/01");
    try expectDate(en, .{ .year = 9, .month = 12, .day = 31 }, .short, "12/31/09");
}

test "addLocale: replacing the active locale notifies widgets + direction callback" {
    const i18n = try testI18n();
    defer i18n.deinit();
    var fired: u32 = 0;
    var dir_flipped: u32 = 0;
    i18n.locale_sig.subscribe(.{ .callback = .{ .fn_ptr = countFired, .userdata = &fired } });
    i18n.on_direction_changed = .{ .fn_ptr = countFired, .userdata = &dir_flipped };
    // Hot reload of the active locale: same tag, new text — force-notify.
    try i18n.addArb("en", "{\"title\": \"Hi\"}", .ltr);
    try std.testing.expectEqual(@as(u32, 1), fired);
    try std.testing.expectEqualStrings("Hi", i18n.tr("title"));
    try std.testing.expectEqual(@as(u32, 0), dir_flipped); // ltr → ltr
    // Same tag with a direction flip — the direction callback fires.
    try i18n.addArb("en", "{\"title\": \"Hi\"}", .rtl);
    try std.testing.expectEqual(@as(u32, 2), fired);
    try std.testing.expectEqual(@as(u32, 1), dir_flipped);
    // Replacing the fallback catalog (current is another locale) notifies too.
    try i18n.setLocale("fr"); // fired = 3
    try i18n.addArb("en", "{\"title\": \"Hi\"}", .ltr); // fallback replaced → fired = 4
    try std.testing.expectEqual(@as(u32, 4), fired);
}

test "formatNumber: grouping, separators, decimals, percent" {
    const i18n = try testI18n();
    defer i18n.deinit();
    const en = i18n.locales.get("en").?;
    const fr = i18n.locales.get("fr").?;
    {
        const s = try en.formatNumber(std.testing.allocator, 1234567.891, .{});
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("1,234,567.891", s);
    }
    {
        const s = try fr.formatNumber(std.testing.allocator, 1234567.891, .{});
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("1 234 567,891", s);
    }
    {
        // fixed decimals + percent
        const s = try en.formatNumber(std.testing.allocator, 0.42, .{ .decimals = 1, .percent = true });
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("42.0%", s);
    }
    {
        // negative, no grouping
        const s = try en.formatNumber(std.testing.allocator, -42, .{ .grouping = false });
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("-42", s);
    }
}

fn expectDate(loc: *Locale, date: Date, kind: DateKind, expected: []const u8) !void {
    const s = try loc.formatDate(std.testing.allocator, date, kind);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "formatDate: patterns per locale and kind" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.addArb("ja", "{\"x\": \"y\"}", .ltr);
    try i18n.addArb("ar", "{\"x\": \"y\"}", .rtl);
    const date = Date{ .year = 2026, .month = 10, .day = 7 };
    const en = i18n.locales.get("en").?;
    const fr = i18n.locales.get("fr").?;
    const ja = i18n.locales.get("ja").?;
    const ar = i18n.locales.get("ar").?;
    try expectDate(en, date, .short, "10/7/26");
    try expectDate(fr, date, .short, "07/10/2026");
    try expectDate(ja, date, .short, "2026/10/07");
    try expectDate(ar, date, .short, "7/10/2026");
    // medium/long with month names
    try expectDate(en, date, .long, "October 7, 2026");
    try expectDate(fr, date, .medium, "7 oct. 2026");
    try expectDate(ja, date, .long, "2026年10月7日");
}

test "direction: locale direction + process-global + setLocale flips it" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\": \"y\"}", .rtl);
    setCurrent(i18n);
    defer setCurrent(null);
    try std.testing.expectEqual(Direction.ltr, direction());
    try std.testing.expectEqual(Direction.ltr, i18n.direction());
    try i18n.setLocale("ar");
    try std.testing.expectEqual(Direction.rtl, direction());
    try std.testing.expectEqual(Direction.rtl, i18n.direction());
    // unknown locale
    try std.testing.expectError(error.UnknownLocale, i18n.setLocale("de"));
}

test "setLocale: the locale signal fires (widgets subscribe) + direction callback" {
    const i18n = try testI18n();
    defer i18n.deinit();
    try i18n.addArb("ar", "{\"x\": \"y\"}", .rtl);
    var fired: u32 = 0;
    var dir_flipped: u32 = 0;
    i18n.locale_sig.subscribe(.{ .callback = .{ .fn_ptr = countFired, .userdata = &fired } });
    i18n.on_direction_changed = .{ .fn_ptr = countFired, .userdata = &dir_flipped };
    try i18n.setLocale("fr");
    try std.testing.expectEqual(@as(u32, 1), fired);
    try std.testing.expectEqual(@as(u32, 0), dir_flipped); // ltr → ltr
    try i18n.setLocale("ar");
    try std.testing.expectEqual(@as(u32, 2), fired);
    try std.testing.expectEqual(@as(u32, 1), dir_flipped); // ltr → rtl
    try i18n.setLocale("en");
    try std.testing.expectEqual(@as(u32, 3), fired);
    try std.testing.expectEqual(@as(u32, 2), dir_flipped); // rtl → ltr
}

fn countFired(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "no i18n installed: direction defaults to ltr" {
    setCurrent(null);
    try std.testing.expectEqual(Direction.ltr, direction());
}
