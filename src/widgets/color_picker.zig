// M3E color picker (Phase 2d.4 PR #34) — a framework-original color picker
// panel inspired by M3E tokens. No official M3/M3E color picker spec exists;
// the design cross-references material-components-android ColorPicker,
// iOS UIColorPickerViewController, Flutter flutter_colorpicker, VS Code /
// Figma / Chrome native pickers, and the M3E token system (src/theme.zig).
//
// Spec: docs/specs/m3e-specs-2d4-colorpicker.md
//
// Components:
//   - SV square (saturation/value): a CornerMedium 12dp rounded rect filled
//     with 3 layered gradients — the pure hue base + a horizontal white
//     gradient (S: 0→1) + a vertical black gradient (V: 1→0) — via
//     fillRRectGradient (ABI 0.10.0). A 20dp cursor (2dp OnSurface stroke,
//     fill = the selected color) marks (s, v).
//   - Hue slider: a CornerFull 24dp bar with a 7-stop rainbow gradient
//     (red→yellow→green→cyan→blue→magenta→red) via fillRRectGradient.
//     A 4×32dp OnSurface cursor marks h.
//   - Preview swatch (48×48, CornerSmall 8dp, 1dp OutlineVariant stroke)
//     + a hex text field (#RRGGBB).
//
// Panel: 320dp wide, SurfaceContainerHigh, CornerExtraLarge 28dp, 20dp
// inner padding, 16dp gaps between sections. Total height 344dp.
//
// Color model: internal HSV (h 0..360, s 0..1, v 0..1); external Color
// (0xRRGGBBAA, alpha always 0xFF in v1). Conversions are pure + total.
//
// State: `color` is a two-way Signal(Color) — always live, round-trips.
// Dragging: sv or hue. Hex field: simplified single-line input (no IME,
// no selection — v1).
//
// v1 deviations (documented, fixed later):
//   - No alpha slider (alpha forced to 0xFF).
//   - No RGB/HSL numeric inputs (hex only).
//   - No preset swatches, no eyedropper.
//   - Hex field: no IME, no selection, no caret blink, no click-to-position.
//   - Instant cursor movement (animated spring = Phase 3).
//   - en strings only.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const ColorPickerOptions = struct {
    theme: Theme = theme_mod.light,
    /// The panel width (320dp default).
    width: f32 = 320,
};

// --- M3E tokens ---

const panel_corner: f32 = 28; // CornerExtraLarge
const panel_pad: f32 = 20;
const section_gap: f32 = 16;
const sv_corner: f32 = 12; // CornerMedium
const sv_height: f32 = 200;
const sv_cursor: f32 = 20;
const sv_cursor_stroke: f32 = 2;
const hue_h: f32 = 24;
const hue_cursor_w: f32 = 4;
const hue_cursor_h: f32 = 32;
const hue_cursor_corner: f32 = 2; // CornerSmall
const swatch_size: f32 = 48;
const swatch_corner: f32 = 8; // CornerSmall
const swatch_stroke: f32 = 1;
const hex_h: f32 = 48;
const hex_gap: f32 = 12;

// --- Color helpers (RGB <-> HSV, RGB <-> Hex) ---

pub const Hsv = struct { h: f32, s: f32, v: f32 };

/// RGB (0..255 each) -> HSV (h 0..360, s 0..1, v 0..1).
pub fn rgbToHsv(r: u8, g: u8, b: u8) Hsv {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;
    const max = @max(rf, @max(gf, bf));
    const min = @min(rf, @min(gf, bf));
    const d = max - min;
    var h: f32 = 0;
    if (d > 0) {
        if (max == rf) {
            h = 60 * @mod((gf - bf) / d, 6);
        } else if (max == gf) {
            h = 60 * ((bf - rf) / d + 2);
        } else {
            h = 60 * ((rf - gf) / d + 4);
        }
    }
    if (h < 0) h += 360;
    const s = if (max > 0) d / max else 0;
    return .{ .h = h, .s = s, .v = max };
}

