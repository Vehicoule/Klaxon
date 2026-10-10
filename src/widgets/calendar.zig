// M3E Calendar (Phase 4d P2) — an inline (non-modal) calendar month view.
// Reuses the date_picker's civil calendar helpers (same algorithms).
//
// Spec: docs/specs/m3e-specs-4d-p2-calendar.md
//
// Differences from date_picker: inline (always visible), narrower (280dp),
// SurfaceContainer (not High), no OK/Cancel footer, smaller cells (36dp).
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const theme_mod = @import("../theme.zig");
const date_picker_w = @import("date_picker.zig");
const golden = @import("../golden.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Theme = theme_mod.Theme;

pub const CalendarOptions = struct {
    theme: Theme = theme_mod.light,
    width: f32 = 280,
    /// "Today" as a UTC epoch day (null = system clock, UTC).
    today: ?i64 = null,
};

// --- Tokens ---
const panel_corner: f32 = 12;
const header_h: f32 = 56;
const weekday_h: f32 = 40;
const cell: f32 = 36;
const cell_gap: f32 = 4;
const grid_rows: usize = 6;
const h_pad: f32 = 8;
const chevron_hit: f32 = 40;
const chevron_icon: f32 = 24;

const grid_h: f32 = grid_rows * (cell + cell_gap); // 240
const total_h: f32 = header_h + weekday_h + grid_h + h_pad; // 312

const weekday_letters = [_][:0]const u8{ "S", "M", "T", "W", "T", "F", "S" };

// --- State ---

const CalState = struct {
    opts: CalendarOptions,
    selected: ?*ui.state.Signal(?i64),
    displayed: ?*ui.state.Signal(i64),
    hovered_day: ?i64 = null,
};

fn stateOf(n: *Node) *CalState {
    return @ptrCast(@alignCast(n.state.?));
}

fn selDay(s: *CalState) ?i64 {
    return if (s.selected) |sig| sig.peek() else null;
}

fn dispMonth(s: *CalState) i64 {
    return if (s.displayed) |sig| sig.peek() else date_picker_w.todayDay(null);
}

// --- Measure / Layout ---

fn calMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const w = @max(s.opts.width, 280);
    return .{
        .w = @max(c.min_w, @min(c.max_w, w)),
        .h = @max(c.min_h, @min(c.max_h, total_h)),
    };
}

fn calLayout(_: *Node, _: Rect) void {}

// --- Paint ---

