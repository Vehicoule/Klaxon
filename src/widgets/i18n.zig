// Localized widgets (Phase 2b) — text that follows the current locale.
//
//   - l10nText(key)           — resolves tr(key), re-renders on locale switch
//   - L10nText(Args).text     — with `{name}` placeholders from the args struct
//   - l10nPlural(key, n)      — ARB plural block for a fixed count
//   - l10nPluralSig(key, sig) — plural bound to a count signal (both the count
//                               and the locale re-resolve the text)
//
// The widgets subscribe to the I18n locale signal: setLocale re-resolves the
// text (and re-measures — the width may change → markLayoutDirty). The args
// struct is stored by value; its string slices are borrowed (they must
// outlive the widget — build args from literals or app-lifetime data).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const i18n_mod = @import("../ui/i18n.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const TextAlign = ui.layout.TextAlign;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

pub const L10nTextOptions = struct {
    size: f32 = 16,
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    bold: bool = false,
    text_align: TextAlign = .start, // directional by default (RTL-aware) — named text_align, `align` is a Zig keyword
};

/// Fields shared by every localized-text state (the vtable reads these).
const L10nBase = struct {
    i18n: *i18n_mod.I18n,
    node: *Node,
    key: []const u8, // owned
    text: [:0]const u8, // owned (resolved message)
    text_resolved: bool = false, // false until the first effect run
    opts: L10nTextOptions,
    effect: *ui.state.Effect, // locale subscription
};

fn L10nState(comptime Args: type) type {
    return struct {
        base: L10nBase,
        args: Args,
    };
}

fn baseOf(n: *Node) *L10nBase {
    // `base` is the first field of every localized-text state: the state's
    // address is the base's address.
    return @ptrCast(@alignCast(n.state.?));
}

fn dupeZ(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn resolveText(comptime Args: type, allocator: std.mem.Allocator, key: []const u8, i18n: *i18n_mod.I18n, args: Args) ![:0]const u8 {
    if (Args == void) {
        return dupeZ(allocator, i18n.tr(key));
    }
    const s = try i18n.trArgs(allocator, key, args);
    defer allocator.free(s);
    return dupeZ(allocator, s);
}

/// Swap the resolved string: repaint + re-layout (the text width may change).
fn resolveBase(allocator: std.mem.Allocator, base: *L10nBase, new_text: [:0]const u8) void {
    if (base.text_resolved) allocator.free(base.text);
    base.text = new_text;
    base.text_resolved = true;
    base.node.markDirty();
    base.node.markLayoutDirty();
}

fn resolvePlural(allocator: std.mem.Allocator, i18n: *i18n_mod.I18n, key: []const u8, count: i64) ![:0]const u8 {
    const r = try i18n.trPlural(allocator, key, count, .{});
    defer allocator.free(r);
    return dupeZ(allocator, r);
}

// --- vtable (shared by every localized-text state) ---

fn l10nMeasure(n: *Node, c: Constraints) Size {
    const s = baseOf(n);
    const m = ui.paint.measureText(s.text, s.opts.size, s.opts.bold);
    return c.constrain(.{ .w = m.width, .h = m.height });
}
fn l10nLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: bounds come from the parent
}
fn l10nPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = baseOf(n);
    const m = ui.paint.measureText(s.text, s.opts.size, s.opts.bold);
    const resolved = ui.layout.resolveAlign(s.opts.text_align, ui.i18n.direction());
    const x = switch (resolved) {
        .left => n.bounds.x,
        .center => n.bounds.x + (n.bounds.w - m.width) / 2,
        .right => n.bounds.x + n.bounds.w - m.width,
        .start, .end => unreachable, // resolved above
    };
    ui.paint.text(ctx, s.text, x, n.bounds.y + m.ascent, s.opts.size, s.opts.bold, s.opts.color);
}
/// Free the shared base fields (the state itself is destroyed by the
/// factory-specific deinit — destroy(*anyopaque) has no size in Zig 0.17).
fn l10nDeinitBase(base: *L10nBase) void {
    base.effect.deinit();
    base.node.allocator.free(base.key);
    if (base.text_resolved) base.node.allocator.free(base.text);
}

