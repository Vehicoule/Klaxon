// Paint — drawing state for a node, emitted through the kx_skia ABI.
// Solid colors (fill/stroke), rects, rrects, text + text metrics, images.
// Path, gradients, blur land later as the widget library grows the ABI.
const std = @import("std");
const kx = @import("../kx.zig");

/// Color: 0xRRGGBBAA (R in the high byte, alpha in the low byte).
pub const Color = u32;

pub const Style = enum { fill, stroke };

pub const Paint = struct {
    color: Color = 0x000000FF, // opaque black (0xRRGGBBAA)
    style: Style = .fill,
    stroke_width: f32 = 1.0,

    pub fn fill(color: Color) Paint {
        return .{ .color = color };
    }

    pub fn stroke(color: Color, width: f32) Paint {
        return .{ .color = color, .style = .stroke, .stroke_width = width };
    }
};

// --- Emission (called from node paint with the kx context) ---

// Canvas state + transforms (Phase 1e, ABI 0.3.0). save/restore must be
// balanced within a frame; widgets wrap their children's paint in a pair.
pub fn save(ctx: *kx.Ctx) void {
    kx.c.kx_save(ctx);
}

pub fn restore(ctx: *kx.Ctx) void {
    kx.c.kx_restore(ctx);
}

pub fn translate(ctx: *kx.Ctx, dx: f32, dy: f32) void {
    kx.c.kx_translate(ctx, dx, dy);
}

pub fn scale(ctx: *kx.Ctx, sx: f32, sy: f32) void {
    kx.c.kx_scale(ctx, sx, sy);
}

/// Clip the current frame to a rect (save + intersect clip).
/// Balanced with clipReset (restores the canvas state).
pub fn clipRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32) void {
    kx.c.kx_clip_rect(ctx, x, y, w, h);
}

pub fn clipReset(ctx: *kx.Ctx) void {
    kx.c.kx_clip_reset(ctx);
}

/// Push an alpha layer (saveLayer with alpha, ABI 0.4.0): everything painted
/// until the matching restore() composites at `alpha` opacity — fade
/// transitions (Phase 2a) and hero dimming.
pub fn layerAlpha(ctx: *kx.Ctx, alpha: f32) void {
    kx.c.kx_layer_alpha(ctx, alpha);
}

pub fn fillRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    kx.c.kx_fill_rect(ctx, x, y, w, h, color);
}

pub fn fillRRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
    kx.c.kx_fill_rrect(ctx, x, y, w, h, radius, color);
}

/// Stroke a polyline through (xs, ys) (ABI 0.5.0) — arcs and wavy progress
/// indicators are polylines generated in Zig; no path type crosses the ABI.
pub fn strokePolyline(ctx: *kx.Ctx, xs: []const f32, ys: []const f32, stroke_w: f32, round_cap: bool, color: Color) void {
    kx.c.kx_stroke_polyline(ctx, xs.ptr, ys.ptr, @intCast(xs.len), stroke_w, round_cap, color);
}

pub fn text(ctx: *kx.Ctx, str: [:0]const u8, x: f32, baseline_y: f32, size: f32, bold: bool, color: Color) void {
    kx.c.kx_draw_text_styled(ctx, str, x, baseline_y, size, bold, color);
}

// --- Text metrics (layout-time; ctx-independent, fonts are process-global) ---

pub const TextMetrics = kx.c.kx_text_metrics;

pub fn measureText(str: [:0]const u8, size: f32, bold: bool) TextMetrics {
    return kx.c.kx_measure_text(str, size, bold);
}

// --- Images (per-ctx registry; create once, draw many) ---

pub fn imageCreate(ctx: *kx.Ctx, rgba: [*]const u8, w: i32, h: i32) u64 {
    return kx.c.kx_image_create(ctx, rgba, w, h);
}

pub fn imageDestroy(ctx: *kx.Ctx, id: u64) void {
    kx.c.kx_image_destroy(ctx, id);
}

pub fn imageDraw(ctx: *kx.Ctx, id: u64, x: f32, y: f32, w: f32, h: f32) void {
    kx.c.kx_draw_image(ctx, id, x, y, w, h);
}