fn calPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;

    // Panel background.
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, panel_corner, t.colors.surface_container);

    const inner_w = b.w - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;

    // Header: month-year + chevrons.
    const month_first = dispMonth(s);
    const civil = date_picker_w.civilFromDays(month_first);
    var month_buf: [32]u8 = undefined;
    const month_str_slice = std.fmt.bufPrint(&month_buf, "{s} {d}", .{ date_picker_w.monthName(civil.m), civil.y }) catch "?";
    month_buf[month_str_slice.len] = 0;
    const month_str: [:0]const u8 = month_buf[0..month_str_slice.len :0];
    const ts = t.type_scale.title_medium;
    const title_x = b.x + h_pad + 16;
    const title_y = b.y + (header_h - ts.line_height) / 2 + ts.line_height * 0.8;
    ui.paint.text(ctx, month_str, title_x, title_y, ts.size, true, t.colors.on_surface);

    // Chevrons (◀ ▶).
    const chev_y = b.y + (header_h - chevron_icon) / 2;
    const chev_prev_x = b.x + b.w - h_pad - 16 - chevron_icon * 2 - 8;
    const chev_next_x = b.x + b.w - h_pad - 16 - chevron_icon;
    ui.paint.text(ctx, "\u{25C0}", chev_prev_x, chev_y + chevron_icon * 0.8, chevron_icon, false, t.colors.on_surface_variant);
    ui.paint.text(ctx, "\u{25B6}", chev_next_x, chev_y + chevron_icon * 0.8, chevron_icon, false, t.colors.on_surface_variant);

    // Weekday row.
    const wd_y = b.y + header_h;
    const ls = t.type_scale.body_small;
    for (weekday_letters, 0..) |letter, col| {
        const cx = b.x + h_pad + @as(f32, @floatFromInt(col)) * (cell_w + cell_gap) + cell_w / 2;
        const m = ui.paint.measureText(letter, ls.size, false);
        ui.paint.text(ctx, letter, cx - m.width / 2, wd_y + (weekday_h - ls.line_height) / 2 + ls.line_height * 0.8, ls.size, false, t.colors.on_surface_variant);
    }

    // Day grid.
    const grid_y = wd_y + weekday_h;
    const today = date_picker_w.clampDay(date_picker_w.todayDay(s.opts.today));
    const sel = selDay(s);
    const first_weekday = date_picker_w.weekdayFromDays(month_first); // 0=Sun..6=Sat
    const days_in_month = date_picker_w.daysInMonth(civil.y, civil.m);

    var day: i64 = 1;
    var row: usize = 0;
    while (row < grid_rows) : (row += 1) {
        var col: usize = 0;
        while (col < 7) : (col += 1) {
            const idx = row * 7 + col;
            if (idx >= first_weekday and day <= days_in_month) {
                const epoch_day = date_picker_w.clampDay(date_picker_w.daysFromCivil(civil.y, civil.m, day));
                const cx = b.x + h_pad + @as(f32, @floatFromInt(col)) * (cell_w + cell_gap);
                const cy = grid_y + @as(f32, @floatFromInt(row)) * (cell + cell_gap);

                // Cell background.
                const is_sel = sel != null and sel.? == epoch_day;
                const is_today = today == epoch_day;
                if (is_sel) {
                    ui.paint.fillRRect(ctx, cx, cy, cell_w, cell, cell / 2, t.colors.primary);
                } else if (is_today) {
                    ui.paint.strokeRRect(ctx, cx, cy, cell_w, cell, cell / 2, 1, t.colors.primary);
                }

                // Day number.
                var day_buf: [5]u8 = undefined;
                const day_slice = std.fmt.bufPrint(&day_buf, "{d}", .{day}) catch "?";
                day_buf[day_slice.len] = 0;
                const day_str: [:0]const u8 = day_buf[0..day_slice.len :0];
                const day_color = if (is_sel)
                    t.colors.on_primary
                else if (is_today)
                    t.colors.primary
                else
                    t.colors.on_surface;
                const dm = ui.paint.measureText(day_str, ls.size, is_sel);
                ui.paint.text(ctx, day_str, cx + (cell_w - dm.width) / 2, cy + (cell - dm.height) / 2 + dm.height * 0.8, ls.size, is_sel, day_color);

                day += 1;
            }
        }
    }
}

// --- Input ---

fn calPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    const b = n.bounds;
    if (ev.phase != .up) return false;

    // Chevron taps.
    const chev_y0 = b.y;
    const chev_y1 = b.y + header_h;
    if (ev.y >= chev_y0 and ev.y <= chev_y1) {
        const chev_prev_x = b.x + b.w - h_pad - 16 - chevron_icon * 2 - 8;
        const chev_next_x = b.x + b.w - h_pad - 16 - chevron_icon;
        if (ev.x >= chev_prev_x and ev.x <= chev_prev_x + chevron_icon) {
            pageMonth(s, n, -1);
            return true;
        }
        if (ev.x >= chev_next_x and ev.x <= chev_next_x + chevron_icon) {
            pageMonth(s, n, 1);
            return true;
        }
    }

    // Day cell tap.
    const grid_y = b.y + header_h + weekday_h;
    const inner_w = b.w - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;
    if (ev.y >= grid_y and ev.y <= grid_y + grid_h) {
        const col: usize = @intCast(@min(6, @max(0, @as(i32, @intFromFloat((ev.x - b.x - h_pad) / (cell_w + cell_gap))))));
        const row: usize = @intCast(@min(5, @max(0, @as(i32, @intFromFloat((ev.y - grid_y) / (cell + cell_gap))))));
        const idx = row * 7 + col;
        const month_first = dispMonth(s);
        const civil = date_picker_w.civilFromDays(month_first);
        const first_weekday = date_picker_w.weekdayFromDays(month_first);
        const days_in_month = date_picker_w.daysInMonth(civil.y, civil.m);
        if (idx >= first_weekday) {
            const day_num = idx - first_weekday + 1;
            if (day_num <= days_in_month) {
                const epoch_day = date_picker_w.clampDay(date_picker_w.daysFromCivil(civil.y, civil.m, @intCast(day_num)));
                if (s.selected) |sig| sig.set(epoch_day);
                n.markDirty();
                return true;
            }
        }
    }
    return false;
}

