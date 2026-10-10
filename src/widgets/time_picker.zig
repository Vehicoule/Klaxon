// M3E time picker (Phase 2d.4 PR #33) — the analog (dial) variant, ported
// from Compose material3 TimePicker.kt + TimePickerTokens.kt
// (/tmp/m3compose2/d3-TimePicker.kt, d3-TimePickerTokens.kt) + the M3E spec
// (m3.material.io/components/time-pickers) + the m3e-canvas visual reference.
//
// Tokens (TimePickerTokens):
//   - container: SurfaceContainerHigh, CornerExtraLarge (28dp), 360dp wide
//   - header (a centered row): the hour plate + the ":" separator + the
//     minute plate + the AM/PM period toggle (12h only)
//     - plates: 96x80, CornerSmall (8dp); the ACTIVE plate (the dial's mode):
//       PrimaryContainer fill + OnPrimaryContainer label + a 2dp Primary
//       border; the inactive plate: SurfaceContainerHighest + OnSurface
//     - labels: DisplayLarge, zero-padded 2 digits
//     - separator: 24dp wide, DisplayLarge, OnSurface
//     - period toggle: 52x80, CornerSmall, a 1dp Outline border + a 1dp
//       Outline divider between the halves; the selected half:
//       TertiaryContainer + OnTertiaryContainer; unselected: transparent +
//       OnSurfaceVariant; labels TitleMedium
//   - dial: 256dp circle, SurfaceContainerHighest, CornerFull
//     - labels on a 101dp ring (OuterCircleToSizeRatio = 101/256), 48dp
//       cells, BodyLarge; hour screen: 12, 1..11 (12 at the top); minute
//       screen: 00, 05..55 (every 5th minute)
//     - the 24h hour screen is a dual-ring dial: 00..11 on the outer ring
//       (101dp) + 12..23 on the inner circle (69dp, InnerCircleToSizeRatio);
//       the tap's radius picks the ring (MaxDistance = 74dp: >= 74 → the
//       outer 0..11, closer → the inner 12..23)
//     - the selector: a 48dp Primary circle (CornerFull) at the selected
//       position (on the selected hour's ring) + the selected label OnPrimary
//       (drawn on top of the knob); the track: a 2dp Primary line from the
//       center to the knob's near edge; the center: an 8dp Primary circle
//   - footer: Cancel / OK text buttons (same as the date picker)
//
// State: `time` is a two-way Signal(i32) of minutes since midnight (clamped
// to 0..1439). Tapping the hour/minute plate switches the dial's mode; tapping
// the dial (or dragging) selects by angle (hours snap to the nearest hour,
// minutes to the nearest minute; in 24h the tap's radius picks the ring);
// tapping AM/PM flips the period (12h). OK fires on_select, Cancel on_cancel.
//
// v1 deviations (documented, fixed later):
//   - No text-input variant, no auto-switch hour→minute after a selection.
//   - en strings only ("AM"/"PM", Cancel/OK).
//   - No per-label hover on the dial; no keyboard navigation yet.
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
const Theme = theme_mod.Theme;

pub const TimePickerOptions = struct {
    theme: Theme = theme_mod.light,
    /// The panel width.
    width: f32 = 360,
    /// 24-hour mode: no AM/PM toggle, the hour plate shows 00..23.
    is_24h: bool = false,
};

pub const DialMode = enum { hour, minute };

/// M3E measurement tokens (TimePickerTokens + the private vals).
const container_corner: f32 = 28; // CornerExtraLarge
const plate_w: f32 = 96; // TimeSelectorContainerWidth
const plate_h: f32 = 80; // TimeSelectorContainerHeight
const plate_corner: f32 = 8; // CornerSmall
const plate_border: f32 = 2; // the selected plate's Primary border
const sep_w: f32 = 24; // DisplaySeparatorWidth
const period_w: f32 = 52; // PeriodSelectorVerticalContainerWidth
const period_h: f32 = 80; // PeriodSelectorVerticalContainerHeight
const period_gap: f32 = 4; // PeriodTogglePaddingSmall
const dial_size: f32 = 256; // ClockDialContainerSize
const label_ring: f32 = 101; // OuterCircleToSizeRatio × 256
const inner_label_ring: f32 = 69; // InnerCircleToSizeRatio × 256 (the 24h dial's inner circle)
const max_tap_dist: f32 = 74; // MaxDistance (the 24h ring threshold)
const label_cell: f32 = 48; // MinimumInteractiveSize
const knob_d: f32 = 48; // ClockDialSelectorHandleContainerSize
const track_w: f32 = 2; // ClockDialSelectorTrackContainerWidth
const center_d: f32 = 8; // ClockDialSelectorCenterContainerSize
const header_top: f32 = 16;
const header_h: f32 = 80; // the plates' height
const display_gap: f32 = 36; // ClockDisplayBottomMargin
const face_gap: f32 = 24; // ClockFaceBottomMargin
const footer_h: f32 = 40;
const footer_pad_bottom: f32 = 12;
const footer_gap: f32 = 8;
const footer_pad_x: f32 = 12; // the text button's horizontal padding

/// Derived layout metrics.
const dial_y_off: f32 = header_top + header_h + display_gap; // 132
const footer_y_off: f32 = dial_y_off + dial_size + face_gap; // 412
const total_h: f32 = footer_y_off + footer_h + footer_pad_bottom; // 464
/// The header row's width (12h: plates + separator + period toggle).
const header_row_w_12h: f32 = plate_w + sep_w + plate_w + period_gap + period_w; // 272