/// Localized text with placeholders: `L10nText(.{ .name = []const u8 }).text(...)`.
/// The args struct is comptime — interpolation is allocation-free per lookup.
pub fn L10nText(comptime Args: type) type {
    return struct {
        const State = L10nState(Args);

        fn resolveCb(userdata: ?*anyopaque) void {
            const s: *State = @ptrCast(@alignCast(userdata.?));
            _ = s.base.i18n.locale_sig.get(); // track: re-run on locale switch
            const new_text = resolveText(Args, s.base.i18n.allocator, s.base.key, s.base.i18n, s.args) catch @panic("klaxon: out of memory");
            resolveBase(s.base.i18n.allocator, &s.base, new_text);
        }

        fn deinit(n: *Node) void {
            const s: *State = @ptrCast(@alignCast(n.state.?));
            l10nDeinitBase(&s.base);
            n.allocator.destroy(s);
        }
        const vtable = ui.node.VTable{ .measure = l10nMeasure, .layout = l10nLayout, .paint = l10nPaint, .deinit = deinit };

        pub fn text(allocator: std.mem.Allocator, i18n: *i18n_mod.I18n, key: []const u8, args: Args, opts: L10nTextOptions) !*Node {
            const node = try Node.create(allocator, &vtable);
            errdefer node.allocator.destroy(node);
            const s = try allocator.create(State);
            errdefer allocator.destroy(s);
            s.* = .{
                .base = .{
                    .i18n = i18n,
                    .node = node,
                    .key = try allocator.dupe(u8, key),
                    .text = undefined,
                    .opts = opts,
                    .effect = undefined,
                },
                .args = args,
            };
            s.base.effect = try ui.state.Effect.init(allocator, resolveCb, s);
            node.state = s;
            s.base.effect.run(); // first run: resolves the text + subscribes to the locale signal
            return node;
        }
    };
}

/// Localized text (no placeholders).
pub fn l10nText(allocator: std.mem.Allocator, i18n: *i18n_mod.I18n, key: []const u8, opts: L10nTextOptions) !*Node {
    return L10nText(void).text(allocator, i18n, key, {}, opts);
}

// --- l10nPlural (fixed count) ---

const PluralState = struct {
    base: L10nBase, // first field: the vtable reads it via baseOf
    count: i64,
};

fn pluralResolveCb(userdata: ?*anyopaque) void {
    const s: *PluralState = @ptrCast(@alignCast(userdata.?));
    _ = s.base.i18n.locale_sig.get(); // track: re-run on locale switch
    const new_text = resolvePlural(s.base.i18n.allocator, s.base.i18n, s.base.key, s.count) catch @panic("klaxon: out of memory");
    resolveBase(s.base.i18n.allocator, &s.base, new_text);
}

fn pluralDeinit(n: *Node) void {
    const s: *PluralState = @ptrCast(@alignCast(n.state.?));
    l10nDeinitBase(&s.base);
    n.allocator.destroy(s);
}
const plural_vtable = ui.node.VTable{ .measure = l10nMeasure, .layout = l10nLayout, .paint = l10nPaint, .deinit = pluralDeinit };

