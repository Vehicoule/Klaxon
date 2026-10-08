// Navigator (Phase 2a) — the page stack: route definitions, imperative
// navigation and deep links. This module is the UI-agnostic logic; the
// widget layer (widgets/navigator.zig) renders the stack and animates the
// transitions between pages.
//
//   - Routes are patterns ("anime/{id}") mapped to a page builder. The
//     builder receives the matched Route (concrete path + params) and
//     returns the page's root node.
//   - Ownership: the Navigator builds page nodes but NEVER deinits them —
//     the widget layer parents them into the tree, and the tree owns their
//     lifetime (a popped page is destroyed when its transition completes).
//   - Deep links: navigateTo("klaxon://anime/42?tab=2") parses the URI,
//     matches a route and pushes it. Called before the first frame, it
//     sets the initial stack (cold start — no transition).
//   - Back: onBack() pops while the stack is deeper than the root. The
//     widget wires it to the input router's back handler (Android hardware
//     button / desktop Escape).
const std = @import("std");
const node_mod = @import("node.zig");

const Node = node_mod.Node;

/// How the entering/exiting pages animate. Per-route (RouteDef.transition).
pub const Transition = enum {
    none, // instant swap
    slide, // horizontal (iOS-style push, with a parallax on the page below)
    slide_up, // vertical (sheets)
    fade, // cross-fade
    scale, // scale-in + fade-in (dialog-style)
};

pub const MAX_PARAMS = 8;

pub const Param = struct { key: []const u8, value: []const u8 };

/// Route parameters: path captures ("anime/{id}") first, then query params
/// ("?tab=2"). Fixed inline storage — a hop allocates nothing per param.
pub const Params = struct {
    items: [MAX_PARAMS]Param = undefined,
    len: u32 = 0,

    pub fn get(p: *const Params, key: []const u8) ?[]const u8 {
        for (p.items[0..p.len]) |it| {
            if (std.mem.eql(u8, it.key, key)) return it.value;
        }
        return null;
    }

    fn add(p: *Params, key: []const u8, value: []const u8) bool {
        if (p.len >= MAX_PARAMS) return false;
        p.items[p.len] = .{ .key = key, .value = value };
        p.len += 1;
        return true;
    }
};

/// A concrete route: the matched pattern, the concrete path and its params.
/// `pattern` is owned by the RouteDef; `path` and the param strings are
/// owned by the Page (freed on pop/deinit).
pub const Route = struct {
    pattern: []const u8,
    path: []const u8,
    params: Params = .{},
    transition: Transition = .slide,
};

/// Builds a page's root node from its route. ADR-0009 shape (fn ptr +
/// userdata). The returned node is NOT owned by the Navigator (the tree is).
pub const PageBuilder = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, route: Route) *Node,
    userdata: ?*anyopaque,
};

pub const RouteDef = struct {
    pattern: []const u8, // owned by the Navigator
    builder: PageBuilder,
    transition: Transition = .slide,
};

pub const Page = struct {
    id: u32, // unique, monotonic — the widget layer tracks wrappers by id
    route: Route,
    node: *Node,
};

pub const ChangeKind = enum { push, pop, replace, reset };

pub const ChangeCb = struct {
    fn_ptr: *const fn (userdata: ?*anyopaque, kind: ChangeKind) void,
    userdata: ?*anyopaque,
};