/// HSV (h 0..360, s 0..1, v 0..1) -> RGB (0..255 each).
pub fn hsvToRgb(h: f32, s: f32, v: f32) struct { r: u8, g: u8, b: u8 } {
    const hh = @mod(h, 360);
    const c = v * s;
    const x = c * (1 - @abs(@mod(hh / 60, 2) - 1));
    const m = v - c;
    var rf: f32 = 0;
    var gf: f32 = 0;
    var bf: f32 = 0;
    if (hh < 60) {
        rf = c; gf = x;
    } else if (hh < 120) {
        rf = x; gf = c;
    } else if (hh < 180) {
        gf = c; bf = x;
    } else if (hh < 240) {
        gf = x; bf = c;
    } else if (hh < 300) {
        rf = x; bf = c;
    } else {
        rf = c; bf = x;
    }
    return .{
        .r = @intFromFloat(@round((rf + m) * 255)),
        .g = @intFromFloat(@round((gf + m) * 255)),
        .b = @intFromFloat(@round((bf + m) * 255)),
    };
}

/// Color (0xRRGGBBAA) -> HSV.
pub fn colorToHsv(c: Color) Hsv {
    return rgbToHsv(
        @intCast((c >> 24) & 0xFF),
        @intCast((c >> 16) & 0xFF),
        @intCast((c >> 8) & 0xFF),
    );
}

/// HSV -> Color (0xRRGGBBAA, alpha forced to 0xFF).
pub fn hsvToColor(h: f32, s: f32, v: f32) Color {
    const rgb = hsvToRgb(h, s, v);
    return (@as(Color, rgb.r) << 24) | (@as(Color, rgb.g) << 16) | (@as(Color, rgb.b) << 8) | 0xFF;
}

/// Color (0xRRGGBBAA) -> "#RRGGBB" (7 chars + null = 8 bytes).
pub fn colorToHex(c: Color, buf: *[8]u8) [:0]const u8 {
    const hex = "0123456789ABCDEF";
    buf[0] = '#';
    buf[1] = hex[(c >> 28) & 0xF];
    buf[2] = hex[(c >> 24) & 0xF];
    buf[3] = hex[(c >> 20) & 0xF];
    buf[4] = hex[(c >> 16) & 0xF];
    buf[5] = hex[(c >> 12) & 0xF];
    buf[6] = hex[(c >> 8) & 0xF];
    buf[7] = 0;
    return buf[0..7 :0];
}

/// "#RRGGBB" or "RRGGBB" -> Color (0xRRGGBBAA). Returns null if invalid.
pub fn hexToColor(str: []const u8) ?Color {
    var s = str;
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return null;
    var val: u32 = 0;
    for (s) |ch| {
        const digit: u32 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => return null,
        };
        val = (val << 4) | digit;
    }
    return (val << 8) | 0xFF;
}

// --- Hue rainbow gradient stops (7 stops, 0°..360°) ---

fn hueStops() [7]Color {
    return .{
        0xFF0000FF, // red    (0°)
        0xFFFF00FF, // yellow (60°)
        0x00FF00FF, // green  (120°)
        0x00FFFFFF, // cyan   (180°)
        0x0000FFFF, // blue   (240°)
        0xFF00FFFF, // magenta(300°)
        0xFF0000FF, // red    (360°)
    };
}

// --- State ---

const DragTarget = enum { none, sv, hue };
const FocusTarget = enum { none, sv, hue, hex };