/// The hour screen values (12 at the top, then 1..11 clockwise).
const hour_values = [_]i32{ 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

// --- time math (minutes since midnight) ---

fn clampedTime(t: i32) i32 {
    return std.math.clamp(t, 0, 1439);
}

fn hour24Of(t: i32) i32 {
    return @divTrunc(clampedTime(t), 60);
}

fn minuteOf(t: i32) i32 {
    return @mod(clampedTime(t), 60);
}

fn hour12Of(t: i32) i32 {
    const h = @mod(hour24Of(t), 12);
    return if (h == 0) 12 else h;
}

fn isPm(t: i32) bool {
    return hour24Of(t) >= 12;
}

/// The dial's value for the current mode (hour12 in 12h hour mode, 0..23 in
/// 24h hour mode, minute in minute mode).
fn dialValue(t: i32, mode: DialMode, is_24h: bool) i32 {
    if (mode == .hour) return if (is_24h) hour24Of(t) else hour12Of(t);
    return minuteOf(t);
}

/// The angle (degrees, standard math: -90 at the top, clockwise) of a dial
/// value. 12h hours are 1..12; 24h hours are 0..23 (the position's 12h base).
fn valueAngle(value: i32, mode: DialMode, is_24h: bool) f32 {
    if (mode == .hour) {
        const base12: i32 = if (is_24h) @mod(value, 12) else value;
        const v12: i32 = if (base12 == 0) 12 else base12;
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            if (hour_values[i] == v12) break;
        }
        return @as(f32, @floatFromInt(i)) * 30 - 90;
    }
    return @as(f32, @floatFromInt(value)) * 6 - 90;
}

/// The ring radius of a dial value's selector knob (the 24h dial's 12..23
/// hours sit on the inner circle).
fn selectorRing(value: i32, mode: DialMode, is_24h: bool) f32 {
    if (mode == .hour and is_24h and value >= 12) return inner_label_ring;
    return label_ring;
}

/// The dial value at a pointer position (the nearest hour / minute). In 24h
/// hour mode the tap's radius picks the ring: >= MaxDistance → the outer
/// circle (0..11), closer → the inner circle (12..23).
fn valueAtAngle(cx: f32, cy: f32, x: f32, y: f32, mode: DialMode, is_24h: bool) i32 {
    var deg = std.math.atan2(y - cy, x - cx) * 180 / std.math.pi + 90;
    deg = @mod(deg, 360);
    if (mode == .hour) {
        const i = @as(usize, @intFromFloat(@round(deg / 30))) % 12;
        if (is_24h) {
            const base = @mod(hour_values[i], 12); // 0..11
            const dist = std.math.hypot(x - cx, y - cy);
            return if (dist >= max_tap_dist) base else base + 12;
        }
        return hour_values[i];
    }
    return @mod(@as(i32, @intFromFloat(@round(deg / 6))), 60);
}

/// Apply a dial selection to the time signal (mode-dependent).
fn applyDialValue(s: *TpState, value: i32) void {
    const t = clampedTime(s.time.peek());
    if (s.mode == .hour) {
        if (s.opts.is_24h) {
            s.time.set(std.math.clamp(value, 0, 23) * 60 + minuteOf(t));
        } else {
            const hour12 = std.math.clamp(value, 1, 12);
            const h24: i32 = if (isPm(t)) @mod(hour12, 12) + 12 else @mod(hour12, 12);
            s.time.set(h24 * 60 + minuteOf(t));
        }
    } else {
        s.time.set(hour24Of(t) * 60 + std.math.clamp(value, 0, 59));
    }
}

// --- widget state ---

const Zone = union(enum) {
    none,
    hour_plate,
    minute_plate,
    am,
    pm,
    dial,
    cancel,
    ok,
};

const TpState = struct {
    opts: TimePickerOptions,
    time: *ui.state.Signal(i32),
    on_select: ?ui.state.Callback,
    on_cancel: ?ui.state.Callback,
    mode: DialMode = .hour,
    hover: Zone = .none,
    pressed: Zone = .none,
    dragging: bool = false, // the dial owns the pointer
    down_x: f32 = 0,
    down_y: f32 = 0,
    /// The a11y value (the formatted time) — Phase 2c.
    value_buf: [24]u8 = std.mem.zeroes([24]u8),
    value_len: usize = 0,
};

fn stateOf(n: *Node) *TpState {
    return @ptrCast(@alignCast(n.state.?));
}

/// The dial's mode (hour/minute) — tests + the app.
pub fn dialMode(n: *Node) DialMode {
    return stateOf(n).mode;
}

/// The current time (minutes since midnight, clamped) — tests + the app.
pub fn timeMinutes(n: *Node) i32 {
    return clampedTime(stateOf(n).time.peek());
}

/// The dial's rect — tests + the app.
pub fn dialRectOf(n: *Node) Rect {
    return dialRect(n.bounds);
}

// --- geometry ---

fn headerRowX(b: Rect, is_24h: bool) f32 {
    const row_w: f32 = if (is_24h) plate_w + sep_w + plate_w else header_row_w_12h;
    return b.x + (b.w - row_w) / 2;
}

fn plateRect(b: Rect, which: DialMode, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    const x = if (which == .hour) row_x else row_x + plate_w + sep_w;
    return .{ .x = x, .y = b.y + header_top, .w = plate_w, .h = plate_h };
}

fn separatorRect(b: Rect, is_24h: bool) Rect {
    const row_x = headerRowX(b, is_24h);
    return .{ .x = row_x + plate_w, .y = b.y + header_top, .w = sep_w, .h = plate_h };
}