pub const Navigator = struct {
    allocator: std.mem.Allocator,
    pages: std.array_list.Managed(Page),
    routes: std.array_list.Managed(RouteDef),
    on_change: ?ChangeCb = null,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Navigator {
        return .{
            .allocator = allocator,
            .pages = std.array_list.Managed(Page).init(allocator),
            .routes = std.array_list.Managed(RouteDef).init(allocator),
        };
    }

    /// Frees the route table and the remaining pages' strings. Page NODES
    /// are not touched (the tree owns them — deinit the tree first or keep
    /// the pages alive).
    pub fn deinit(nav: *Navigator) void {
        for (nav.pages.items) |*p| freePage(nav.allocator, p);
        nav.pages.deinit();
        for (nav.routes.items) |*r| nav.allocator.free(r.pattern);
        nav.routes.deinit();
    }

    /// Register a route: pattern ("anime/{id}") + page builder + transition.
    pub fn define(nav: *Navigator, pattern: []const u8, builder: PageBuilder, transition: Transition) !void {
        try nav.routes.append(.{
            .pattern = try nav.allocator.dupe(u8, pattern),
            .builder = builder,
            .transition = transition,
        });
    }

    pub fn setOnChange(nav: *Navigator, cb: ?ChangeCb) void {
        nav.on_change = cb;
    }

    pub fn depth(nav: *const Navigator) usize {
        return nav.pages.items.len;
    }

    pub fn canPop(nav: *const Navigator) bool {
        return nav.pages.items.len > 1;
    }

    pub fn current(nav: *const Navigator) ?*Page {
        if (nav.pages.items.len == 0) return null;
        return &nav.pages.items[nav.pages.items.len - 1];
    }

    pub fn containsPage(nav: *const Navigator, id: u32) bool {
        for (nav.pages.items) |p| {
            if (p.id == id) return true;
        }
        return false;
    }

    /// Push a route by pattern: the concrete path is built from the pattern
    /// and the params ("anime/{id}" + id=42 → "anime/42").
    pub fn push(nav: *Navigator, pattern: []const u8, params: []const Param) !void {
        const def = nav.findDef(pattern) orelse return error.UnknownRoute;
        const path = try buildPath(nav.allocator, pattern, params);
        defer nav.allocator.free(path);
        try nav.pushDef(def, path, params);
    }

    /// Push a concrete path (deep links and cold starts). Params are given
    /// explicitly (already parsed from the URI).
    pub fn pushPath(nav: *Navigator, path: []const u8, params: []const Param) !void {
        var matched = Params{};
        const def = for (nav.routes.items) |*r| {
            if (matchPattern(r.pattern, path, &matched)) break r;
        } else return error.UnknownRoute;
        // merge the explicit params after the path captures
        for (params) |p| {
            if (!matched.add(p.key, p.value)) return error.TooManyParams;
        }
        try nav.pushDef(def, path, matched.items[0..matched.len]);
    }

    /// Deep link: "klaxon://anime/42?tab=2" (the scheme is optional).
    /// Navigating to the route already on top is a no-op.
    pub fn navigateTo(nav: *Navigator, uri: []const u8) !void {
        const parsed = parseUri(uri) orelse return error.InvalidUri;
        var params = Params{};
        const def = for (nav.routes.items) |*r| {
            if (matchPattern(r.pattern, parsed.path, &params)) break r;
        } else return error.UnknownRoute;
        // query params ("tab=2&lang=fr")
        var q = parsed.query;
        while (q.len > 0) {
            const amp = std.mem.indexOf(u8, q, "&");
            const pair = if (amp) |a| q[0..a] else q;
            q = if (amp) |a| q[a + 1 ..] else "";
            const eq = std.mem.indexOf(u8, pair, "=") orelse return error.InvalidUri;
            if (!params.add(pair[0..eq], pair[eq + 1 ..])) return error.TooManyParams;
        }
        // No-op when the top page is the same concrete path.
        if (nav.current()) |top| {
            if (std.mem.eql(u8, top.route.path, parsed.path)) return;
        }
        try nav.pushDef(def, parsed.path, params.items[0..params.len]);
    }

    /// Back (Android hardware button / Escape): pop while deeper than the
    /// root. Returns false at the root (the app may quit then).
    pub fn onBack(nav: *Navigator) bool {
        return nav.pop();
    }

    /// Pop the top page. False at the root (the stack never empties).
    pub fn pop(nav: *Navigator) bool {
        if (!nav.canPop()) return false;
        var page = nav.pages.pop().?;
        freePage(nav.allocator, &page);
        nav.notify(.pop);
        return true;
    }

    /// Replace the top page (same depth). On an empty stack this is a push.
    pub fn replace(nav: *Navigator, pattern: []const u8, params: []const Param) !void {
        if (nav.pages.items.len == 0) return nav.push(pattern, params);
        const def = nav.findDef(pattern) orelse return error.UnknownRoute;
        const path = try buildPath(nav.allocator, pattern, params);
        defer nav.allocator.free(path);
        const top = &nav.pages.items[nav.pages.items.len - 1];
        freePage(nav.allocator, top);
        top.* = try nav.buildPageFromSlice(def, path, params);
        nav.notify(.replace);
    }

    /// Pop everything above the root (one transition animates top → root).
    pub fn popToRoot(nav: *Navigator) void {
        if (nav.pages.items.len <= 1) return;
        while (nav.pages.items.len > 1) {
            var page = nav.pages.pop().?;
            freePage(nav.allocator, &page);
        }
        nav.notify(.reset);
    }

    // --- internals ---

    fn findDef(nav: *const Navigator, pattern: []const u8) ?*const RouteDef {
        for (nav.routes.items) |*r| {
            if (std.mem.eql(u8, r.pattern, pattern)) return r;
        }
        return null;
    }

    fn pushDef(nav: *Navigator, def: *const RouteDef, path: []const u8, params: []const Param) !void {
        const page = try nav.buildPageFromSlice(def, path, params);
        nav.pages.append(page) catch @panic("klaxon: out of memory");
        nav.notify(.push);
    }

    /// Build a page from borrowed param slices (duped into the navigator).
    fn buildPageFromSlice(nav: *Navigator, def: *const RouteDef, path: []const u8, params: []const Param) !Page {
        var owned = Params{};
        for (params) |p| {
            if (!owned.add(try nav.allocator.dupe(u8, p.key), try nav.allocator.dupe(u8, p.value))) {
                freeParams(nav.allocator, &owned);
                return error.TooManyParams;
            }
        }
        return nav.buildPageOwned(def, path, owned);
    }

    /// Build a page from owned params (the ownership transfers to the Page;
    /// on error the CALLER frees them).
    fn buildPageOwned(nav: *Navigator, def: *const RouteDef, path: []const u8, owned: Params) !Page {
        const owned_path = try nav.allocator.dupe(u8, path);
        errdefer nav.allocator.free(owned_path);
        const route = Route{
            .pattern = def.pattern,
            .path = owned_path,
            .params = owned,
            .transition = def.transition,
        };
        // The builder reads the route (params/path); it must not retain the
        // borrowed strings.
        const node = def.builder.fn_ptr(def.builder.userdata, route);
        const id = nav.next_id;
        nav.next_id += 1;
        return .{ .id = id, .route = route, .node = node };
    }

    fn notify(nav: *Navigator, kind: ChangeKind) void {
        if (nav.on_change) |cb| cb.fn_ptr(cb.userdata, kind);
    }
};