pub const CPState = struct {
    opts: ColorPickerOptions,
    sig: ?*ui.state.Signal(Color),
    on_change: ?Callback,
    h: f32 = 0,
    s: f32 = 1,
    v: f32 = 1,
    dragging: DragTarget = .none,
    hovered: DragTarget = .none,
    focus: FocusTarget = .none,
    hex_buf: [8]u8 = .{ '#', 'F', 'F', '0', '0', '0', '0', 0 },
    hex_dirty: bool = false, // hex edited but not yet applied
    /// The down position in raw coords (drag past slop = scroll cancel).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    /// Cached layout rects (set in layout, used by paint/hit).
    sv_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hue_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    swatch_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hex_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub fn stateOf(n: *Node) *CPState {
    return @ptrCast(@alignCast(n.state.?));
}

/// Sync the internal HSV from the signal's color.
fn syncHsv(s: *CPState) void {
    if (s.sig) |sig| {
        const hsv = colorToHsv(sig.peek());
        s.h = hsv.h;
        s.s = hsv.s;
        s.v = hsv.v;
    }
}

/// Push the current HSV to the signal + fire on_change + update hex + a11y.
fn pushColor(s: *CPState, n: *Node) void {
    const c = hsvToColor(s.h, s.s, s.v);
    if (s.sig) |sig| sig.set(c);
    // Update hex buffer (unless the user is actively editing it).
    if (!s.hex_dirty) {
        _ = colorToHex(c, &s.hex_buf);
    }
    // Update a11y value.
    if (n.semantics) |sem| {
        sem.value = s.hex_buf[0..7];
    }
    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
    n.markDirty();
}

/// Set color from an external value (signal changed externally).
fn applyExternalColor(s: *CPState, n: *Node, c: Color) void {
    const hsv = colorToHsv(c);
    s.h = hsv.h;
    s.s = hsv.s;
    s.v = hsv.v;
    if (!s.hex_dirty) {
        _ = colorToHex(c, &s.hex_buf);
    }
    if (n.semantics) |sem| {
        sem.value = s.hex_buf[0..7];
    }
    n.markDirty();
}

// --- Layout metrics ---

fn svWidth(opts: ColorPickerOptions) f32 {
    return opts.width - panel_pad * 2;
}

fn svY() f32 {
    return panel_pad;
}

fn hueY() f32 {
    return svY() + sv_height + section_gap;
}

fn previewY() f32 {
    return hueY() + hue_h + section_gap;
}

fn totalHeight(_: ColorPickerOptions) f32 {
    return panel_pad + sv_height + section_gap + hue_h + section_gap + hex_h + panel_pad;
}

// --- Measure ---

fn cpMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const w = @max(s.opts.width, svWidth(s.opts) + panel_pad * 2);
    const h = totalHeight(s.opts);
    return .{
        .w = @max(c.min_w, @min(c.max_w, w)),
        .h = @max(c.min_h, @min(c.max_h, h)),
    };
}

// --- Layout ---

fn cpLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(n);
    const inner_x = bounds.x + panel_pad;
    const inner_w = bounds.w - panel_pad * 2;
    s.sv_rect = .{ .x = inner_x, .y = bounds.y + svY(), .w = inner_w, .h = sv_height };
    s.hue_rect = .{ .x = inner_x, .y = bounds.y + hueY(), .w = inner_w, .h = hue_h };
    s.swatch_rect = .{ .x = inner_x, .y = bounds.y + previewY(), .w = swatch_size, .h = swatch_size };
    s.hex_rect = .{
        .x = inner_x + swatch_size + hex_gap,
        .y = bounds.y + previewY(),
        .w = inner_w - swatch_size - hex_gap,
        .h = hex_h,
    };
}

// --- Paint ---