fn periodRect(b: Rect) Rect {
    const row_x = headerRowX(b, false);
    return .{ .x = row_x + 2 * plate_w + sep_w + period_gap, .y = b.y + header_top, .w = period_w, .h = period_h };
}

fn dialRect(b: Rect) Rect {
    return .{ .x = b.x + (b.w - dial_size) / 2, .y = b.y + dial_y_off, .w = dial_size, .h = dial_size };
}

const FooterRects = struct { cancel: Rect, ok: Rect };

fn footerRects(n: *Node) FooterRects {
    const s = stateOf(n);
    const ls = s.opts.theme.type_scale.label_large;
    const bold = ls.weight >= 500;
    const ok_m = ui.paint.measureText("OK", ls.size, bold);
    const cancel_m = ui.paint.measureText("Cancel", ls.size, bold);
    const ok_w = ok_m.width + 2 * footer_pad_x;
    const cancel_w = cancel_m.width + 2 * footer_pad_x;
    const right = n.bounds.x + n.bounds.w - footer_pad_bottom;
    const y = n.bounds.y + footer_y_off;
    return .{
        .cancel = .{ .x = right - ok_w - footer_gap - cancel_w, .y = y, .w = cancel_w, .h = footer_h },
        .ok = .{ .x = right - ok_w, .y = y, .w = ok_w, .h = footer_h },
    };
}

/// The interactive zone at (x, y) — window coordinates.
fn zoneAt(n: *Node, x: f32, y: f32) Zone {
    const s = stateOf(n);
    const b = n.bounds;
    const fr = footerRects(n);
    if (fr.cancel.contains(x, y)) return .cancel;
    if (fr.ok.contains(x, y)) return .ok;
    if (plateRect(b, .hour, s.opts.is_24h).contains(x, y)) return .hour_plate;
    if (plateRect(b, .minute, s.opts.is_24h).contains(x, y)) return .minute_plate;
    if (!s.opts.is_24h) {
        const pr = periodRect(b);
        if (pr.contains(x, y)) return if (y < pr.y + pr.h / 2) .am else .pm;
    }
    const d = dialRect(b);
    if (d.contains(x, y)) {
        const cx = d.x + d.w / 2;
        const cy = d.y + d.h / 2;
        const dx = x - cx;
        const dy = y - cy;
        if (dx * dx + dy * dy <= (d.w / 2) * (d.w / 2)) return .dial;
    }
    return .none;
}

// --- measure / layout / paint ---

fn tpMeasure(n: *Node, c: Constraints) Size {
    const w = stateOf(n).opts.width;
    return c.constrain(.{ .w = w, .h = total_h });
}

fn tpLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: the chrome is computed from the bounds at paint/hit
}

fn paintTextButton(n: *Node, ctx: *kx.Ctx, r: Rect, label: [:0]const u8, zone: Zone) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, r.h / 2, theme_mod.stateLayer(0, t.colors.primary, alpha));
    }
    const ls = t.type_scale.label_large;
    const bold = ls.weight >= 500;
    const m = ui.paint.measureText(label, ls.size, bold);
    ui.paint.text(ctx, label, r.x + (r.w - m.width) / 2, r.y + (r.h - m.height) / 2 + m.ascent, ls.size, bold, t.colors.primary);
}

/// A time plate (96x80, CornerSmall): the active mode gets the
/// PrimaryContainer fill + the 2dp Primary border + OnPrimaryContainer.
fn paintPlate(n: *Node, ctx: *kx.Ctx, r: Rect, label: [:0]const u8, active: bool, zone: Zone) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const fill: Color = if (active) cs.primary_container else cs.surface_container_highest;
    const fg: Color = if (active) cs.on_primary_container else cs.on_surface;
    ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, fill);
    const hover = std.meta.eql(s.hover, zone);
    const pressed = std.meta.eql(s.pressed, zone);
    if (hover or pressed) {
        const alpha = if (pressed) t.state.pressed else t.state.hover;
        ui.paint.fillRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, theme_mod.stateLayer(fill, fg, alpha));
    }
    if (active) ui.paint.strokeRRect(ctx, r.x, r.y, r.w, r.h, plate_corner, plate_border, cs.primary);
    const dl = t.type_scale.display_large;
    const m = ui.paint.measureText(label, dl.size, dl.weight >= 500);
    ui.paint.text(ctx, label, r.x + (r.w - m.width) / 2, r.y + (r.h - m.height) / 2 + m.ascent, dl.size, dl.weight >= 500, fg);
}