fn freePage(allocator: std.mem.Allocator, page: *Page) void {
    allocator.free(page.route.path);
    freeParams(allocator, &page.route.params);
}

fn freeParams(allocator: std.mem.Allocator, params: *Params) void {
    for (params.items[0..params.len]) |it| {
        allocator.free(it.key);
        allocator.free(it.value);
    }
    params.len = 0;
}

/// Build the concrete path from a pattern + params ("anime/{id}" + id=42).
fn buildPath(allocator: std.mem.Allocator, pattern: []const u8, params: []const Param) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    var it = std.mem.splitScalar(u8, pattern, '/');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try buf.append('/');
        first = false;
        if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
            const key = seg[1 .. seg.len - 1];
            var found: ?[]const u8 = null;
            for (params) |p| {
                if (std.mem.eql(u8, p.key, key)) {
                    found = p.value;
                    break;
                }
            }
            try buf.appendSlice(found orelse return error.MissingParam);
        } else {
            try buf.appendSlice(seg);
        }
    }
    return buf.toOwnedSlice();
}

/// Match a path against a pattern. "{name}" segments capture into `params`
/// (reset first). Static segments must be equal; the arity must match.
pub fn matchPattern(pattern: []const u8, path: []const u8, params: *Params) bool {
    params.len = 0;
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var hit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const ps = pit.next();
        const hs = hit.next();
        if (ps == null and hs == null) return true;
        const p = ps orelse return false;
        const h = hs orelse return false;
        if (p.len >= 2 and p[0] == '{' and p[p.len - 1] == '}') {
            if (!params.add(p[1 .. p.len - 1], h)) return false;
        } else if (!std.mem.eql(u8, p, h)) {
            return false;
        }
    }
}