fn cpPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;

    // Panel background.
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, panel_corner, t.colors.surface_container_high);

    const sv = s.sv_rect;
    const hue = s.hue_rect;

    // --- SV square ---
    // 1. Base: pure hue color.
    const pure_hue = hsvToColor(s.h, 1, 1);
    ui.paint.fillRRect(ctx, sv.x, sv.y, sv.w, sv.h, sv_corner, pure_hue);
    // 2. Saturation overlay: horizontal white gradient (transparent → opaque).
    const sat_stops = [_]Color{ 0xFFFFFF00, 0xFFFFFFFF };
    ui.paint.fillRRectGradient(ctx, sv.x, sv.y, sv.w, sv.h, sv_corner, sv.x, sv.y, sv.x + sv.w, sv.y, &sat_stops);
    // 3. Value overlay: vertical black gradient (transparent → opaque).
    const val_stops = [_]Color{ 0x00000000, 0xFF000000 };
    ui.paint.fillRRectGradient(ctx, sv.x, sv.y, sv.w, sv.h, sv_corner, sv.x, sv.y, sv.x, sv.y + sv.h, &val_stops);

    // SV cursor.
    const cur_color = hsvToColor(s.h, s.s, s.v);
    const cx = sv.x + s.s * sv.w;
    const cy = sv.y + (1 - s.v) * sv.h;
    // White ring for visibility on any background.
    ui.paint.fillRRect(ctx, cx - sv_cursor / 2 - 1, cy - sv_cursor / 2 - 1, sv_cursor + 2, sv_cursor + 2, sv_cursor / 2 + 1, 0xFFFFFFFF);
    ui.paint.fillRRect(ctx, cx - sv_cursor / 2, cy - sv_cursor / 2, sv_cursor, sv_cursor, sv_cursor / 2, cur_color);
    ui.paint.strokeRRect(ctx, cx - sv_cursor / 2, cy - sv_cursor / 2, sv_cursor, sv_cursor, sv_cursor / 2, sv_cursor_stroke, t.colors.on_surface);

    // --- Hue slider ---
    const stops = hueStops();
    ui.paint.fillRRectGradient(ctx, hue.x, hue.y, hue.w, hue.h, hue.h / 2, hue.x, hue.y, hue.x + hue.w, hue.y, &stops);

    // Hue cursor (4×32, centered vertically on the 24dp bar).
    const hx = hue.x + (s.h / 360) * hue.w;
    const hcy = hue.y + hue.h / 2;
    ui.paint.fillRRect(ctx, hx - hue_cursor_w / 2, hcy - hue_cursor_h / 2, hue_cursor_w, hue_cursor_h, hue_cursor_corner, t.colors.on_surface);
    // Inner color strip on the cursor.
    ui.paint.fillRRect(ctx, hx - hue_cursor_w / 2 + 1, hcy - hue_cursor_h / 2 + 1, hue_cursor_w - 2, hue_cursor_h - 2, 1, pure_hue);

    // --- Preview swatch ---
    const sw = s.swatch_rect;
    ui.paint.fillRRect(ctx, sw.x, sw.y, sw.w, sw.h, swatch_corner, cur_color);
    ui.paint.strokeRRect(ctx, sw.x, sw.y, sw.w, sw.h, swatch_corner, swatch_stroke, t.colors.outline_variant);

    // --- Hex field ---
    const hx_rect = s.hex_rect;
    const field_corner: f32 = 8;
    // Field background.
    const field_bg = if (s.focus == .hex) t.colors.surface_container_highest else t.colors.surface_container_highest;
    ui.paint.fillRRect(ctx, hx_rect.x, hx_rect.y, hx_rect.w, hx_rect.h, field_corner, field_bg);
    // Focus indicator (bottom line, like M3E text field).
    const indicator_color = if (s.focus == .hex) t.colors.primary else t.colors.on_surface_variant;
    const indicator_h: f32 = if (s.focus == .hex) 2 else 1;
    ui.paint.fillRect(ctx, hx_rect.x, hx_rect.y + hx_rect.h - indicator_h, hx_rect.w, indicator_h, indicator_color);
    // Hex text.
    const hex_z = s.hex_buf[0..7 :0];
    const ts = t.type_scale.body_large;
    const text_x = hx_rect.x + 16;
    const text_y = hx_rect.y + (hx_rect.h - ts.line_height) / 2 + ts.line_height * 0.8;
    ui.paint.text(ctx, hex_z, text_x, text_y, ts.size, ts.weight >= 500, t.colors.on_surface);
}

// --- Hit test ---

fn zoneAt(s: *CPState, x: f32, y: f32) DragTarget {
    if (s.sv_rect.contains(x, y)) return .sv;
    if (s.hue_rect.contains(x, y)) return .hue;
    return .none;
}

fn cpHit(n: *Node, x: f32, y: f32) bool {
    const s = stateOf(n);
    // SV square, hue slider, or hex field.
    if (s.sv_rect.contains(x, y)) return true;
    if (s.hue_rect.contains(x, y)) return true;
    if (s.hex_rect.contains(x, y)) return true;
    return n.bounds.contains(x, y);
}

// --- Input handlers ---