/// Localized plural text (fixed count).
pub fn l10nPlural(allocator: std.mem.Allocator, i18n: *i18n_mod.I18n, key: []const u8, count: i64, opts: L10nTextOptions) !*Node {
    const node = try Node.create(allocator, &plural_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(PluralState);
    errdefer allocator.destroy(s);
    s.* = .{
        .base = .{
            .i18n = i18n,
            .node = node,
            .key = try allocator.dupe(u8, key),
            .text = undefined,
            .opts = opts,
            .effect = undefined,
        },
        .count = count,
    };
    s.base.effect = try ui.state.Effect.init(allocator, pluralResolveCb, s);
    node.state = s;
    s.base.effect.run(); // first run: resolves the text + subscribes to the locale signal
    return node;
}

// --- l10nPluralSig (count signal) ---

const PluralSigState = struct {
    base: L10nBase, // first field
    count_sig: *ui.state.Signal(i64),
};

fn pluralSigResolveCb(userdata: ?*anyopaque) void {
    const s: *PluralSigState = @ptrCast(@alignCast(userdata.?));
    _ = s.base.i18n.locale_sig.get(); // track: re-run on locale switch
    const new_text = resolvePlural(s.base.i18n.allocator, s.base.i18n, s.base.key, s.count_sig.peek()) catch @panic("klaxon: out of memory");
    resolveBase(s.base.i18n.allocator, &s.base, new_text);
}

fn pluralSigDeinit(n: *Node) void {
    const s: *PluralSigState = @ptrCast(@alignCast(n.state.?));
    s.count_sig.unsubscribe(.{ .callback = .{ .fn_ptr = pluralSigResolveCb, .userdata = s } });
    s.base.effect.deinit();
    n.allocator.free(s.base.key);
    n.allocator.free(s.base.text);
    n.allocator.destroy(s);
}
const plural_sig_vtable = ui.node.VTable{ .measure = l10nMeasure, .layout = l10nLayout, .paint = l10nPaint, .deinit = pluralSigDeinit };

/// Localized plural text bound to a count signal: both the count and the
/// locale re-resolve the text.
pub fn l10nPluralSig(allocator: std.mem.Allocator, i18n: *i18n_mod.I18n, key: []const u8, count_sig: *ui.state.Signal(i64), opts: L10nTextOptions) !*Node {
    const node = try Node.create(allocator, &plural_sig_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(PluralSigState);
    errdefer allocator.destroy(s);
    s.* = .{
        .base = .{
            .i18n = i18n,
            .node = node,
            .key = try allocator.dupe(u8, key),
            .text = undefined,
            .opts = opts,
            .effect = undefined,
        },
        .count_sig = count_sig,
    };
    s.base.effect = try ui.state.Effect.init(allocator, pluralSigResolveCb, s);
    count_sig.subscribe(.{ .callback = .{ .fn_ptr = pluralSigResolveCb, .userdata = s } });
    node.state = s;
    s.base.effect.run(); // first run: resolves the text + subscribes to the locale signal
    return node;
}

// --- tests ---

const en_arb =
    \\{"greeting": "Hello {name}!", "title": "Demo", "items": "{count, plural, =0 {No items} one {# item} other {# items}}", "dir": "LTR"}
;
const fr_arb =
    \\{"greeting": "Bonjour {name} !", "title": "Démo", "items": "{count, plural, =0 {Aucun élément} one {# élément} other {# éléments}}", "dir": "LTR"}
;
const ar_arb =
    \\{"greeting": "مرحبا {name}!", "title": "تجريبي", "items": "{count, plural, zero {لا عناصر} one {عنصر واحد} two {عنصران} few {# عناصر} many {# عنصراً} other {# عنصر}}", "dir": "RTL"}
;

fn testI18n() !*i18n_mod.I18n {
    const i18n = try i18n_mod.I18n.init(std.testing.allocator, "en");
    errdefer i18n.deinit();
    try i18n.addArb("en", en_arb, .ltr);
    try i18n.addArb("fr", fr_arb, .ltr);
    try i18n.addArb("ar", ar_arb, .rtl);
    try i18n.setLocale("en");
    i18n_mod.setCurrent(i18n);
    return i18n;
}

test "l10nText resolves the message and re-renders on locale switch" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const node = try l10nText(std.testing.allocator, i18n, "title", .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("Demo", baseOf(node).text);
    try i18n.setLocale("fr");
    try std.testing.expectEqualStrings("Démo", baseOf(node).text); // re-resolved
    try std.testing.expect(node.dirty); // repaint requested
    try std.testing.expect(node.layout_dirty); // re-measure requested
}

test "l10nText with args interpolates the placeholders" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const Args = struct { name: []const u8 };
    const node = try L10nText(Args).text(std.testing.allocator, i18n, "greeting", .{ .name = "Léa" }, .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("Hello Léa!", baseOf(node).text);
    try i18n.setLocale("fr");
    try std.testing.expectEqualStrings("Bonjour Léa !", baseOf(node).text);
}

test "l10nPlural selects the CLDR branch per locale" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const node = try l10nPlural(std.testing.allocator, i18n, "items", 5, .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("5 items", baseOf(node).text);
    try i18n.setLocale("fr");
    try std.testing.expectEqualStrings("5 éléments", baseOf(node).text);
    try i18n.setLocale("ar");
    try std.testing.expectEqualStrings("5 عناصر", baseOf(node).text); // few (3..10)
}

test "l10nPluralSig re-resolves on count change and locale switch" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const count = try ui.state.Signal(i64).init(std.testing.allocator, 1);
    defer count.deinit();
    const node = try l10nPluralSig(std.testing.allocator, i18n, "items", count, .{});
    defer node.deinit();
    try std.testing.expectEqualStrings("1 item", baseOf(node).text);
    count.set(3);
    try std.testing.expectEqualStrings("3 items", baseOf(node).text);
    try i18n.setLocale("ar");
    try std.testing.expectEqualStrings("3 عناصر", baseOf(node).text); // few
    count.set(0);
    try std.testing.expectEqualStrings("لا عناصر", baseOf(node).text); // zero
}

test "golden: localized text renders (presence) across a locale switch" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const bg: Color = 0x000000FF;
    const node = try l10nText(std.testing.allocator, i18n, "title", .{ .color = 0xFFFFFFFF });
    defer node.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 128, 32);
    defer r.deinit();
    node.layout(.{ .x = 0, .y = 0, .w = 128, .h = 32 });
    r.paint(node, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expect(f1.countNot(bg) > 0); // "Demo" painted
    try i18n.setLocale("fr");
    node.layout(.{ .x = 0, .y = 0, .w = 128, .h = 32 });
    r.paint(node, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countNot(bg) > 0); // "Démo" painted
}