fn tpPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const cs = t.colors;
    const b = n.bounds;
    const tm = clampedTime(s.time.peek());
    // the container
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, container_corner, cs.surface_container_high);
    // the header: the hour plate, the separator, the minute plate, the toggle
    var hbuf: [4]u8 = undefined;
    var mbuf: [4]u8 = undefined;
    const hour_v = if (s.opts.is_24h) hour24Of(tm) else hour12Of(tm);
    // The clock fields are euclidean (always >= 0) — cast to unsigned: Zig
    // 0.17 pads signed ints with an explicit sign.
    const hour_lbl = std.fmt.bufPrintSentinel(&hbuf, "{d:0>2}", .{@as(u32, @intCast(hour_v))}, 0) catch "?";
    const minute_lbl = std.fmt.bufPrintSentinel(&mbuf, "{d:0>2}", .{@as(u32, @intCast(minuteOf(tm)))}, 0) catch "?";
    paintPlate(n, ctx, plateRect(b, .hour, s.opts.is_24h), hour_lbl, s.mode == .hour, .hour_plate);
    paintPlate(n, ctx, plateRect(b, .minute, s.opts.is_24h), minute_lbl, s.mode == .minute, .minute_plate);
    const dl = t.type_scale.display_large;
    const sep = separatorRect(b, s.opts.is_24h);
    const sep_m = ui.paint.measureText(":", dl.size, dl.weight >= 500);
    ui.paint.text(ctx, ":", sep.x + (sep.w - sep_m.width) / 2, sep.y + (sep.h - sep_m.height) / 2 + sep_m.ascent, dl.size, dl.weight >= 500, cs.on_surface);
    if (!s.opts.is_24h) {
        // the AM/PM period toggle: a 1dp Outline border + divider, the
        // selected half TertiaryContainer
        const pr = periodRect(b);
        ui.paint.strokeRRect(ctx, pr.x, pr.y, pr.w, pr.h, plate_corner, 1, cs.outline);
        const half_h = pr.h / 2;
        const pm = isPm(tm);
        const halves = [_]struct { zone: Zone, label: [:0]const u8, selected: bool, y: f32 }{
            .{ .zone = .am, .label = "AM", .selected = !pm, .y = pr.y },
            .{ .zone = .pm, .label = "PM", .selected = pm, .y = pr.y + half_h },
        };
        for (halves) |h| {
            // the half's corners: the toggle's rounded side only (AM = top,
            // PM = bottom)
            const tl: f32 = if (h.zone == .am) plate_corner else 0;
            const tr: f32 = tl;
            const br: f32 = if (h.zone == .pm) plate_corner else 0;
            const bl: f32 = br;
            if (h.selected) {
                ui.paint.fillRRectCorners(ctx, pr.x, h.y, pr.w, half_h, tl, tr, br, bl, cs.tertiary_container);
            }
            const hover = std.meta.eql(s.hover, h.zone);
            const pressed = std.meta.eql(s.pressed, h.zone);
            if (hover or pressed) {
                const alpha = if (pressed) t.state.pressed else t.state.hover;
                const on: Color = if (h.selected) cs.on_tertiary_container else cs.on_surface_variant;
                ui.paint.fillRRectCorners(ctx, pr.x, h.y, pr.w, half_h, tl, tr, br, bl, theme_mod.stateLayer(0, on, alpha));
            }
            const tm_style = t.type_scale.title_medium;
            const bold = tm_style.weight >= 500;
            const m = ui.paint.measureText(h.label, tm_style.size, bold);
            const fg: Color = if (h.selected) cs.on_tertiary_container else cs.on_surface_variant;
            ui.paint.text(ctx, h.label, pr.x + (pr.w - m.width) / 2, h.y + (half_h - m.height) / 2 + m.ascent, tm_style.size, bold, fg);
        }
        // the 1dp divider between the halves
        ui.paint.fillRect(ctx, pr.x, pr.y + half_h - 0.5, pr.w, 1, cs.outline);
    }
    // the dial
    const d = dialRect(b);
    const cx = d.x + d.w / 2;
    const cy = d.y + d.h / 2;
    ui.paint.fillRRect(ctx, d.x, d.y, d.w, d.h, dial_size / 2, cs.surface_container_highest);
    const bl = t.type_scale.body_large;
    const bl_bold = bl.weight >= 500;
    const is_24h = s.opts.is_24h and s.mode == .hour;
    const sel_val = dialValue(tm, s.mode, s.opts.is_24h);
    // the labels on the ring(s): the 24h hour dial has two rings — 00..11 on
    // the outer circle (101dp), 12..23 on the inner one (69dp). The selected
    // label is stashed and drawn AFTER the selector (on top of the knob).
    var sel_buf: [4]u8 = undefined;
    var sel_str: ?[:0]const u8 = null;
    var sel_x: f32 = 0;
    var sel_y: f32 = 0;
    var ring_index: usize = 0;
    while (ring_index < @as(usize, if (is_24h) 2 else 1)) : (ring_index += 1) {
        const ring: f32 = if (ring_index == 1) inner_label_ring else label_ring;
        for (0..12) |i| {
            const a = (@as(f32, @floatFromInt(i)) * 30 - 90) * std.math.pi / 180;
            const lx = cx + @cos(a) * ring;
            const ly = cy + @sin(a) * ring;
            const value: i32 = if (s.mode == .hour) blk: {
                if (is_24h) {
                    const base = @mod(hour_values[i], 12); // 0..11
                    break :blk if (ring_index == 1) base + 12 else base;
                }
                break :blk hour_values[i];
            } else @intCast(i * 5);
            var vbuf: [4]u8 = undefined;
            const vstr = if (s.mode == .hour and is_24h)
                std.fmt.bufPrintSentinel(&vbuf, "{d:0>2}", .{@as(u32, @intCast(value))}, 0) catch "?"
            else if (s.mode == .hour)
                std.fmt.bufPrintSentinel(&vbuf, "{d}", .{value}, 0) catch "?"
            else
                std.fmt.bufPrintSentinel(&vbuf, "{d:0>2}", .{@as(u32, @intCast(value))}, 0) catch "?";
            if (value == sel_val) {
                @memcpy(sel_buf[0..vstr.len], vstr[0..vstr.len]);
                sel_buf[vstr.len] = 0;
                sel_str = sel_buf[0..vstr.len :0];
                sel_x = lx;
                sel_y = ly;
                continue;
            }
            const m = ui.paint.measureText(vstr, bl.size, bl_bold);
            ui.paint.text(ctx, vstr, lx - m.width / 2, ly - m.height / 2 + m.ascent, bl.size, bl_bold, cs.on_surface);
        }
    }
    // the selector: the track + the knob + the center dot
    const sel_angle = valueAngle(sel_val, s.mode, s.opts.is_24h) * std.math.pi / 180;
    const sel_ring = selectorRing(sel_val, s.mode, s.opts.is_24h);
    const kx_ = cx + @cos(sel_angle) * sel_ring;
    const ky = cy + @sin(sel_angle) * sel_ring;
    const hand_end_r = sel_ring - knob_d / 2;
    var xs = [2]f32{ cx, cx + @cos(sel_angle) * hand_end_r };
    var ys = [2]f32{ cy, cy + @sin(sel_angle) * hand_end_r };
    ui.paint.strokePolyline(ctx, &xs, &ys, track_w, false, cs.primary);
    ui.paint.fillRRect(ctx, kx_ - knob_d / 2, ky - knob_d / 2, knob_d, knob_d, knob_d / 2, cs.primary);
    ui.paint.fillRRect(ctx, cx - center_d / 2, cy - center_d / 2, center_d, center_d, center_d / 2, cs.primary);
    // the selected label on top of the knob (OnPrimary)
    if (sel_str) |vstr| {
        const m = ui.paint.measureText(vstr, bl.size, bl_bold);
        ui.paint.text(ctx, vstr, sel_x - m.width / 2, sel_y - m.height / 2 + m.ascent, bl.size, bl_bold, cs.on_primary);
    }
    // the footer
    const fr = footerRects(n);
    paintTextButton(n, ctx, fr.cancel, "Cancel", .cancel);
    paintTextButton(n, ctx, fr.ok, "OK", .ok);
}