fn cpPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!n.visible) return false;

    switch (ev.phase) {
        .down => {
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            // Hex field click.
            if (s.hex_rect.contains(ev.x, ev.y)) {
                s.focus = .hex;
                s.hex_dirty = false;
                _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                input.requestFocus(n);
                n.markDirty();
                return true;
            }
            // SV or hue.
            const zone = zoneAt(s, ev.x, ev.y);
            if (zone != .none) {
                s.dragging = zone;
                s.focus = if (zone == .sv) .sv else .hue;
                input.requestFocus(n);
                applyDrag(s, n, ev.x, ev.y);
                n.markDirty();
                return true;
            }
            // Click on panel background: blur hex.
            if (s.focus == .hex) {
                s.focus = .none;
                s.hex_dirty = false;
                _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                n.markDirty();
            }
            return false;
        },
        .move => {
            if (s.dragging != .none) {
                // Drag past slop = cancel (scroll).
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (s.dragging == .none or @sqrt(dx * dx + dy * dy) > gestures.SLOP) {
                    applyDrag(s, n, ev.x, ev.y);
                }
                return true;
            }
            // Hover.
            const zone = zoneAt(s, ev.x, ev.y);
            if (zone != s.hovered) {
                s.hovered = zone;
                n.markDirty();
            }
            return zone != .none;
        },
        .up => {
            if (s.dragging != .none) {
                s.dragging = .none;
                n.markDirty();
                return true;
            }
            return false;
        },
        .outside_down => {
            if (s.dragging != .none) {
                s.dragging = .none;
                n.markDirty();
                return true;
            }
            if (s.focus == .hex) {
                s.focus = .none;
                s.hex_dirty = false;
                _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                n.markDirty();
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn applyDrag(s: *CPState, n: *Node, x: f32, y: f32) void {
    switch (s.dragging) {
        .none => {},
        .sv => {
            const sv = s.sv_rect;
            s.s = std.math.clamp((x - sv.x) / sv.w, 0, 1);
            s.v = std.math.clamp(1 - (y - sv.y) / sv.h, 0, 1);
            pushColor(s, n);
        },
        .hue => {
            const hue = s.hue_rect;
            s.h = std.math.clamp((x - hue.x) / hue.w, 0, 1) * 360;
            pushColor(s, n);
        },
    }
}

fn cpKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);

    // Text input (hex field editing).
    if (ev.kind == .text_input and s.focus == .hex) {
        for (ev.text) |ch| {
            const upper = switch (ch) {
                'a'...'f' => ch - 'a' + 'A',
                else => ch,
            };
            if ((upper >= '0' and upper <= '9') or (upper >= 'A' and upper <= 'F')) {
                if (!s.hex_dirty) {
                    _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                    s.hex_dirty = true;
                    // Clear to "#000000".
                    s.hex_buf = .{ '#', '0', '0', '0', '0', '0', '0', 0 };
                }
                // Shift into the buffer (positions 1..6).
                var i: usize = 6;
                while (i > 1) : (i -= 1) {
                    s.hex_buf[i] = s.hex_buf[i - 1];
                }
                s.hex_buf[1] = upper;
                n.markDirty();
            }
        }
        return ev.text.len > 0;
    }

    if (ev.kind != .key_down) return false;

    // Hex field special keys.
    if (s.focus == .hex) {
        switch (ev.key) {
            .enter => {
                if (hexToColor(s.hex_buf[0..7])) |c| {
                    applyExternalColor(s, n, c);
                    if (s.sig) |sig| sig.set(c);
                    if (s.on_change) |cb| cb.fn_ptr(cb.userdata);
                } else {
                    // Invalid: revert.
                    _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                }
                s.hex_dirty = false;
                s.focus = .none;
                n.markDirty();
                return true;
            },
            .escape, .back => {
                s.hex_dirty = false;
                _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                s.focus = .none;
                n.markDirty();
                return true;
            },
            .backspace => {
                if (!s.hex_dirty) {
                    _ = colorToHex(hsvToColor(s.h, s.s, s.v), &s.hex_buf);
                    s.hex_dirty = true;
                }
                // Shift out the last hex digit.
                var i: usize = 1;
                while (i < 6) : (i += 1) {
                    s.hex_buf[i] = s.hex_buf[i + 1];
                }
                s.hex_buf[6] = '0';
                n.markDirty();
                return true;
            },
            else => return false,
        }
    }

    // SV / Hue keyboard.
    switch (ev.key) {
        .left => {
            if (s.focus == .sv) {
                s.s = std.math.clamp(s.s - 0.05, 0, 1);
                pushColor(s, n);
            } else if (s.focus == .hue) {
                s.h = @mod(s.h - 5 + 360, 360);
                pushColor(s, n);
            } else return false;
            return true;
        },
        .right => {
            if (s.focus == .sv) {
                s.s = std.math.clamp(s.s + 0.05, 0, 1);
                pushColor(s, n);
            } else if (s.focus == .hue) {
                s.h = @mod(s.h + 5, 360);
                pushColor(s, n);
            } else return false;
            return true;
        },
        .up => {
            if (s.focus == .sv) {
                s.v = std.math.clamp(s.v + 0.05, 0, 1);
                pushColor(s, n);
            } else return false;
            return true;
        },
        .down => {
            if (s.focus == .sv) {
                s.v = std.math.clamp(s.v - 0.05, 0, 1);
                pushColor(s, n);
            } else return false;
            return true;
        },
        else => return false,
    }
}

// --- Deinit ---

fn cpDeinit(n: *Node) void {
    const s = stateOf(n);
    // Unsubscribe from the signal before destroying the state.
    if (s.sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = cpSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

// --- Focus change ---

// --- Factory ---

const cp_vtable = ui.node.VTable{
    .measure = cpMeasure,
    .layout = cpLayout,
    .paint = cpPaint,
    .on_pointer = cpPointer,
    .on_key = cpKey,
    .deinit = cpDeinit,
};

/// Create an M3E color picker panel.
///
/// `sig` — a live Signal(Color) (0xRRGGBBAA, alpha forced to 0xFF). The
/// picker syncs its internal HSV from the signal and writes back on change.
/// `on_change` — fired after every color change.
/// `opts` — panel options (width, theme).
pub fn colorPicker(
    allocator: std.mem.Allocator,
    sig: ?*ui.state.Signal(Color),
    on_change: ?Callback,
    opts: ColorPickerOptions,
) !*Node {
    const node = try Node.create(allocator, &cp_vtable);
    errdefer node.allocator.destroy(node);
    const s = try allocator.create(CPState);
    errdefer allocator.destroy(s);

    const initial: Color = if (sig) |sg| sg.peek() else 0xFF0000FF;
    const hsv = colorToHsv(initial);

    s.* = .{
        .opts = opts,
        .sig = sig,
        .on_change = on_change,
        .h = hsv.h,
        .s = hsv.s,
        .v = hsv.v,
    };
    _ = colorToHex(initial, &s.hex_buf);

    node.state = @ptrCast(s);

    // Subscribe to external signal changes (the app moved the color).
    if (sig) |sg| {
        sg.subscribe(.{ .callback = .{ .fn_ptr = cpSyncCb, .userdata = node } });
    }

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Color picker",
        .value = s.hex_buf[0..7],
        .focusable = true,
    });

    return node;
}

/// The signal -> widget sync (the app moved the color externally).
fn cpSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.sig) |sig| {
        applyExternalColor(s, n, sig.peek());
        ui.semantics.notifyControlChanged(n);
    }
}