pub const ParsedUri = struct { path: []const u8, query: []const u8 };

/// Parse "scheme://path?query" (the scheme is optional). Slices into `uri`
/// (no allocation). A trailing slash is stripped. Null when there is no path.
pub fn parseUri(uri: []const u8) ?ParsedUri {
    var rest = uri;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    var path = rest;
    var query: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "?")) |q| {
        path = rest[0..q];
        query = rest[q + 1 ..];
    }
    while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len == 0) return null;
    return .{ .path = path, .query = query };
}

// --- tests ---

// A minimal leaf page node (kept local: this module stays golden-free).
const LeafState = struct { w: f32 = 10, h: f32 = 10 };

fn leafMeasure(n: *Node, c: node_mod.Constraints) node_mod.Size {
    _ = n;
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn leafLayout(n: *Node, bounds: node_mod.Rect) void {
    _ = n;
    _ = bounds;
}
fn leafPaint(n: *Node, ctx: *@import("../kx.zig").Ctx) void {
    _ = n;
    _ = ctx;
}
fn leafDeinit(n: *Node) void {
    n.allocator.destroy(@as(*LeafState, @ptrCast(@alignCast(n.state.?))));
}
const leaf_vtable = node_mod.VTable{ .measure = leafMeasure, .layout = leafLayout, .paint = leafPaint, .deinit = leafDeinit };

fn testLeaf(allocator: std.mem.Allocator) !*Node {
    const node = try Node.create(allocator, &leaf_vtable);
    const s = try allocator.create(LeafState);
    s.* = .{ .w = 10, .h = 10 };
    node.state = s;
    return node;
}

/// Test builder: tracks every created page node (the Navigator does not own
/// nodes — the tests deinit them, the widget layer owns them in-app).
const TestBuilder = struct {
    allocator: std.mem.Allocator,
    created: std.array_list.Managed(*Node),
    last_route: ?Route = null,

    fn init(allocator: std.mem.Allocator) TestBuilder {
        return .{ .allocator = allocator, .created = std.array_list.Managed(*Node).init(allocator) };
    }

    fn builder(userdata: ?*anyopaque, route: Route) *Node {
        const self: *TestBuilder = @ptrCast(@alignCast(userdata.?));
        const n = testLeaf(self.allocator) catch @panic("klaxon: out of memory");
        self.created.append(n) catch @panic("klaxon: out of memory");
        self.last_route = route;
        return n;
    }

    fn deinitAll(self: *TestBuilder) void {
        for (self.created.items) |n| n.deinit();
        self.created.deinit();
    }
};

/// The builder userdata must be stable: tb lives on the heap (a by-value
/// return would leave the routes' userdata pointing at a dead stack frame).
fn testNav() !struct { nav: Navigator, tb: *TestBuilder } {
    var nav = Navigator.init(std.testing.allocator);
    errdefer nav.deinit();
    const tb = try std.testing.allocator.create(TestBuilder);
    errdefer std.testing.allocator.destroy(tb);
    tb.* = TestBuilder.init(std.testing.allocator);
    try nav.define("home", .{ .fn_ptr = TestBuilder.builder, .userdata = tb }, .none);
    try nav.define("anime/{id}", .{ .fn_ptr = TestBuilder.builder, .userdata = tb }, .slide);
    try nav.define("page", .{ .fn_ptr = TestBuilder.builder, .userdata = tb }, .fade);
    return .{ .nav = nav, .tb = tb };
}

test "push builds the path from pattern + params and tracks the page" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.push("anime/{id}", &.{.{ .key = "id", .value = "42" }});
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    const page = t.nav.current().?;
    try std.testing.expectEqualStrings("anime/42", page.route.path);
    try std.testing.expectEqualStrings("42", page.route.params.get("id").?);
    try std.testing.expectEqual(Transition.slide, page.route.transition);
    // the builder received the route
    try std.testing.expectEqualStrings("anime/42", t.tb.last_route.?.path);
}

