// Paint — drawing state for a node, emitted through the kx_skia ABI.
// Phase 0: solid colors (fill/stroke), rects, text. Path, gradients, blur and
// images land in Phase 1 as the widget library grows the ABI.
const std = @import("std");
const kx = @import("../kx.zig");

/// Color: 0xRRGGBBAA (R in the high byte, alpha in the low byte).
pub const Color = u32;

pub const Style = enum { fill, stroke };

pub const Paint = struct {
    color: Color = 0xFF000000,
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

pub fn fillRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    kx.c.kx_fill_rect(ctx, x, y, w, h, color);
}

pub fn fillRRect(ctx: *kx.Ctx, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
    kx.c.kx_fill_rrect(ctx, x, y, w, h, radius, color);
}

pub fn text(ctx: *kx.Ctx, str: [:0]const u8, x: f32, baseline_y: f32, size: f32, color: Color) void {
    kx.c.kx_draw_text(ctx, str, x, baseline_y, size, color);
}