// --- input ---

fn tpOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    switch (ev.phase) {
        .down => {
            const z = zoneAt(n, ev.x, ev.y);
            if (std.meta.activeTag(z) == .none) return false;
            s.down_x = ev.raw_x;
            s.down_y = ev.raw_y;
            if (std.meta.activeTag(z) == .dial) {
                // the dial owns the drag: select by angle immediately
                s.dragging = true;
                const c = dialCenter(n);
                applyDialValue(s, valueAtAngle(c[0], c[1], ev.x, ev.y, s.mode, s.opts.is_24h));
                n.markDirty();
                return true;
            }
            s.pressed = z;
            n.markDirty();
            return true;
        },
        .move => {
            if (s.dragging) {
                const c = dialCenter(n);
                applyDialValue(s, valueAtAngle(c[0], c[1], ev.x, ev.y, s.mode, s.opts.is_24h));
                n.markDirty();
                return true; // the dial claims the move
            }
            if (std.meta.activeTag(s.pressed) != .none) {
                const dx = ev.raw_x - s.down_x;
                const dy = ev.raw_y - s.down_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.pressed = .none;
                    n.markDirty();
                }
            }
            return false;
        },
        .up => {
            if (s.dragging) {
                s.dragging = false;
                n.markDirty();
                return true;
            }
            const was = s.pressed;
            s.pressed = .none;
            n.markDirty();
            if (std.meta.activeTag(was) == .none) return false;
            if (!std.meta.eql(zoneAt(n, ev.x, ev.y), was)) return true; // released outside: no action
            activate(n, s, was);
            return true;
        },
        .outside_down => {
            if (std.meta.activeTag(s.pressed) != .none) {
                s.pressed = .none;
                n.markDirty();
            }
            return false;
        },
        .enter, .leave => {
            s.hover = zoneAt(n, ev.x, ev.y);
            n.markDirty();
            return true;
        },
        .hover_move => {
            const z = zoneAt(n, ev.x, ev.y);
            if (!std.meta.eql(z, s.hover)) {
                s.hover = z;
                n.markDirty();
            }
            return true;
        },
    }
}

fn dialCenter(n: *Node) struct { f32, f32 } {
    const d = dialRect(n.bounds);
    return .{ d.x + d.w / 2, d.y + d.h / 2 };
}

fn activate(n: *Node, s: *TpState, z: Zone) void {
    _ = n;
    switch (z) {
        .none, .dial => {},
        .hour_plate => s.mode = .hour,
        .minute_plate => s.mode = .minute,
        .am, .pm => {
            const t = clampedTime(s.time.peek());
            const h12 = hour12Of(t);
            const h24: i32 = if (z == .pm) @mod(h12, 12) + 12 else @mod(h12, 12);
            s.time.set(h24 * 60 + minuteOf(t));
        },
        .cancel => {
            if (s.on_cancel) |cb| cb.fn_ptr(cb.userdata);
        },
        .ok => {
            if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
        },
    }
}

// --- signals + a11y ---

fn tpSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    updateA11yValue(n);
    n.markDirty();
    ui.semantics.notifyControlChanged(n); // a11y: the value changed
}

/// "10:30 AM" (12h) / "22:30" (24h) — the a11y value + the gallery's time
/// label (pub for the gallery: it matches what the picker displays).
pub fn formatTime(t: i32, is_24h: bool, buf: []u8) [:0]const u8 {
    const h24: u32 = @intCast(hour24Of(t));
    const min: u32 = @intCast(minuteOf(t));
    if (is_24h) {
        return std.fmt.bufPrintSentinel(buf, "{d:0>2}:{d:0>2}", .{ h24, min }, 0) catch "?";
    }
    var b1: [4]u8 = undefined;
    var b2: [4]u8 = undefined;
    const h = std.fmt.bufPrintSentinel(&b1, "{d:0>2}", .{@as(u32, @intCast(hour12Of(t)))}, 0) catch "?";
    const m = std.fmt.bufPrintSentinel(&b2, "{d:0>2}", .{min}, 0) catch "?";
    return std.fmt.bufPrintSentinel(buf, "{s}:{s} {s}", .{ h, m, if (isPm(t)) "PM" else "AM" }, 0) catch "?";
}