fn pageMonth(s: *CalState, n: *Node, delta: i32) void {
    const month_first = dispMonth(s);
    const civil = date_picker_w.civilFromDays(month_first);
    var y = civil.y;
    var m = civil.m + delta;
    if (m < 1) {
        m = 12;
        y -= 1;
    } else if (m > 12) {
        m = 1;
        y += 1;
    }
    const new_first = date_picker_w.clampDay(date_picker_w.daysFromCivil(y, m, 1));
    if (s.displayed) |sig| sig.set(new_first);
    n.markDirty();
}

// --- Deinit ---

fn calDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(n));
}

// --- VTable ---

const cal_vtable = ui.node.VTable{
    .measure = calMeasure,
    .layout = calLayout,
    .paint = calPaint,
    .on_pointer = calPointer,
    .deinit = calDeinit,
};

// --- Factory ---

pub fn calendar(
    allocator: std.mem.Allocator,
    selected: ?*ui.state.Signal(?i64),
    displayed: ?*ui.state.Signal(i64),
    opts: CalendarOptions,
) !*Node {
    const node = try Node.create(allocator, &cal_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(CalState);
    errdefer allocator.destroy(s);

    s.* = .{ .opts = opts, .selected = selected, .displayed = displayed };
    node.state = @ptrCast(s);

    ui.semantics.attach(node, .{
        .role = .group,
        .label = "Calendar",
        .focusable = false,
    });

    return node;
}

// --- Tests ---

test "calendar: measure returns 280×312" {
    const a = std.testing.allocator;
    const n = try calendar(a, null, null, .{});
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 2000, .max_h = 2000 });
    try std.testing.expectApproxEqAbs(@as(f32, 280), sz.w, 0.001);
    try std.testing.expectApproxEqAbs(total_h, sz.h, 0.001);
}

test "calendar: tap a day selects it" {
    const sig = try ui.state.Signal(?i64).init(std.testing.allocator, null);
    defer sig.deinit();
    const a = std.testing.allocator;
    // Use a fixed "today" so the displayed month is deterministic.
    const fixed_today = date_picker_w.daysFromCivil(2026, 10, 15); // Oct 2026
    const n = try calendar(a, sig, null, .{ .today = fixed_today });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 280, .h = total_h });
    // Tap somewhere in the middle of the grid (row 2, col 3) — guaranteed
    // to land on a valid day cell for any month.
    const grid_y = header_h + weekday_h;
    const inner_w = 280 - h_pad * 2;
    const cell_w = (inner_w - cell_gap * 6) / 7;
    const tap_x = h_pad + 3 * (cell_w + cell_gap) + cell_w / 2;
    const tap_y = grid_y + 2 * (cell + cell_gap) + cell / 2;
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = tap_x, .y = tap_y, .raw_x = tap_x, .raw_y = tap_y });
    // A day was selected (not null) and it's in October 2026.
    const sel = sig.peek();
    try std.testing.expect(sel != null);
    const civil = date_picker_w.civilFromDays(sel.?);
    try std.testing.expectEqual(@as(i64, 2026), civil.y);
    try std.testing.expectEqual(@as(i64, 10), civil.m);
}

test "golden: the calendar paints SurfaceContainer + a day grid" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try calendar(a, null, null, .{ .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 300, 340);
    defer r.deinit();
    n.layout(.{ .x = 10, .y = 10, .w = 280, .h = total_h });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Panel fill.
    try std.testing.expectEqual(t.colors.surface_container, f.pixelAt(20, 20));
    // Outside the panel corner: background.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(10, 10));
}