test "golden: RTL row paints the logical order right → left (exact pixels)" {
    const i18n = try testI18n();
    defer i18n_mod.setCurrent(null);
    defer i18n.deinit();
    const bg: Color = 0x101010FF;
    const red: Color = 0xFF0000FF;
    const blue: Color = 0x0000FFFF;
    const root = try @import("layout.zig").row(std.testing.allocator, .{ .gap = 8 });
    var r = try golden.Renderer.init(std.testing.allocator, 128, 64);
    defer r.deinit();
    defer root.deinit(); // defer LIFO: the tree dies before the ctx
    root.add(try golden.solidBox(std.testing.allocator, 40, 20, red));
    root.add(try golden.solidBox(std.testing.allocator, 40, 20, blue));
    const bounds = Rect{ .x = 0, .y = 0, .w = 128, .h = 64 };
    // LTR (en): red left, blue right
    try i18n.setLocale("en");
    root.layout(bounds);
    r.paint(root, bg);
    var frame = try r.readback(std.testing.allocator);
    defer frame.deinit();
    try std.testing.expectEqual(red, frame.pixelAt(5, 5));
    try std.testing.expectEqual(blue, frame.pixelAt(53, 5)); // 40 + gap 8 + 5
    try std.testing.expectEqual(bg, frame.pixelAt(44, 5)); // inside the gap
    // RTL (ar): the logical order [red, blue] runs right → left:
    // red at x=88, blue at x=40 (gap 80..88 preserved)
    try i18n.setLocale("ar");
    root.layout(bounds); // re-layout: the direction flip mirrors the row
    r.paint(root, bg);
    var frame2 = try r.readback(std.testing.allocator);
    defer frame2.deinit();
    try std.testing.expectEqual(bg, frame2.pixelAt(5, 5)); // left of blue
    try std.testing.expectEqual(blue, frame2.pixelAt(45, 5)); // blue at x=40
    try std.testing.expectEqual(bg, frame2.pixelAt(84, 5)); // inside the gap
    try std.testing.expectEqual(red, frame2.pixelAt(93, 5)); // red at x=88
}