test "push with a missing param fails (MissingParam)" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try std.testing.expectError(error.MissingParam, t.nav.push("anime/{id}", &.{}));
    try std.testing.expectEqual(@as(usize, 0), t.nav.depth());
}

test "push of an unknown route fails (UnknownRoute)" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try std.testing.expectError(error.UnknownRoute, t.nav.push("nope", &.{}));
}

test "pop / canPop / onBack never empty the stack" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.push("home", &.{});
    try t.nav.push("page", &.{});
    try std.testing.expectEqual(@as(usize, 2), t.nav.depth());
    try std.testing.expect(t.nav.canPop());
    try std.testing.expect(t.nav.onBack());
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    try std.testing.expect(!t.nav.canPop());
    try std.testing.expect(!t.nav.onBack()); // at the root
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    try std.testing.expect(!t.nav.pop());
}

test "replace swaps the top page (same depth) and pushes on an empty stack" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.replace("home", &.{}); // empty stack → push
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    try t.nav.replace("page", &.{});
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    try std.testing.expectEqualStrings("page", t.nav.current().?.route.path);
    try std.testing.expectEqual(Transition.fade, t.nav.current().?.route.transition);
}

test "popToRoot keeps only the root" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.push("home", &.{});
    try t.nav.push("page", &.{});
    try t.nav.push("anime/{id}", &.{.{ .key = "id", .value = "7" }});
    t.nav.popToRoot();
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    try std.testing.expectEqualStrings("home", t.nav.current().?.route.path);
    t.nav.popToRoot(); // already at the root: no-op
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
}

test "page ids are unique and monotonic (containsPage)" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.push("home", &.{});
    try t.nav.push("page", &.{});
    const id_a = t.nav.pages.items[0].id;
    const id_b = t.nav.pages.items[1].id;
    try std.testing.expect(id_b > id_a);
    try std.testing.expect(t.nav.containsPage(id_a));
    _ = t.nav.pop();
    try std.testing.expect(!t.nav.containsPage(id_b));
    try std.testing.expect(t.nav.containsPage(id_a));
}

test "matchPattern: static, capture, arity and mismatch" {
    var params = Params{};
    try std.testing.expect(matchPattern("home", "home", &params));
    try std.testing.expectEqual(@as(u32, 0), params.len);
    try std.testing.expect(matchPattern("anime/{id}", "anime/42", &params));
    try std.testing.expectEqualStrings("42", params.get("id").?);
    try std.testing.expect(matchPattern("a/{x}/c/{y}", "a/1/c/2", &params));
    try std.testing.expectEqualStrings("1", params.get("x").?);
    try std.testing.expectEqualStrings("2", params.get("y").?);
    try std.testing.expect(!matchPattern("anime/{id}", "anime", &params)); // arity
    try std.testing.expect(!matchPattern("anime/{id}", "anime/42/extra", &params)); // arity
    try std.testing.expect(!matchPattern("anime/{id}", "manga/42", &params)); // static mismatch
    // too many captures for the inline storage
    try std.testing.expect(!matchPattern("{a}/{b}/{c}/{d}/{e}/{f}/{g}/{h}/{i}", "1/2/3/4/5/6/7/8/9", &params));
}