// --- Accessors (for tests + registry) ---

pub fn currentColor(n: *Node) Color {
    const s = stateOf(n);
    return hsvToColor(s.h, s.s, s.v);
}

pub fn currentHex(n: *Node) [:0]const u8 {
    const s = stateOf(n);
    return s.hex_buf[0..7 :0];
}

// --- Tests ---

test "color helpers: rgbToHsv / hsvToRgb round-trip" {
    // Red.
    const hsv_red = rgbToHsv(255, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv_red.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv_red.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv_red.v, 0.01);
    const rgb_red = hsvToRgb(hsv_red.h, hsv_red.s, hsv_red.v);
    try std.testing.expectEqual(@as(u8, 255), rgb_red.r);
    try std.testing.expectEqual(@as(u8, 0), rgb_red.g);
    try std.testing.expectEqual(@as(u8, 0), rgb_red.b);

    // Green.
    const hsv_green = rgbToHsv(0, 255, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 120), hsv_green.h, 0.01);
    const rgb_green = hsvToRgb(hsv_green.h, hsv_green.s, hsv_green.v);
    try std.testing.expectEqual(@as(u8, 0), rgb_green.r);
    try std.testing.expectEqual(@as(u8, 255), rgb_green.g);
    try std.testing.expectEqual(@as(u8, 0), rgb_green.b);

    // Blue.
    const hsv_blue = rgbToHsv(0, 0, 255);
    try std.testing.expectApproxEqAbs(@as(f32, 240), hsv_blue.h, 0.01);
    const rgb_blue = hsvToRgb(hsv_blue.h, hsv_blue.s, hsv_blue.v);
    try std.testing.expectEqual(@as(u8, 0), rgb_blue.r);
    try std.testing.expectEqual(@as(u8, 0), rgb_blue.g);
    try std.testing.expectEqual(@as(u8, 255), rgb_blue.b);

    // Gray (s=0, h undefined but stable).
    const hsv_gray = rgbToHsv(128, 128, 128);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv_gray.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), hsv_gray.v, 0.01);
}