fn updateA11yValue(n: *Node) void {
    const s = stateOf(n);
    const str = formatTime(clampedTime(s.time.peek()), s.opts.is_24h, &s.value_buf);
    s.value_len = str.len;
    if (n.semantics) |sem| sem.value = s.value_buf[0..s.value_len];
}

fn tpDeinit(n: *Node) void {
    const s = stateOf(n);
    s.time.unsubscribe(.{ .callback = .{ .fn_ptr = tpSyncCb, .userdata = n } });
    input.releaseNode(n);
    n.allocator.destroy(s);
}

const tp_vtable = ui.node.VTable{
    .measure = tpMeasure,
    .layout = tpLayout,
    .paint = tpPaint,
    .deinit = tpDeinit,
    .on_pointer = tpOnPointer,
};

/// An M3E time picker panel (the analog dial). `time` is a two-way
/// Signal(i32) of minutes since midnight (clamped to 0..1439). `on_select`
/// fires on OK, `on_cancel` on Cancel. The widget is a LEAF panel (it paints
/// all its chrome; the app wraps it in a dialog for modal behavior).
pub fn timePicker(allocator: std.mem.Allocator, time: *ui.state.Signal(i32), on_select: ?ui.state.Callback, on_cancel: ?ui.state.Callback, opts: TimePickerOptions) !*Node {
    const node = try Node.create(allocator, &tp_vtable);
    errdefer node.allocator.destroy(node); // no state yet
    const s = try allocator.create(TpState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .time = time, .on_select = on_select, .on_cancel = on_cancel };
    node.state = s;
    updateA11yValue(node);
    ui.semantics.attach(node, .{ .role = .group, .label = "Time picker", .value = s.value_buf[0..s.value_len] }); // Phase 2c
    time.subscribe(.{ .callback = .{ .fn_ptr = tpSyncCb, .userdata = node } });
    return node;
}

// --- tests ---

/// A picker at 10:30 (630 minutes).
fn tpFixture(a: std.mem.Allocator) !struct { *Node, *ui.state.Signal(i32) } {
    const t = try ui.state.Signal(i32).init(a, 630);
    errdefer t.deinit();
    const n = try timePicker(a, t, null, null, .{});
    errdefer n.deinit();
    return .{ n, t };
}

test "time_picker: the time math (12h display, period, clamping)" {
    try std.testing.expectEqual(@as(i32, 10), hour24Of(630));
    try std.testing.expectEqual(@as(i32, 30), minuteOf(630));
    try std.testing.expectEqual(@as(i32, 10), hour12Of(630));
    try std.testing.expect(!isPm(630));
    try std.testing.expect(isPm(720)); // 12:00 = noon = PM
    try std.testing.expectEqual(@as(i32, 12), hour12Of(720));
    try std.testing.expectEqual(@as(i32, 0), hour24Of(0)); // 12:00 AM
    try std.testing.expectEqual(@as(i32, 12), hour12Of(0));
    try std.testing.expectEqual(@as(i32, 23), hour24Of(1439));
    try std.testing.expectEqual(@as(i32, 1439), clampedTime(5000));
    try std.testing.expectEqual(@as(i32, 0), clampedTime(-5));
    // the dial angles: 12 at the top (-90°), 6 at the bottom (90°)
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(12, .hour, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(6, .hour, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(0, .minute, false), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(30, .minute, false), 0.01);
    // the angle → value round-trips
    try std.testing.expectEqual(@as(i32, 12), valueAtAngle(0, 0, 0, -101, .hour, false)); // the top = 12
    try std.testing.expectEqual(@as(i32, 6), valueAtAngle(0, 0, 0, 101, .hour, false)); // down = 6
    try std.testing.expectEqual(@as(i32, 30), valueAtAngle(0, 0, 0, 101, .minute, false)); // down = 30
    try std.testing.expectEqual(@as(i32, 0), valueAtAngle(0, 0, 0, -101, .minute, false)); // up = 00
    try std.testing.expectEqual(@as(i32, 15), valueAtAngle(0, 0, 101, 0, .minute, false)); // right = 15
    // the 24h dial: 00 and 12 share the top position, 18 sits at the bottom
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(0, .hour, true), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -90), valueAngle(12, .hour, true), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), valueAngle(18, .hour, true), 0.01);
    try std.testing.expectEqual(@as(i32, 15), dialValue(15 * 60 + 30, .hour, true));
    try std.testing.expectEqual(@as(i32, 10), dialValue(22 * 60 + 30, .hour, false)); // 12h keeps 10
    // the 24h ring selection: the outer ring (>= 74dp) → 0..11, the inner → 12..23
    try std.testing.expectEqual(@as(i32, 3), valueAtAngle(0, 0, 101, 0, .hour, true)); // outer 3 o'clock
    try std.testing.expectEqual(@as(i32, 15), valueAtAngle(0, 0, 69, 0, .hour, true)); // inner 3 o'clock
    try std.testing.expectEqual(@as(i32, 0), valueAtAngle(0, 0, 0, -74, .hour, true)); // the top, at MaxDistance → outer
    try std.testing.expectEqual(label_ring, selectorRing(3, .hour, true));
    try std.testing.expectEqual(inner_label_ring, selectorRing(15, .hour, true));
    try std.testing.expectEqual(label_ring, selectorRing(10, .hour, false)); // 12h: a single ring
}