test "parseUri: scheme, query, trailing slash, degenerate" {
    const p1 = parseUri("klaxon://anime/42?tab=2").?;
    try std.testing.expectEqualStrings("anime/42", p1.path);
    try std.testing.expectEqualStrings("tab=2", p1.query);
    const p2 = parseUri("anime/42").?;
    try std.testing.expectEqualStrings("anime/42", p2.path);
    try std.testing.expectEqualStrings("", p2.query);
    const p3 = parseUri("klaxon://home/").?;
    try std.testing.expectEqualStrings("home", p3.path);
    try std.testing.expect(parseUri("") == null);
    try std.testing.expect(parseUri("klaxon://") == null);
    try std.testing.expect(parseUri("klaxon://?tab=2") == null);
}

test "navigateTo pushes from a deep link (path + query params)" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.navigateTo("klaxon://anime/42?tab=2");
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    const route = t.nav.current().?.route;
    try std.testing.expectEqualStrings("anime/42", route.path);
    try std.testing.expectEqualStrings("42", route.params.get("id").?);
    try std.testing.expectEqualStrings("2", route.params.get("tab").?);
    // same route on top → no-op
    try t.nav.navigateTo("klaxon://anime/42?tab=9");
    try std.testing.expectEqual(@as(usize, 1), t.nav.depth());
    // unknown route / invalid uri
    try std.testing.expectError(error.UnknownRoute, t.nav.navigateTo("klaxon://nope/1"));
    try std.testing.expectError(error.InvalidUri, t.nav.navigateTo("klaxon://"));
    try std.testing.expectError(error.InvalidUri, t.nav.navigateTo("klaxon://home?badquery"));
}

test "navigateTo is the cold start (initial stack before the first frame)" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    try t.nav.push("home", &.{});
    try t.nav.navigateTo("klaxon://anime/9");
    try std.testing.expectEqual(@as(usize, 2), t.nav.depth());
    try std.testing.expectEqualStrings("anime/9", t.nav.current().?.route.path);
}

test "on_change fires with the mutation kind" {
    var t = try testNav();
    defer t.nav.deinit();
    defer std.testing.allocator.destroy(t.tb);
    defer t.tb.deinitAll();
    var kinds: [8]ChangeKind = undefined;
    var n: u32 = 0;
    const Ctx = struct {
        kinds: *[8]ChangeKind,
        n: *u32,
        fn cb(userdata: ?*anyopaque, kind: ChangeKind) void {
            const c: *@This() = @ptrCast(@alignCast(userdata.?));
            c.kinds[c.n.*] = kind;
            c.n.* += 1;
        }
    };
    var ctx = Ctx{ .kinds = &kinds, .n = &n };
    t.nav.setOnChange(.{ .fn_ptr = Ctx.cb, .userdata = &ctx });
    try t.nav.push("home", &.{});
    try t.nav.push("page", &.{});
    _ = t.nav.pop();
    try t.nav.push("anime/{id}", &.{.{ .key = "id", .value = "1" }});
    try t.nav.replace("page", &.{});
    t.nav.popToRoot();
    try std.testing.expectEqual(@as(u32, 6), n);
    try std.testing.expectEqual(ChangeKind.push, kinds[0]);
    try std.testing.expectEqual(ChangeKind.push, kinds[1]);
    try std.testing.expectEqual(ChangeKind.pop, kinds[2]);
    try std.testing.expectEqual(ChangeKind.push, kinds[3]);
    try std.testing.expectEqual(ChangeKind.replace, kinds[4]);
    try std.testing.expectEqual(ChangeKind.reset, kinds[5]);
}