test "color helpers: colorToHex / hexToColor round-trip" {
    var buf: [8]u8 = undefined;
    // Red.
    const hex_red = colorToHex(0xFF0000FF, &buf);
    try std.testing.expectEqualStrings("#FF0000", hex_red);
    try std.testing.expectEqual(@as(Color, 0xFF0000FF), hexToColor(hex_red).?);
    // With alpha ignored (forced to 0xFF).
    try std.testing.expectEqual(@as(Color, 0x00FF00FF), hexToColor("#00FF00").?);
    // Lowercase.
    try std.testing.expectEqual(@as(Color, 0xAABBCCFF), hexToColor("#aabbcc").?);
    // Without '#'.
    try std.testing.expectEqual(@as(Color, 0xAABBCCFF), hexToColor("aabbcc").?);
    // Invalid.
    try std.testing.expect(hexToColor("#FFF") == null);
    try std.testing.expect(hexToColor("#GGGGGG") == null);
    try std.testing.expect(hexToColor("") == null);
}

test "color helpers: colorToHsv / hsvToColor round-trip" {
    const c = 0x3F51B5FF; // Indigo.
    const hsv = colorToHsv(c);
    const c2 = hsvToColor(hsv.h, hsv.s, hsv.v);
    // Allow ±1 per channel (rounding).
    const r1 = (c >> 24) & 0xFF;
    const g1 = (c >> 16) & 0xFF;
    const b1 = (c >> 8) & 0xFF;
    const r2 = (c2 >> 24) & 0xFF;
    const g2 = (c2 >> 16) & 0xFF;
    const b2 = (c2 >> 8) & 0xFF;
    try std.testing.expect(@abs(@as(i16, @intCast(r1)) - @as(i16, @intCast(r2))) <= 1);
    try std.testing.expect(@abs(@as(i16, @intCast(g1)) - @as(i16, @intCast(g2))) <= 1);
    try std.testing.expect(@abs(@as(i16, @intCast(b1)) - @as(i16, @intCast(b2))) <= 1);
    try std.testing.expectEqual(@as(Color, 0xFF), c2 & 0xFF);
}

test "color_picker: measure returns 320×344" {
    const a = std.testing.allocator;
    const n = try colorPicker(a, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@as(f32, 320), sz.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 344), sz.h, 0.001);
}

test "color_picker: SV drag updates the color (signal + on_change)" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = changeCounterCb, .userdata = &count };
    const sig = try ui.state.Signal(Color).init(std.testing.allocator, 0xFF0000FF);
    defer sig.deinit();
    const a = std.testing.allocator;
    const n = try colorPicker(a, sig, cb, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 320, .h = 344 });

    const s = stateOf(n);
    // Initial: red (h=0, s=1, v=1).
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.v, 0.01);

    // Drag to center of SV square: s=0.5, v=0.5.
    const sv = s.sv_rect;
    const cx = sv.x + sv.w / 2;
    const cy = sv.y + sv.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
    try std.testing.expect(s.dragging == .sv);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.v, 0.01);
    try std.testing.expectEqual(@as(u32, 1), count);
    // The signal round-trips.
    const c = sig.peek();
    try std.testing.expectEqual(@as(Color, 0xFF), c & 0xFF); // alpha
    // h=0, s=0.5, v=0.5 -> r=127, g=63, b=63 approx.
    const r = (c >> 24) & 0xFF;
    try std.testing.expect(r >= 120 and r <= 135);

    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
    try std.testing.expect(s.dragging == .none);
}