test "time_picker: measures the 360x464 M3E panel" {
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const m = f[0].measure(.{ .max_w = 1000, .max_h = 1000 });
    try std.testing.expectEqual(@as(f32, 360), m.w);
    try std.testing.expectEqual(total_h, m.h);
}

test "time_picker: the plates switch the dial mode; AM/PM flips the period; OK/Cancel fire" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    var ok_fired: u32 = 0;
    var cancel_fired: u32 = 0;
    const s = stateOf(n);
    s.on_select = .{ .fn_ptr = countCb, .userdata = &ok_fired };
    s.on_cancel = .{ .fn_ptr = countCb, .userdata = &cancel_fired };
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    const tap = struct {
        fn go(r: *input.InputRouter, node: *Node, rct: Rect) void {
            const cx = rct.x + rct.w / 2;
            const cy = rct.y + rct.h / 2;
            r.dispatchPointer(node, .{ .phase = .down, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
            r.dispatchPointer(node, .{ .phase = .up, .x = cx, .y = cy, .raw_x = cx, .raw_y = cy });
        }
    }.go;
    // the minute plate → minute mode
    tap(&router, n, plateRect(n.bounds, .minute, false));
    try std.testing.expectEqual(DialMode.minute, dialMode(n));
    // the hour plate → back to hour mode
    tap(&router, n, plateRect(n.bounds, .hour, false));
    try std.testing.expectEqual(DialMode.hour, dialMode(n));
    // PM: 10:30 AM → 22:30 (the signal round-trips) — tap the PM half's
    // center (the toggle's exact vertical center is the AM/PM boundary → .pm)
    const pr = periodRect(n.bounds);
    const px = pr.x + pr.w / 2;
    const py = pr.y + pr.h * 3 / 4; // PM = bottom half
    router.dispatchPointer(n, .{ .phase = .down, .x = px, .y = py, .raw_x = px, .raw_y = py });
    router.dispatchPointer(n, .{ .phase = .up, .x = px, .y = py, .raw_x = px, .raw_y = py });
    try std.testing.expectEqual(@as(i32, 22 * 60 + 30), f[1].peek());
    try std.testing.expectEqual(@as(i32, 1350), timeMinutes(n));
    try std.testing.expectEqualStrings("10:30 PM", n.semantics.?.value);
    // AM: back — tap the AM half's center
    const ay = pr.y + pr.h / 4; // AM = top half
    router.dispatchPointer(n, .{ .phase = .down, .x = px, .y = ay, .raw_x = px, .raw_y = ay });
    router.dispatchPointer(n, .{ .phase = .up, .x = px, .y = ay, .raw_x = px, .raw_y = ay });
    try std.testing.expectEqual(@as(i32, 630), f[1].peek());
    // the footer
    const fr = footerRects(n);
    tap(&router, n, fr.cancel);
    try std.testing.expectEqual(@as(u32, 1), cancel_fired);
    tap(&router, n, fr.ok);
    try std.testing.expectEqual(@as(u32, 1), ok_fired);
}

fn countCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "time_picker: tapping + dragging the dial selects by angle (hour + minute modes)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const c = dialCenter(n);
    // hour mode: tap straight up (the top) → 12 o'clock; the picker is in AM
    // (10:30) so 12 means 12 AM = midnight → 00:30 = 30
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0], .y = c[1] - 101, .raw_x = c[0], .raw_y = c[1] - 101 });
    try std.testing.expectEqual(@as(i32, 30), f[1].peek());
    // keep dragging (the dial owns the move): drag to the right (3 o'clock) → 3
    router.dispatchPointer(n, .{ .phase = .move, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), f[1].peek());
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    // minute mode: tap straight down → minute 30 (3:30 → 3:30? hour stays 3)
    const s = stateOf(n);
    s.mode = .minute;
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0], .y = c[1] + 101, .raw_x = c[0], .raw_y = c[1] + 101 });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), f[1].peek());
    // drag to the right → minute 15
    router.dispatchPointer(n, .{ .phase = .move, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 15), f[1].peek());
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 101, .y = c[1], .raw_x = c[0] + 101, .raw_y = c[1] });
    // a tap outside the dial circle (the square's corner) does nothing
    router.dispatchPointer(n, .{ .phase = .down, .x = c[0] + 120, .y = c[1] + 120, .raw_x = c[0] + 120, .raw_y = c[1] + 120 });
    router.dispatchPointer(n, .{ .phase = .up, .x = c[0] + 120, .y = c[1] + 120, .raw_x = c[0] + 120, .raw_y = c[1] + 120 });
    try std.testing.expectEqual(@as(i32, 3 * 60 + 15), f[1].peek());
}

test "time_picker: the 24h dial is a dual ring (outer 0..11, inner 12..23)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const a = std.testing.allocator;
    const sig = try ui.state.Signal(i32).init(a, 630); // 10:30
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .is_24h = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    const c = dialCenter(n);
    const tap = struct {
        fn go(r: *input.InputRouter, node: *Node, x: f32, y: f32) void {
            r.dispatchPointer(node, .{ .phase = .down, .x = x, .y = y, .raw_x = x, .raw_y = y });
            r.dispatchPointer(node, .{ .phase = .up, .x = x, .y = y, .raw_x = x, .raw_y = y });
        }
    }.go;
    // the OUTER ring at 3 o'clock (radius 101 >= MaxDistance 74) → 03:30
    tap(&router, n, c[0] + 101, c[1]);
    try std.testing.expectEqual(@as(i32, 3 * 60 + 30), sig.peek());
    // the INNER ring at 3 o'clock (radius 69 < 74) → 15:30
    tap(&router, n, c[0] + 69, c[1]);
    try std.testing.expectEqual(@as(i32, 15 * 60 + 30), sig.peek());
    // the boundary distance (74) picks the outer ring: the top → 00:30
    tap(&router, n, c[0], c[1] - 74);
    try std.testing.expectEqual(@as(i32, 30), sig.peek());
    // the a11y value follows (24h format)
    try std.testing.expectEqualStrings("00:30", n.semantics.?.value);
}

