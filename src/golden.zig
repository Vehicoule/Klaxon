// Golden — offscreen rendering + pixel assertions for widget tests (Phase 1b).
// Renders through the raster backend: no window, no GPU, hermetic on CI.
// The same helper will drive the gallery (Phase 1g) and the conformance
// suite (Phase 4c).
//
// Golden rule: assert STRUCTURAL properties — exact pixel counts for solid
// rects, presence/absence of a color for text and icons (glyph shapes are
// font-dependent and differ per platform). Never assert glyph bitmaps.
const std = @import("std");
const kx = @import("kx.zig");
const ui = @import("ui.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Color = ui.paint.Color;

/// One rendered frame's pixels (RGBA memory order). Pixels only — no ctx, no
/// tree: use Renderer for interactive (multi-frame) scenarios.
pub const Frame = struct {
    pixels: []u8, // RGBA memory order (R,G,B,A), w*h*4
    w: i32,
    h: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(f: *Frame) void {
        f.allocator.free(f.pixels);
    }

    /// Pixel as 0xRRGGBBAA (matches ui.paint.Color).
    pub fn pixelAt(f: Frame, x: i32, y: i32) Color {
        const i = (@as(usize, @intCast(y)) * @as(usize, @intCast(f.w)) + @as(usize, @intCast(x))) * 4;
        return @as(u32, f.pixels[i]) << 24 |
            @as(u32, f.pixels[i + 1]) << 16 |
            @as(u32, f.pixels[i + 2]) << 8 |
            @as(u32, f.pixels[i + 3]);
    }

    /// Count pixels exactly equal to `color` in the whole frame.
    pub fn countColor(f: Frame, color: Color) u64 {
        const r: u8 = @intCast((color >> 24) & 0xFF);
        const g: u8 = @intCast((color >> 16) & 0xFF);
        const b: u8 = @intCast((color >> 8) & 0xFF);
        const a: u8 = @intCast(color & 0xFF);
        var n: u64 = 0;
        var i: usize = 0;
        while (i < f.pixels.len) : (i += 4) {
            if (f.pixels[i] == r and f.pixels[i + 1] == g and f.pixels[i + 2] == b and f.pixels[i + 3] == a) n += 1;
        }
        return n;
    }

    /// Count pixels different from `color` in the whole frame (text/icons: AA
    /// blends count as "not background").
    pub fn countNot(f: Frame, color: Color) u64 {
        const total: u64 = @intCast(f.pixels.len / 4);
        return total - f.countColor(color);
    }

    /// Rect clipped to the frame (integer bounds).
    fn clipToFrame(f: Frame, rect: Rect) Rect {
        const x0 = @max(0, @as(i32, @intFromFloat(rect.x)));
        const y0 = @max(0, @as(i32, @intFromFloat(rect.y)));
        const x1 = @min(f.w, @as(i32, @intFromFloat(rect.x + rect.w)));
        const y1 = @min(f.h, @as(i32, @intFromFloat(rect.y + rect.h)));
        return .{
            .x = @floatFromInt(x0),
            .y = @floatFromInt(y0),
            .w = @floatFromInt(@max(0, x1 - x0)),
            .h = @floatFromInt(@max(0, y1 - y0)),
        };
    }

    /// Count pixels exactly equal to `color` inside a rect (clipped to frame).
    pub fn countColorIn(f: Frame, rect: Rect, color: Color) u64 {
        const r = f.clipToFrame(rect);
        var n: u64 = 0;
        var y = @as(i32, @intFromFloat(r.y));
        while (y < @as(i32, @intFromFloat(r.y + r.h))) : (y += 1) {
            var x = @as(i32, @intFromFloat(r.x));
            while (x < @as(i32, @intFromFloat(r.x + r.w))) : (x += 1) {
                if (f.pixelAt(x, y) == color) n += 1;
            }
        }
        return n;
    }

    /// Count pixels different from `color` inside a rect (clipped to frame).
    pub fn countNotIn(f: Frame, rect: Rect, color: Color) u64 {
        const r = f.clipToFrame(rect);
        const w: u64 = @intCast(@as(i32, @intFromFloat(r.w)));
        const h: u64 = @intCast(@as(i32, @intFromFloat(r.h)));
        return w * h - f.countColorIn(rect, color);
    }
};

/// Offscreen raster renderer — owns the kx ctx. For interactive golden tests:
/// lay out the tree, dispatch input events between frames, read back pixels.
/// The tree is NOT owned: destroy it before the Renderer (widgets may hold
/// ctx-bound GPU resources — destroying the ctx first is a use-after-free).
pub const Renderer = struct {
    ctx: *kx.Ctx,
    w: i32,
    h: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: i32, h: i32) !Renderer {
        const ctx = kx.create(null, w, h, kx.c.KX_BACKEND_RASTER) orelse return error.KxCreateFailed;
        return .{ .ctx = ctx, .w = w, .h = h, .allocator = allocator };
    }

    pub fn deinit(r: *Renderer) void {
        kx.c.kx_destroy(r.ctx);
    }

    /// Paint one frame of `root` on a cleared `bg`.
    pub fn paint(r: *Renderer, root: *Node, bg: Color) void {
        kx.c.kx_begin_frame(r.ctx);
        kx.c.kx_clear(r.ctx, bg);
        root.paint(r.ctx);
        kx.c.kx_end_frame(r.ctx);
    }

    pub fn readback(r: *Renderer, allocator: std.mem.Allocator) !Frame {
        const pixels = try allocator.alloc(u8, @as(usize, @intCast(r.w)) * @as(usize, @intCast(r.h)) * 4);
        errdefer allocator.free(pixels);
        var ow: c_int = 0;
        var oh: c_int = 0;
        if (!kx.c.kx_readback_rgba(r.ctx, pixels.ptr, pixels.len, &ow, &oh)) return error.ReadbackFailed;
        return .{ .pixels = pixels, .w = r.w, .h = r.h, .allocator = allocator };
    }
};

/// Lay out `root` over a w×h canvas, paint one frame on `bg`, read it back.
/// Takes ownership of `root`: the tree is torn down BEFORE the ctx (widgets
/// may hold ctx-bound GPU resources — destroying the ctx first is a
/// use-after-free).
pub fn render(allocator: std.mem.Allocator, root: *Node, w: i32, h: i32, bg: Color) !Frame {
    var r = try Renderer.init(allocator, w, h);
    defer r.deinit();
    defer root.deinit(); // defer LIFO: the tree dies before the ctx
    root.layout(.{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) });
    r.paint(root, bg);
    return r.readback(allocator);
}

// --- Test leaf: a solid rect (exact pixels at integer bounds) ---

const BoxState = struct {
    w: f32,
    h: f32,
    color: Color,
};

fn boxMeasure(n: *Node, c: ui.layout.Constraints) ui.layout.Size {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn boxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn boxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s: *BoxState = @ptrCast(@alignCast(n.state.?));
    ui.paint.fillRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.color);
}
fn boxDeinit(n: *Node) void {
    n.allocator.destroy(@as(*BoxState, @ptrCast(@alignCast(n.state.?))));
}
const box_vtable = ui.node.VTable{ .measure = boxMeasure, .layout = boxLayout, .paint = boxPaint, .deinit = boxDeinit };

pub fn solidBox(allocator: std.mem.Allocator, w: f32, h: f32, color: Color) !*Node {
    const node = try Node.create(allocator, &box_vtable);
    const s = try allocator.create(BoxState);
    s.* = .{ .w = w, .h = h, .color = color };
    node.state = s;
    return node;
}