test "color_picker: hue drag updates the hue" {
    const sig = try ui.state.Signal(Color).init(std.testing.allocator, 0xFF0000FF);
    defer sig.deinit();
    const a = std.testing.allocator;
    const n = try colorPicker(a, sig, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 320, .h = 344 });

    const s = stateOf(n);
    const hue = s.hue_rect;
    // Drag to 50% of the hue bar: h = 180 (cyan).
    const hx = hue.x + hue.w / 2;
    const hy = hue.y + hue.h / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = hx, .y = hy, .raw_x = hx, .raw_y = hy });
    try std.testing.expect(s.dragging == .hue);
    try std.testing.expectApproxEqAbs(@as(f32, 180), s.h, 1);
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = hx, .y = hy, .raw_x = hx, .raw_y = hy });

    // The color should be cyan-ish.
    const c = sig.peek();
    const g = (c >> 16) & 0xFF;
    const b = (c >> 8) & 0xFF;
    try std.testing.expect(g > 200);
    try std.testing.expect(b > 200);
}

test "color_picker: keyboard arrows adjust SV" {
    const sig = try ui.state.Signal(Color).init(std.testing.allocator, 0xFF0000FF);
    defer sig.deinit();
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const n = try colorPicker(a, sig, null, .{});
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 320, .h = 344 });

    const s = stateOf(n);
    // Focus SV.
    s.focus = .sv;
    input.requestFocus(n);

    // Initial: s=1, v=1. Left arrow: s -= 0.05.
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .left });
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), s.s, 0.01);
    // Down arrow: v -= 0.05.
    _ = n.vtable.on_key.?(n, .{ .kind = .key_down, .key = .down });
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), s.v, 0.01);
}

test "color_picker: semantics — role group, focusable, value = hex" {
    const a = std.testing.allocator;
    const n = try colorPicker(a, null, null, .{});
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.group, n.semantics.?.role);
    try std.testing.expect(n.semantics.?.focusable);
    try std.testing.expectEqualStrings("#FF0000", n.semantics.?.value);
}

test "golden: the panel paints SurfaceContainerHigh; the SV square paints the hue base at top-left" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try colorPicker(a, null, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 360, 380);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 320, .h = 344 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(n);
    // Panel background at a corner inside the panel (past the corner radius).
    try std.testing.expectEqual(t.colors.surface_container_high, f.pixelAt(30, 30));
    // SV square top-left corner (s=1, v=1 -> pure red, h=0).
    // The top-left of the SV square is at (40, 40) in window coords.
    // At s=1 (right), v=1 (top): pure hue. At top-left (s=0, v=1): white.
    // Check the center-top (s=0.5, v=1): a light red.
    const sv = s.sv_rect;
    const mid_top_x = @as(i32, @intFromFloat(sv.x + sv.w / 2));
    const top_y = @as(i32, @intFromFloat(sv.y + 2));
    const px = f.pixelAt(mid_top_x, top_y);
    // Should be a light red/pink (red + 50% white).
    const pr = (px >> 24) & 0xFF;
    const pg = (px >> 16) & 0xFF;
    const pb = (px >> 8) & 0xFF;
    try std.testing.expect(pr > 200); // high red
    try std.testing.expect(pg > 100 and pg < 200); // mid green (white overlay)
    try std.testing.expect(pb > 100 and pb < 200); // mid blue
}

test "golden: the preview swatch paints the selected color" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(Color).init(a, 0x3F51B5FF); // Indigo.
    defer sig.deinit();
    const n = try colorPicker(a, sig, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 360, 380);
    defer r.deinit();
    n.layout(.{ .x = 20, .y = 20, .w = 320, .h = 344 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    const s = stateOf(n);
    // The swatch center should be the indigo color.
    const sw = s.swatch_rect;
    const cx = @as(i32, @intFromFloat(sw.x + sw.w / 2));
    const cy = @as(i32, @intFromFloat(sw.y + sw.h / 2));
    const px = f.pixelAt(cx, cy);
    // Allow ±2 per channel (anti-aliasing at the edges, but center should be exact).
    const er = (px >> 24) & 0xFF;
    const eg = (px >> 16) & 0xFF;
    const eb = (px >> 8) & 0xFF;
    try std.testing.expect(@abs(@as(i16, @intCast(er)) - 0x3F) <= 2);
    try std.testing.expect(@abs(@as(i16, @intCast(eg)) - 0x51) <= 2);
    try std.testing.expect(@abs(@as(i16, @intCast(eb)) - 0xB5) <= 2);
}

// --- Test helpers ---

fn changeCounterCb(userdata: ?*anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(userdata.?));
    count.* += 1;
}