test "time_picker: the app drives the time (two-way signal, clamped)" {
    const a = std.testing.allocator;
    const f = try tpFixture(a);
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    f[1].set(22 * 60 + 5); // 22:05
    try std.testing.expectEqual(@as(i32, 1325), timeMinutes(n));
    try std.testing.expectEqualStrings("10:05 PM", n.semantics.?.value);
    f[1].set(-10); // clamped to 00:00
    try std.testing.expectEqual(@as(i32, 0), timeMinutes(n));
    try std.testing.expectEqualStrings("12:00 AM", n.semantics.?.value);
}

test "golden: the M3E time picker panel (plates, period toggle, dial knob + hand, footer)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const f = try tpFixture(a); // 10:30 AM, hour mode
    defer f[1].deinit();
    defer f[0].deinit();
    const n = f[0];
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    var r = try golden.Renderer.init(a, 360, 464);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh)
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the hour plate (active): PrimaryContainer fill, inside the 2dp border
    const hp = plateRect(n.bounds, .hour, false);
    try std.testing.expectEqual(t.colors.primary_container, f2.pixelAt(@intFromFloat(hp.x + 12), @intFromFloat(hp.y + 12)));
    // the minute plate (inactive): SurfaceContainerHighest
    const mp = plateRect(n.bounds, .minute, false);
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(@intFromFloat(mp.x + 12), @intFromFloat(mp.y + 12)));
    // the period toggle: 10:30 is AM → the AM half is TertiaryContainer
    // (sample above the "AM" label ink, inside the rounded fill)
    const pr = periodRect(n.bounds);
    try std.testing.expectEqual(t.colors.tertiary_container, f2.pixelAt(@intFromFloat(pr.x + 26), @intFromFloat(pr.y + 4)));
    // the dial fill (SurfaceContainerHighest) between the center and the ring
    const d = dialRect(n.bounds);
    const cx = @as(i32, @intFromFloat(d.x + d.w / 2));
    const cy = @as(i32, @intFromFloat(d.y + d.h / 2));
    try std.testing.expectEqual(t.colors.surface_container_highest, f2.pixelAt(cx, cy - 60));
    // the knob: 10 o'clock → angle 210° → the knob center at radius 101
    // (92.5, 209.5); sample inside the 48dp knob, away from the "10" label
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx - 103, cy - 51));
    // the center dot (8dp Primary)
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx, cy - 2));
    // the footer: the OK label (Primary ink)
    const fr = footerRects(n);
    try std.testing.expect(f2.countColorApproxIn(fr.ok, t.colors.primary) > 0);
}

test "golden: the M3E time picker panel in 24h mode (dual-ring dial, inner knob)" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    // 15:30, 24h → the knob sits on the INNER ring (69dp) at 3 o'clock
    const sig = try ui.state.Signal(i32).init(a, 15 * 60 + 30);
    defer sig.deinit();
    const n = try timePicker(a, sig, null, null, .{ .is_24h = true });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 360, .h = total_h });
    var r = try golden.Renderer.init(a, 360, 464);
    defer r.deinit();
    r.paint(n, 0xFFFFFFFF);
    var f2 = try r.readback(a);
    defer f2.deinit();
    // the container (SurfaceContainerHigh)
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(180, 5));
    // the hour plate (active): "15" (OnPrimaryContainer ink on PrimaryContainer)
    const hp = plateRect(n.bounds, .hour, true);
    try std.testing.expectEqual(t.colors.primary_container, f2.pixelAt(@intFromFloat(hp.x + 12), @intFromFloat(hp.y + 12)));
    try std.testing.expect(f2.countColorApproxIn(hp, t.colors.on_primary_container) > 0);
    // no period toggle in 24h: the dial's left edge is clear at the header's
    // right side (the row is narrower — nothing painted past the minute plate)
    const mp = plateRect(n.bounds, .minute, true);
    try std.testing.expectEqual(t.colors.surface_container_high, f2.pixelAt(@intFromFloat(mp.x + mp.w + 10), @intFromFloat(mp.y + mp.h / 2)));
    // the inner knob (Primary) at 3 o'clock on the inner ring, away from the
    // "15" label ink (below it, still inside the 48dp knob)
    const d = dialRect(n.bounds);
    const cx = @as(i32, @intFromFloat(d.x + d.w / 2));
    const cy = @as(i32, @intFromFloat(d.y + d.h / 2));
    try std.testing.expectEqual(t.colors.primary, f2.pixelAt(cx + 69, cy + 15));
    // the outer ring's "03" label (OnSurface ink) at 3 o'clock on the outer ring
    try std.testing.expect(f2.countColorApproxIn(.{ .x = @floatFromInt(cx + 101 - 20), .y = @floatFromInt(cy - 12), .w = 40, .h = 24 }, t.colors.on_surface) > 0);
    // the inner ring's "15" label is on the knob (OnPrimary ink)
    try std.testing.expect(f2.countColorApproxIn(.{ .x = @floatFromInt(cx + 69 - 20), .y = @floatFromInt(cy - 12), .w = 40, .h = 24 }, t.colors.on_primary) > 0);
}
