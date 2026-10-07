// Input widgets (Phase 1c) — Button, Toggle, Checkbox, Radio, Slider,
// TextField, Dropdown, Chip. Built on the input router (ui/input.zig):
// pointer events arrive via VTable.on_pointer (bubbled until handled), key
// events via VTable.on_key (delivered to the focused node).
//
// Interactive widgets are signal-driven (Phase 1a): Toggle/Checkbox/Radio/
// Slider/Chip bind their node to a signal (visual updates on set) and
// unsubscribe on deinit — no GC, dangling subscriptions are fatal.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const golden = @import("../golden.zig");
const text_w = @import("text.zig");
const layout_w = @import("layout.zig");

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const EdgeInsets = ui.layout.EdgeInsets;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;

fn stateOf(comptime T: type, n: *Node) *T {
    return @ptrCast(@alignCast(n.state.?));
}

// --- Button ---

pub const ButtonOptions = struct {
    bg: Color = 0x3B5BDBFF,
    bg_hover: Color = 0x4C6EF5FF,
    bg_pressed: Color = 0x364FC7FF,
    radius: f32 = 8,
    padding: EdgeInsets = .{ .left = 16, .top = 8, .right = 16, .bottom = 8 },
};

const ButtonState = struct {
    opts: ButtonOptions,
    on_pressed: ?Callback = null,
    pressed: bool = false,
    hovered: bool = false,
};

fn buttonMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ButtonState, n);
    var size = Size{ .w = s.opts.padding.hSum(), .h = s.opts.padding.vSum() };
    if (n.children.items.len > 0) {
        const cs = n.children.items[0].measure(c.deflateEdge(s.opts.padding));
        size = .{ .w = cs.w + s.opts.padding.hSum(), .h = cs.h + s.opts.padding.vSum() };
    }
    return c.constrain(size);
}
fn buttonLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(ButtonState, n);
    if (n.children.items.len == 0) return;
    n.children.items[0].layout(.{
        .x = bounds.x + s.opts.padding.left,
        .y = bounds.y + s.opts.padding.top,
        .w = @max(0, bounds.w - s.opts.padding.hSum()),
        .h = @max(0, bounds.h - s.opts.padding.vSum()),
    });
}
fn buttonPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ButtonState, n);
    const bg = if (s.pressed) s.opts.bg_pressed else if (s.hovered) s.opts.bg_hover else s.opts.bg;
    ui.paint.fillRRect(ctx, n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h, s.opts.radius, bg);
}
fn buttonOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ButtonState, n);
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            n.markDirty();
            return true;
        },
        .up => {
            s.pressed = false;
            n.markDirty();
            // Click = down + up on the same node (the router captured us).
            if (n.bounds.contains(ev.x, ev.y)) {
                if (s.on_pressed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .enter => {
            s.hovered = true;
            n.markDirty();
            return true;
        },
        .leave => {
            s.hovered = false;
            n.markDirty();
            return true;
        },
        else => {},
    }
    return false;
}
fn buttonDeinit(n: *Node) void {
    input.releaseNode(n);
    n.allocator.destroy(stateOf(ButtonState, n));
}
const button_vtable = ui.node.VTable{
    .measure = buttonMeasure,
    .layout = buttonLayout,
    .paint = buttonPaint,
    .deinit = buttonDeinit,
    .on_pointer = buttonOnPointer,
};

pub fn button(allocator: std.mem.Allocator, on_pressed: ?Callback, opts: ButtonOptions) !*Node {
    const node = try Node.create(allocator, &button_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ButtonState);
    errdefer allocator.destroy(s);
    s.* = .{ .opts = opts, .on_pressed = on_pressed };
    node.state = s;
    return node;
}

// --- Toggle (switch) ---

pub const ToggleOptions = struct {
    width: f32 = 44,
    height: f32 = 24,
    track_off: Color = 0x444455FF,
    track_on: Color = 0x3B5BDBFF,
    knob: Color = 0xFFFFFFFF,
};

const ToggleState = struct {
    sig: *ui.state.Signal(bool),
    opts: ToggleOptions,
    on_changed: ?Callback = null,
};

fn toggleMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ToggleState, n);
    return c.constrain(.{ .w = s.opts.width, .h = s.opts.height });
}
fn toggleLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn togglePaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ToggleState, n);
    const on = s.sig.get();
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, b.h / 2, if (on) s.opts.track_on else s.opts.track_off);
    const knob_size = b.h - 4;
    const knob_x = if (on) b.x + b.w - knob_size - 2 else b.x + 2;
    ui.paint.fillRRect(ctx, knob_x, b.y + 2, knob_size, knob_size, knob_size / 2, s.opts.knob);
}
fn toggleOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ToggleState, n);
    switch (ev.phase) {
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) {
                s.sig.set(!s.sig.get());
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .down => return true,
        else => {},
    }
    return false;
}
fn toggleDeinit(n: *Node) void {
    const s = stateOf(ToggleState, n);
    s.sig.unsubscribe(.{ .node = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const toggle_vtable = ui.node.VTable{
    .measure = toggleMeasure,
    .layout = toggleLayout,
    .paint = togglePaint,
    .deinit = toggleDeinit,
    .on_pointer = toggleOnPointer,
};

pub fn toggle(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: ToggleOptions) !*Node {
    const node = try Node.create(allocator, &toggle_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ToggleState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = sig, .opts = opts, .on_changed = on_changed };
    node.state = s;
    ui.state.bindNode(node, sig); // visual updates on set
    return node;
}

// --- Checkbox ---

pub const CheckboxOptions = struct {
    size: f32 = 20,
    box_color: Color = 0x282838FF,
    border: Color = 0x555566FF,
    check: Color = 0xFFFFFFFF,
    accent: Color = 0x3B5BDBFF,
    radius: f32 = 4,
};

const CheckboxState = struct {
    sig: *ui.state.Signal(bool),
    opts: CheckboxOptions,
    on_changed: ?Callback = null,
};

fn checkboxMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(CheckboxState, n);
    return c.constrain(.{ .w = s.opts.size, .h = s.opts.size });
}
fn checkboxLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn checkboxPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(CheckboxState, n);
    const b = n.bounds;
    if (s.sig.get()) {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, s.opts.accent);
        const glyph = "\u{2713}"; // ✓
        const gm = ui.paint.measureText(glyph, b.h * 0.7, false);
        ui.paint.text(ctx, glyph, b.x + (b.w - gm.width) / 2, b.y + (b.h - gm.height) / 2 + gm.ascent, b.h * 0.7, false, s.opts.check);
    } else {
        ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, s.opts.border);
        ui.paint.fillRRect(ctx, b.x + 2, b.y + 2, b.w - 4, b.h - 4, @max(0, s.opts.radius - 2), s.opts.box_color);
    }
}
fn checkboxOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(CheckboxState, n);
    switch (ev.phase) {
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) {
                s.sig.set(!s.sig.get());
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .down => return true,
        else => {},
    }
    return false;
}
fn checkboxDeinit(n: *Node) void {
    const s = stateOf(CheckboxState, n);
    s.sig.unsubscribe(.{ .node = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const checkbox_vtable = ui.node.VTable{
    .measure = checkboxMeasure,
    .layout = checkboxLayout,
    .paint = checkboxPaint,
    .deinit = checkboxDeinit,
    .on_pointer = checkboxOnPointer,
};

pub fn checkbox(allocator: std.mem.Allocator, sig: *ui.state.Signal(bool), on_changed: ?Callback, opts: CheckboxOptions) !*Node {
    const node = try Node.create(allocator, &checkbox_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(CheckboxState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = sig, .opts = opts, .on_changed = on_changed };
    node.state = s;
    ui.state.bindNode(node, sig);
    return node;
}

// --- Radio (group = a shared signal; value type T) ---

pub const RadioOptions = struct {
    size: f32 = 20,
    ring: Color = 0x555566FF,
    track: Color = 0x282838FF,
    dot: Color = 0x3B5BDBFF,
};

/// Radio button for a group signal — generic over the value type `T`
/// (int, enum, ...). Usage: Radio(u32).radio(allocator, group, 2, .{}).
pub fn Radio(comptime T: type) type {
    return struct {
        pub const State = struct {
            group: *ui.state.Signal(T),
            value: T,
            opts: RadioOptions,
        };

        fn measure(n: *Node, c: Constraints) Size {
            const s = stateOf(State, n);
            return c.constrain(.{ .w = s.opts.size, .h = s.opts.size });
        }
        fn layout(n: *Node, bounds: Rect) void {
            _ = n;
            _ = bounds;
        }
        fn paint(n: *Node, ctx: *kx.Ctx) void {
            const s = stateOf(State, n);
            const b = n.bounds;
            const selected = std.meta.eql(s.group.get(), s.value);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, b.w / 2, s.opts.ring);
            ui.paint.fillRRect(ctx, b.x + 2, b.y + 2, b.w - 4, b.h - 4, (b.w - 4) / 2, s.opts.track);
            if (selected) {
                ui.paint.fillRRect(ctx, b.x + 6, b.y + 6, b.w - 12, b.h - 12, (b.w - 12) / 2, s.opts.dot);
            }
        }
        fn onPointer(n: *Node, ev: input.PointerEvent) bool {
            const s = stateOf(State, n);
            switch (ev.phase) {
                .up => {
                    if (n.bounds.contains(ev.x, ev.y)) s.group.set(s.value);
                    return true;
                },
                .down => return true,
                else => {},
            }
            return false;
        }
        fn deinit(n: *Node) void {
            const s = stateOf(State, n);
            s.group.unsubscribe(.{ .node = n });
            input.releaseNode(n);
            n.allocator.destroy(s);
        }
        const vtable = ui.node.VTable{
            .measure = measure,
            .layout = layout,
            .paint = paint,
            .deinit = deinit,
            .on_pointer = onPointer,
        };

        pub fn radio(allocator: std.mem.Allocator, group: *ui.state.Signal(T), value: T, opts: RadioOptions) !*Node {
            const node = try Node.create(allocator, &vtable);
            errdefer node.allocator.destroy(node); // no state yet; children list is empty
            const s = try allocator.create(State);
            errdefer allocator.destroy(s);
            s.* = .{ .group = group, .value = value, .opts = opts };
            node.state = s;
            ui.state.bindNode(node, group); // visual updates when the group changes
            return node;
        }
    };
}

// --- Slider ---

pub const SliderOptions = struct {
    height: f32 = 24,
    track: Color = 0x444455FF,
    fill: Color = 0x3B5BDBFF,
    knob: Color = 0xFFFFFFFF,
    default_width: f32 = 200,
    knob_size: f32 = 16,
};

const SliderState = struct {
    sig: *ui.state.Signal(f32),
    opts: SliderOptions,
    on_changed: ?Callback = null,
};

fn sliderMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(SliderState, n);
    const w = if (std.math.isFinite(c.max_w)) c.max_w else s.opts.default_width;
    return c.constrain(.{ .w = w, .h = s.opts.height });
}
fn sliderLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn sliderPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(SliderState, n);
    const v = std.math.clamp(s.sig.get(), 0, 1);
    const b = n.bounds;
    const track_h: f32 = 4;
    const ty = b.y + (b.h - track_h) / 2;
    ui.paint.fillRRect(ctx, b.x, ty, b.w, track_h, track_h / 2, s.opts.track);
    ui.paint.fillRRect(ctx, b.x, ty, b.w * v, track_h, track_h / 2, s.opts.fill);
    const ks = s.opts.knob_size;
    ui.paint.fillRRect(ctx, b.x + b.w * v - ks / 2, b.y + (b.h - ks) / 2, ks, ks, ks / 2, s.opts.knob);
}
fn sliderOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(SliderState, n);
    switch (ev.phase) {
        // down/move: the router only delivers move while we are captured (drag).
        .down, .move => {
            const b = n.bounds;
            if (b.w > 0) {
                const v = std.math.clamp((ev.x - b.x) / b.w, 0, 1);
                s.sig.set(v);
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            }
            return true;
        },
        .up => return true,
        else => {},
    }
    return false;
}
fn sliderDeinit(n: *Node) void {
    const s = stateOf(SliderState, n);
    s.sig.unsubscribe(.{ .node = n });
    input.releaseNode(n);
    n.allocator.destroy(s);
}
const slider_vtable = ui.node.VTable{
    .measure = sliderMeasure,
    .layout = sliderLayout,
    .paint = sliderPaint,
    .deinit = sliderDeinit,
    .on_pointer = sliderOnPointer,
};

pub fn slider(allocator: std.mem.Allocator, sig: *ui.state.Signal(f32), on_changed: ?Callback, opts: SliderOptions) !*Node {
    const node = try Node.create(allocator, &slider_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(SliderState);
    errdefer allocator.destroy(s);
    s.* = .{ .sig = sig, .opts = opts, .on_changed = on_changed };
    node.state = s;
    ui.state.bindNode(node, sig);
    return node;
}

// --- TextField ---

pub const TextFieldOptions = struct {
    size: f32 = 16,
    color: Color = 0xFFFFFFFF,
    hint: Color = 0x888899FF,
    bg: Color = 0x282838FF,
    radius: f32 = 6,
    padding: EdgeInsets = .{ .left = 8, .top = 6, .right = 8, .bottom = 6 },
    placeholder: []const u8 = "",
    initial: []const u8 = "",
};

/// Write the null sentinel at items[len] (requires capacity > len — callers
/// ensureTotalCapacity first). The slice length stays at the text length, so
/// items[0..len :0] is valid.
fn setSentinel(buf: *std.array_list.Managed(u8)) void {
    buf.items.len += 1;
    buf.items[buf.items.len - 1] = 0;
    buf.items.len -= 1;
}

const TextFieldState = struct {
    buf: std.array_list.Managed(u8), // kept null-terminated: items[len] == 0
    placeholder: [:0]const u8, // owned
    opts: TextFieldOptions,
    on_changed: ?Callback = null,
    on_submitted: ?Callback = null,

    fn text(s: *TextFieldState) [:0]const u8 {
        // Sentinel slice via the many-item pointer: the null terminator sits at
        // items[len] in the spare capacity (a plain items[0..len :0] slice would
        // require the sentinel to be inside the slice bounds).
        return s.buf.items.ptr[0..s.buf.items.len :0];
    }
};

fn textFieldMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(TextFieldState, n);
    const str = if (s.buf.items.len > 0) s.text() else s.placeholder;
    const m = ui.paint.measureText(str, s.opts.size, false);
    return c.constrain(.{ .w = m.width + s.opts.padding.hSum() + 2, .h = m.height + s.opts.padding.vSum() });
}
fn textFieldLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn textFieldPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(TextFieldState, n);
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, s.opts.bg);
    const empty = s.buf.items.len == 0;
    const str = if (empty) s.placeholder else s.text();
    const m = ui.paint.measureText(str, s.opts.size, false);
    const text_x = b.x + s.opts.padding.left;
    const text_y = b.y + (b.h - m.height) / 2 + m.ascent;
    if (str.len > 0) ui.paint.text(ctx, str, text_x, text_y, s.opts.size, false, if (empty) s.opts.hint else s.opts.color);
    if (input.isFocused(n)) {
        // Cursor bar at the end of the text (P0: cursor always at the end).
        const cursor_x = text_x + (if (empty) @as(f32, 0) else m.width + 1);
        ui.paint.fillRect(ctx, cursor_x, b.y + s.opts.padding.top, 2, m.height, s.opts.color);
    }
}
fn textFieldOnPointer(n: *Node, ev: input.PointerEvent) bool {
    switch (ev.phase) {
        .down => {
            input.requestFocus(n);
            n.markDirty();
            return true;
        },
        .up => return true,
        else => {},
    }
    return false;
}
fn textFieldOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(TextFieldState, n);
    switch (ev.kind) {
        .text_input => {
            s.buf.ensureTotalCapacity(s.buf.items.len + ev.text.len + 1) catch @panic("klaxon: out of memory");
            s.buf.appendSlice(ev.text) catch @panic("klaxon: out of memory");
            setSentinel(&s.buf);
            n.markDirty();
            if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .key_down => switch (ev.key) {
            .backspace => {
                // Delete the last UTF-8 codepoint (continuation bytes first).
                while (s.buf.items.len > 0) {
                    const last = s.buf.items[s.buf.items.len - 1];
                    s.buf.items.len -= 1;
                    if ((last & 0xC0) != 0x80) break;
                }
                setSentinel(&s.buf);
                n.markDirty();
                if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
                return true;
            },
            .enter => {
                if (s.on_submitted) |cb| cb.fn_ptr(cb.userdata);
                return true;
            },
            .escape => {
                input.requestFocus(null);
                n.markDirty();
                return true;
            },
            else => {},
        },
    }
    return false;
}
fn textFieldDeinit(n: *Node) void {
    input.releaseNode(n);
    const s = stateOf(TextFieldState, n);
    n.allocator.free(s.placeholder);
    s.buf.deinit();
    n.allocator.destroy(s);
}
const text_field_vtable = ui.node.VTable{
    .measure = textFieldMeasure,
    .layout = textFieldLayout,
    .paint = textFieldPaint,
    .deinit = textFieldDeinit,
    .on_pointer = textFieldOnPointer,
    .on_key = textFieldOnKey,
};

pub fn textField(allocator: std.mem.Allocator, opts: TextFieldOptions, on_changed: ?Callback, on_submitted: ?Callback) !*Node {
    const node = try Node.create(allocator, &text_field_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(TextFieldState);
    errdefer allocator.destroy(s);
    const placeholder = try allocator.alloc(u8, opts.placeholder.len + 1);
    errdefer allocator.free(placeholder);
    @memcpy(placeholder[0..opts.placeholder.len], opts.placeholder);
    placeholder[opts.placeholder.len] = 0;
    s.* = .{
        .buf = std.array_list.Managed(u8).init(allocator),
        .placeholder = placeholder[0..opts.placeholder.len :0],
        .opts = opts,
        .on_changed = on_changed,
        .on_submitted = on_submitted,
    };
    errdefer {
        allocator.free(s.placeholder);
        s.buf.deinit();
    }
    s.buf.ensureTotalCapacity(opts.initial.len + 1) catch @panic("klaxon: out of memory");
    if (opts.initial.len > 0) {
        s.buf.appendSlice(opts.initial) catch @panic("klaxon: out of memory");
    }
    setSentinel(&s.buf); // null-terminates the (possibly empty) buffer
    node.state = s;
    return node;
}

/// Current TextField text — borrowed from the widget's buffer (valid until
/// the next edit or deinit). Apps read it from on_changed/on_submitted.
pub fn textFieldText(n: *Node) [:0]const u8 {
    const s = stateOf(TextFieldState, n);
    return s.text();
}

// --- Dropdown (popup menu) ---

pub const DropdownOptions = struct {
    item_height: f32 = 28,
    bg: Color = 0x282838FF,
    menu_bg: Color = 0x1E1E2EFF,
    color: Color = 0xFFFFFFFF,
    radius: f32 = 6,
    padding: EdgeInsets = .{ .left = 10, .top = 4, .right = 10, .bottom = 4 },
    size: f32 = 16, // text size
};

const DropdownState = struct {
    items: std.array_list.Managed([:0]const u8), // owned labels
    selected: usize = 0,
    open: bool = false,
    opts: DropdownOptions,
    on_changed: ?Callback = null,

    fn openBox(s: *DropdownState, n: *Node) void {
        s.open = true;
        for (n.children.items) |child| child.visible = true;
        markMenuDirty(n);
        input.setOpenPopup(n);
    }

    fn close(s: *DropdownState, n: *Node) void {
        s.open = false;
        for (n.children.items) |child| child.visible = false;
        markMenuDirty(n);
        input.setOpenPopup(null);
    }

    /// Damage covers the closed box AND the menu rows: the menu items paint
    /// below the box (overflow), so the dirty-rect clip must include them
    /// for the menu to appear (open) and disappear (close).
    fn markMenuDirty(n: *Node) void {
        var region = n.bounds;
        for (n.children.items) |child| region = ui.node.rectUnion(region, child.bounds);
        n.markDirtyRect(region);
    }
};

/// Menu item row — a child node of the dropdown, hidden until the menu opens.
/// Labels are borrowed from the dropdown's state (children die before it).
const ItemState = struct {
    label: [:0]const u8,
    index: usize,
    owner: *Node,
};

fn itemMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ItemState, n);
    const ds = stateOf(DropdownState, s.owner);
    const m = ui.paint.measureText(s.label, ds.opts.size, false);
    return c.constrain(.{ .w = m.width + ds.opts.padding.hSum(), .h = ds.opts.item_height });
}
fn itemLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn itemPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ItemState, n);
    const ds = stateOf(DropdownState, s.owner);
    const b = n.bounds;
    ui.paint.fillRect(ctx, b.x, b.y, b.w, b.h, ds.opts.menu_bg);
    const m = ui.paint.measureText(s.label, ds.opts.size, false);
    const text_y = b.y + (b.h - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, s.label, b.x + ds.opts.padding.left, text_y, ds.opts.size, false, ds.opts.color);
}
fn itemOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ItemState, n);
    if (ev.phase == .up and n.bounds.contains(ev.x, ev.y)) {
        dropdownSelect(s.owner, s.index);
        return true;
    }
    return false;
}
fn itemDeinit(n: *Node) void {
    n.allocator.destroy(stateOf(ItemState, n));
}
const item_vtable = ui.node.VTable{
    .measure = itemMeasure,
    .layout = itemLayout,
    .paint = itemPaint,
    .deinit = itemDeinit,
    .on_pointer = itemOnPointer,
};

fn menuItem(allocator: std.mem.Allocator, label: [:0]const u8, index: usize, owner: *Node) !*Node {
    const node = try Node.create(allocator, &item_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ItemState);
    errdefer allocator.destroy(s);
    s.* = .{ .label = label, .index = index, .owner = owner };
    node.state = s;
    node.visible = false; // hidden until the dropdown opens
    return node;
}

fn dropdownSelect(owner: *Node, index: usize) void {
    const s = stateOf(DropdownState, owner);
    if (index >= s.items.items.len) return;
    s.selected = index;
    s.close(owner);
    if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
}

fn dropdownMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(DropdownState, n);
    var max_w: f32 = 0;
    for (s.items.items) |label| {
        const m = ui.paint.measureText(label, s.opts.size, false);
        max_w = @max(max_w, m.width);
    }
    const w = max_w + s.opts.padding.hSum() + 24; // + chevron zone
    return c.constrain(.{ .w = w, .h = s.opts.item_height });
}
fn dropdownLayout(n: *Node, bounds: Rect) void {
    const s = stateOf(DropdownState, n);
    // The menu overlays below the closed box (children fill their row).
    for (n.children.items, 0..) |child, i| {
        child.layout(.{
            .x = bounds.x,
            .y = bounds.y + bounds.h + @as(f32, @floatFromInt(i)) * s.opts.item_height,
            .w = bounds.w,
            .h = s.opts.item_height,
        });
    }
}
fn dropdownPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(DropdownState, n);
    const b = n.bounds;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, s.opts.bg);
    const label: [:0]const u8 = if (s.items.items.len > 0) s.items.items[s.selected] else "";
    const m = ui.paint.measureText(label, s.opts.size, false);
    const text_y = b.y + (b.h - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, label, b.x + s.opts.padding.left, text_y, s.opts.size, false, s.opts.color);
    const chevron = "\u{25BC}"; // ▼
    const cm = ui.paint.measureText(chevron, s.opts.size * 0.7, false);
    ui.paint.text(ctx, chevron, b.x + b.w - s.opts.padding.right - cm.width, b.y + (b.h - cm.height) / 2 + cm.ascent, s.opts.size * 0.7, false, s.opts.color);
}
fn dropdownOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(DropdownState, n);
    switch (ev.phase) {
        .up => {
            if (n.bounds.contains(ev.x, ev.y)) {
                if (s.open) s.close(n) else s.openBox(n);
            }
            return true;
        },
        .outside_down => {
            if (s.open) s.close(n);
            return true;
        },
        else => {},
    }
    return false;
}
fn dropdownDeinit(n: *Node) void {
    input.releaseNode(n);
    const s = stateOf(DropdownState, n);
    for (s.items.items) |label| n.allocator.free(label);
    s.items.deinit();
    n.allocator.destroy(s);
}
const dropdown_vtable = ui.node.VTable{
    .measure = dropdownMeasure,
    .layout = dropdownLayout,
    .paint = dropdownPaint,
    .deinit = dropdownDeinit,
    .on_pointer = dropdownOnPointer,
};

/// Copy item labels into an owned list (error-safe: frees partial copies).
fn buildItems(allocator: std.mem.Allocator, items: []const []const u8) !std.array_list.Managed([:0]const u8) {
    var list = std.array_list.Managed([:0]const u8).init(allocator);
    errdefer {
        for (list.items) |label| allocator.free(label);
        list.deinit();
    }
    for (items) |item| {
        const buf = try allocator.alloc(u8, item.len + 1);
        @memcpy(buf[0..item.len], item);
        buf[item.len] = 0;
        list.append(buf[0..item.len :0]) catch {
            allocator.free(buf);
            return error.OutOfMemory;
        };
    }
    return list;
}

/// Create the dropdown node + state, moving ownership of the label list in.
fn nodeWithLabels(
    allocator: std.mem.Allocator,
    owned: *std.array_list.Managed([:0]const u8),
    opts: DropdownOptions,
    on_changed: ?Callback,
) !*Node {
    const node = try Node.create(allocator, &dropdown_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(DropdownState);
    errdefer allocator.destroy(s);
    errdefer {
        for (owned.items) |label| allocator.free(label);
        owned.deinit();
    }
    s.* = .{ .items = owned.*, .opts = opts, .on_changed = on_changed };
    node.state = s;
    return node; // labels owned by the state from here (no fallible ops after)
}

pub fn dropdown(allocator: std.mem.Allocator, items: []const []const u8, opts: DropdownOptions, on_changed: ?Callback) !*Node {
    var owned = try buildItems(allocator, items);
    const node = try nodeWithLabels(allocator, &owned, opts, on_changed);
    errdefer node.deinit(); // state is set: frees labels + partial children
    for (owned.items, 0..) |label, i| {
        node.add(try menuItem(allocator, label, i, node));
    }
    return node;
}

/// Index of the selected Dropdown item (0 before any selection; the closed
/// box always shows it). Read it from on_changed.
pub fn dropdownSelected(n: *Node) usize {
    const s = stateOf(DropdownState, n);
    return s.selected;
}

// --- Chip ---

pub const ChipOptions = struct {
    bg: Color = 0x282838FF,
    bg_selected: Color = 0x3B5BDBFF,
    color: Color = 0xFFFFFFFF,
    radius: f32 = 12,
    padding: EdgeInsets = .{ .left = 10, .top = 4, .right = 10, .bottom = 4 },
    size: f32 = 14,
};

const ChipState = struct {
    label: [:0]const u8, // owned
    selected: ?*ui.state.Signal(bool) = null,
    on_pressed: ?Callback = null,
    on_deleted: ?Callback = null,
    opts: ChipOptions,
};

fn chipMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(ChipState, n);
    const m = ui.paint.measureText(s.label, s.opts.size, false);
    const extra: f32 = if (s.on_deleted != null) 16 else 0; // delete icon zone
    return c.constrain(.{ .w = m.width + s.opts.padding.hSum() + extra, .h = m.height + s.opts.padding.vSum() });
}
fn chipLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn chipPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(ChipState, n);
    const b = n.bounds;
    const selected = if (s.selected) |sig| sig.get() else false;
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, s.opts.radius, if (selected) s.opts.bg_selected else s.opts.bg);
    const m = ui.paint.measureText(s.label, s.opts.size, false);
    const text_y = b.y + (b.h - m.height) / 2 + m.ascent;
    ui.paint.text(ctx, s.label, b.x + s.opts.padding.left, text_y, s.opts.size, false, s.opts.color);
    if (s.on_deleted != null) {
        const glyph = "\u{2715}"; // ✕
        const gm = ui.paint.measureText(glyph, s.opts.size, false);
        ui.paint.text(ctx, glyph, b.x + b.w - s.opts.padding.right - gm.width, text_y, s.opts.size, false, s.opts.color);
    }
}
fn chipOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(ChipState, n);
    if (ev.phase != .up) return ev.phase == .down;
    if (!n.bounds.contains(ev.x, ev.y)) return true;
    // The delete icon zone is the right padding area.
    if (s.on_deleted != null and ev.x >= n.bounds.x + n.bounds.w - s.opts.padding.right) {
        if (s.on_deleted) |cb| cb.fn_ptr(cb.userdata);
    } else if (s.on_pressed) |cb| {
        cb.fn_ptr(cb.userdata);
    }
    return true;
}
fn chipDeinit(n: *Node) void {
    const s = stateOf(ChipState, n);
    if (s.selected) |sig| sig.unsubscribe(.{ .node = n });
    input.releaseNode(n);
    n.allocator.free(s.label);
    n.allocator.destroy(s);
}
const chip_vtable = ui.node.VTable{
    .measure = chipMeasure,
    .layout = chipLayout,
    .paint = chipPaint,
    .deinit = chipDeinit,
    .on_pointer = chipOnPointer,
};

pub fn chip(allocator: std.mem.Allocator, label: []const u8, selected: ?*ui.state.Signal(bool), on_pressed: ?Callback, on_deleted: ?Callback, opts: ChipOptions) !*Node {
    const node = try Node.create(allocator, &chip_vtable);
    errdefer node.allocator.destroy(node); // no state yet; children list is empty
    const s = try allocator.create(ChipState);
    errdefer allocator.destroy(s);
    const buf = try allocator.alloc(u8, label.len + 1);
    errdefer allocator.free(buf);
    @memcpy(buf[0..label.len], label);
    buf[label.len] = 0;
    s.* = .{ .label = buf[0..label.len :0], .selected = selected, .on_pressed = on_pressed, .on_deleted = on_deleted, .opts = opts };
    node.state = s;
    if (selected) |sig| ui.state.bindNode(node, sig);
    return node;
}

// --- tests ---

const Rec = struct { fired: u32 = 0 };

fn recCb(userdata: ?*anyopaque) void {
    const r: *Rec = @ptrCast(@alignCast(userdata.?));
    r.fired += 1;
}

fn click(router: *input.InputRouter, root: *Node, x: f32, y: f32) void {
    router.dispatchPointer(root, .{ .phase = .down, .x = x, .y = y });
    router.dispatchPointer(root, .{ .phase = .up, .x = x, .y = y });
}

test "button fires on_pressed on click, tracks pressed/hover state" {
    var rec = Rec{};
    const cb: Callback = .{ .fn_ptr = recCb, .userdata = &rec };
    const root = try button(std.testing.allocator, cb, .{});
    defer root.deinit();
    root.add(try text_w.text(std.testing.allocator, "OK", .{}));
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    var router = input.InputRouter{};
    // measure: child + padding
    const size = root.measure(.{});
    try std.testing.expect(size.w > 32);
    try std.testing.expect(size.h > 16);
    // press → pressed visual; release inside → callback
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 20 });
    try std.testing.expect(stateOf(ButtonState, root).pressed);
    router.dispatchPointer(root, .{ .phase = .up, .x = 50, .y = 20 });
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    try std.testing.expect(!stateOf(ButtonState, root).pressed);
    // release outside → no callback
    router.dispatchPointer(root, .{ .phase = .down, .x = 50, .y = 20 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 500, .y = 500 });
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    // hover
    router.dispatchPointer(root, .{ .phase = .move, .x = 50, .y = 20 });
    try std.testing.expect(stateOf(ButtonState, root).hovered);
}

test "toggle flips the signal on click and fires on_changed" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    var rec = Rec{};
    const root = try toggle(std.testing.allocator, sig, .{ .fn_ptr = recCb, .userdata = &rec }, .{});
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 44, .h = 24 });
    var router = input.InputRouter{};
    click(&router, root, 22, 12);
    try std.testing.expect(sig.get());
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    click(&router, root, 22, 12);
    try std.testing.expect(!sig.get());
    try std.testing.expectEqual(@as(u32, 2), rec.fired);
}

test "checkbox toggles the signal on click" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const root = try checkbox(std.testing.allocator, sig, null, .{});
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    var router = input.InputRouter{};
    click(&router, root, 10, 10);
    try std.testing.expect(sig.get());
}

test "radio selects its value in the group" {
    const group = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer group.deinit();
    // a and b are owned by root (no defer on them — root.deinit covers them).
    const a = try Radio(u32).radio(std.testing.allocator, group, 1, .{});
    const b = try Radio(u32).radio(std.testing.allocator, group, 2, .{});
    const root = try goldenSolidRoot(std.testing.allocator, a, b);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 48, .h = 20 });
    var router = input.InputRouter{};
    click(&router, root, 34, 10); // radio B
    try std.testing.expectEqual(@as(u32, 2), group.get());
}

fn goldenSolidRoot(allocator: std.mem.Allocator, a: *Node, b: *Node) !*Node {
    const root = try layout_w.row(allocator, .{ .gap = 4, .cross_align = .start });
    root.add(a);
    root.add(b);
    return root;
}

test "slider drag sets the signal (clamped to 0..1)" {
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    var rec = Rec{};
    const root = try slider(std.testing.allocator, sig, .{ .fn_ptr = recCb, .userdata = &rec }, .{});
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 24 });
    var router = input.InputRouter{};
    router.dispatchPointer(root, .{ .phase = .down, .x = 75, .y = 12 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), sig.get(), 0.001);
    router.dispatchPointer(root, .{ .phase = .move, .x = 50, .y = 12 }); // drag (captured)
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sig.get(), 0.001);
    router.dispatchPointer(root, .{ .phase = .move, .x = 500, .y = 12 }); // beyond → clamped
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sig.get(), 0.001);
    router.dispatchPointer(root, .{ .phase = .up, .x = 500, .y = 12 });
    try std.testing.expectEqual(@as(u32, 3), rec.fired);
}

test "text field edits the buffer (type, backspace, submit, escape)" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var changed = Rec{};
    var submitted = Rec{};
    const root = try textField(std.testing.allocator, .{ .placeholder = "hint" }, .{ .fn_ptr = recCb, .userdata = &changed }, .{ .fn_ptr = recCb, .userdata = &submitted });
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 160, .h = 32 });
    const s = stateOf(TextFieldState, root);
    // click to focus
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 16 });
    try std.testing.expect(input.isFocused(root));
    // type "ab"
    router.dispatchKey(.{ .kind = .text_input, .text = "a" });
    router.dispatchKey(.{ .kind = .text_input, .text = "b" });
    try std.testing.expectEqualStrings("ab", s.text());
    try std.testing.expectEqual(@as(u32, 2), changed.fired);
    // backspace deletes the last codepoint (multi-byte safe)
    router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("a", s.text());
    // enter submits, escape unfocuses
    router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), submitted.fired);
    router.dispatchKey(.{ .kind = .key_down, .key = .escape });
    try std.testing.expect(!input.isFocused(root));
}

test "text field deletes multi-byte codepoints correctly" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const root = try textField(std.testing.allocator, .{ .initial = "a\u{25CF}b" }, null, null); // a●b (● = 3 bytes)
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 160, .h = 32 });
    const s = stateOf(TextFieldState, root);
    try std.testing.expectEqualStrings("a\u{25CF}b", s.text());
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 16 });
    router.dispatchKey(.{ .kind = .key_down, .key = .backspace }); // deletes b
    try std.testing.expectEqualStrings("a\u{25CF}", s.text());
    router.dispatchKey(.{ .kind = .key_down, .key = .backspace }); // deletes ● (3 bytes at once)
    try std.testing.expectEqualStrings("a", s.text());
}

test "dropdown opens on click, selects an item, closes on outside click" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var rec = Rec{};
    const dd = try dropdown(std.testing.allocator, &.{ "One", "Two", "Three" }, .{}, .{ .fn_ptr = recCb, .userdata = &rec });
    defer dd.deinit();
    dd.layout(.{ .x = 0, .y = 0, .w = 100, .h = 28 });
    // click the box → open
    click(&router, dd, 50, 14);
    try std.testing.expect(stateOf(DropdownState, dd).open);
    // click item 1 (menu rows start below the box, 28px tall → row 1 is y in [56, 84))
    click(&router, dd, 50, 70);
    try std.testing.expect(!stateOf(DropdownState, dd).open);
    try std.testing.expectEqual(@as(usize, 1), stateOf(DropdownState, dd).selected);
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    // reopen, click outside → closed (barrier)
    click(&router, dd, 50, 14);
    try std.testing.expect(stateOf(DropdownState, dd).open);
    router.dispatchPointer(dd, .{ .phase = .down, .x = 500, .y = 500 });
    try std.testing.expect(!stateOf(DropdownState, dd).open);
}

test "dropdown: open/close damage covers the box AND the menu rows" {
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const dd = try dropdown(std.testing.allocator, &.{ "One", "Two", "Three" }, .{}, null);
    defer dd.deinit();
    dd.layout(.{ .x = 0, .y = 0, .w = 100, .h = 28 });
    dd.clearDamage();
    click(&router, dd, 50, 14); // open
    try std.testing.expect(dd.damage_valid);
    // box (0,0,100,28) ∪ 3 menu rows of 28 below → (0,0,100,112)
    try std.testing.expectEqual(@as(f32, 0), dd.damage.x);
    try std.testing.expectEqual(@as(f32, 0), dd.damage.y);
    try std.testing.expectEqual(@as(f32, 100), dd.damage.w);
    try std.testing.expectEqual(@as(f32, 112), dd.damage.h);
    dd.clearDamage();
    click(&router, dd, 50, 70); // select item 1 → close
    try std.testing.expect(dd.damage_valid);
    try std.testing.expectEqual(@as(f32, 0), dd.damage.x);
    try std.testing.expectEqual(@as(f32, 112), dd.damage.h); // menu area erased
}

test "chip fires on_pressed / on_deleted by click zone" {
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    var pressed = Rec{};
    var deleted = Rec{};
    const root = try chip(
        std.testing.allocator,
        "Tag",
        sig,
        .{ .fn_ptr = recCb, .userdata = &pressed },
        .{ .fn_ptr = recCb, .userdata = &deleted },
        .{},
    );
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 32 });
    var router = input.InputRouter{};
    click(&router, root, 30, 16); // label zone
    try std.testing.expectEqual(@as(u32, 1), pressed.fired);
    try std.testing.expectEqual(@as(u32, 0), deleted.fired);
    click(&router, root, 95, 16); // delete zone (right padding)
    try std.testing.expectEqual(@as(u32, 1), deleted.fired);
    try std.testing.expectEqual(@as(u32, 1), pressed.fired);
}

// --- golden tests (interactive: dispatch input between frames) ---

test "golden: button paints normal/hover/pressed states exactly" {
    const bg = 0x101010FF;
    var rec = Rec{};
    const root = try button(std.testing.allocator, .{ .fn_ptr = recCb, .userdata = &rec }, .{
        .bg = 0x3B5BDBFF,
        .bg_hover = 0x4C6EF5FF,
        .bg_pressed = 0x364FC7FF,
        .radius = 0, // exact rect: only the text ink reduces the bg count
    });
    defer root.deinit();
    root.add(try text_w.text(std.testing.allocator, "OK", .{ .color = 0xFFFFFFFF }));
    var r = try golden.Renderer.init(std.testing.allocator, 128, 64);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 128, .h = 64 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expect(f1.countColor(0x3B5BDBFF) > 128 * 64 - 400); // bg + text ink
    // hover
    router.dispatchPointer(root, .{ .phase = .move, .x = 64, .y = 32 });
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(0x4C6EF5FF) > 128 * 64 - 400);
    // press
    router.dispatchPointer(root, .{ .phase = .down, .x = 64, .y = 32 });
    r.paint(root, bg);
    var f3 = try r.readback(std.testing.allocator);
    defer f3.deinit();
    try std.testing.expect(f3.countColor(0x364FC7FF) > 128 * 64 - 400);
    // release → click fires; the pointer is still over the button → hover bg
    router.dispatchPointer(root, .{ .phase = .up, .x = 64, .y = 32 });
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    r.paint(root, bg);
    var f4 = try r.readback(std.testing.allocator);
    defer f4.deinit();
    try std.testing.expect(f4.countColor(0x4C6EF5FF) > 128 * 64 - 400); // hover bg + text
    // move away → leave → back to normal
    router.dispatchPointer(root, .{ .phase = .move, .x = 500, .y = 500 });
    r.paint(root, bg);
    var f5 = try r.readback(std.testing.allocator);
    defer f5.deinit();
    try std.testing.expect(f5.countColor(0x3B5BDBFF) > 128 * 64 - 400); // normal bg + white text
}

test "golden: toggle moves the knob on click" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const root = try toggle(std.testing.allocator, sig, null, .{});
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 44, 24);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 44, .h = 24 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // knob (20px circle) at left: interior (6, 6, 12, 12) is solid white
    try std.testing.expectEqual(@as(u64, 144), f1.countColorIn(.{ .x = 6, .y = 6, .w = 12, .h = 12 }, white));
    try std.testing.expectEqual(@as(u64, 0), f1.countColorIn(.{ .x = 26, .y = 6, .w = 12, .h = 12 }, white));
    click(&router, root, 22, 12);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    // knob moved right: interior (26, 6, 12, 12) solid white, left empty
    try std.testing.expectEqual(@as(u64, 144), f2.countColorIn(.{ .x = 26, .y = 6, .w = 12, .h = 12 }, white));
    try std.testing.expectEqual(@as(u64, 0), f2.countColorIn(.{ .x = 6, .y = 6, .w = 12, .h = 12 }, white));
}

test "golden: checkbox shows the check mark after click" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const accent = 0x3B5BDBFF;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const root = try checkbox(std.testing.allocator, sig, null, .{});
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 20, 20);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 20, .h = 20 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // Off: no accent box, no check glyph.
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(accent));
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(white));
    click(&router, root, 10, 10);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    // On: accent box (AA edges) + white check glyph ink.
    try std.testing.expect(f2.countColor(accent) > 300);
    try std.testing.expect(f2.countColor(white) > 0);
}

test "golden: radio moves the dot to the clicked radio" {
    const bg = 0x101010FF;
    const dot = 0x3B5BDBFF;
    const group = try ui.state.Signal(u32).init(std.testing.allocator, 1);
    defer group.deinit();
    const a = try Radio(u32).radio(std.testing.allocator, group, 1, .{});
    const b = try Radio(u32).radio(std.testing.allocator, group, 2, .{});
    const root = try goldenSolidRoot(std.testing.allocator, a, b);
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 48, 20);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 48, .h = 20 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // A selected: dot in A's half (interior of the 8px dot circle).
    try std.testing.expectEqual(@as(u64, 16), f1.countColorIn(.{ .x = 8, .y = 8, .w = 4, .h = 4 }, dot));
    try std.testing.expectEqual(@as(u64, 0), f1.countColorIn(.{ .x = 32, .y = 8, .w = 4, .h = 4 }, dot));
    click(&router, root, 34, 10); // radio B
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(u64, 0), f2.countColorIn(.{ .x = 8, .y = 8, .w = 4, .h = 4 }, dot));
    try std.testing.expectEqual(@as(u64, 16), f2.countColorIn(.{ .x = 32, .y = 8, .w = 4, .h = 4 }, dot));
}

test "golden: slider drag moves fill and knob" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const fill = 0x3B5BDBFF;
    const track = 0x444455FF;
    const sig = try ui.state.Signal(f32).init(std.testing.allocator, 0);
    defer sig.deinit();
    const root = try slider(std.testing.allocator, sig, null, .{});
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 24);
    defer r.deinit();
    var router = input.InputRouter{};
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 24 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // value 0: no fill; knob centered on the left edge.
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(fill));
    try std.testing.expectEqual(track, f1.pixelAt(50, 12));
    try std.testing.expectEqual(white, f1.pixelAt(0, 12)); // knob center
    // drag to 75%
    router.dispatchPointer(root, .{ .phase = .down, .x = 75, .y = 12 });
    router.dispatchPointer(root, .{ .phase = .up, .x = 75, .y = 12 });
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(fill, f2.pixelAt(10, 12)); // filled track
    try std.testing.expectEqual(track, f2.pixelAt(95, 12)); // unfilled track
    try std.testing.expectEqual(white, f2.pixelAt(75, 12)); // knob center
    // knob interior (16px circle at center (75, 12)) is solid white
    try std.testing.expectEqual(@as(u64, 36), f2.countColorIn(.{ .x = 72, .y = 9, .w = 6, .h = 6 }, white));
}

test "golden: text field shows typed text and the focus cursor" {
    const bg = 0x101010FF;
    const white = 0xFFFFFFFF;
    const field_bg = 0x282838FF;
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    const root = try textField(std.testing.allocator, .{ .placeholder = "hint" }, null, null);
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 32);
    defer r.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 160, .h = 32 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // placeholder ink (hint color is AA → count "not field bg" in the text area)
    const text_area = Rect{ .x = 8, .y = 6, .w = 144, .h = 20 };
    const ink1 = f1.countNotIn(text_area, field_bg);
    try std.testing.expect(ink1 > 0); // placeholder "hint" is visible
    // click to focus → cursor bar appears (solid white 2px bar)
    click(&router, root, 80, 16);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(white) > f1.countColor(white)); // cursor bar
    // type "ab" → white text replaces the gray placeholder (white ink grows)
    router.dispatchKey(.{ .kind = .text_input, .text = "ab" });
    r.paint(root, bg);
    var f3 = try r.readback(std.testing.allocator);
    defer f3.deinit();
    try std.testing.expect(f3.countColor(white) > f2.countColor(white));
}

test "golden: dropdown menu appears on open and disappears on select" {
    const bg = 0x101010FF;
    const menu_bg = 0x1E1E2EFF;
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    var rec = Rec{};
    const dd = try dropdown(std.testing.allocator, &.{ "One", "Two", "Three" }, .{ .menu_bg = menu_bg }, .{ .fn_ptr = recCb, .userdata = &rec });
    defer dd.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 160, 200);
    defer r.deinit();
    // Integer rect: the menu rows (fillRect) land on exact pixels.
    dd.layout(.{ .x = 20, .y = 20, .w = 100, .h = 28 });
    r.paint(dd, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    try std.testing.expectEqual(@as(u64, 0), f1.countColor(menu_bg)); // closed
    // click the box → open (menu = 3 rows of 100x28 below the box)
    click(&router, dd, 70, 34);
    r.paint(dd, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    // The rows are vertically centered text on menu_bg: the bottom 4px strip of
    // each row is text-free → exact counts there.
    try std.testing.expectEqual(@as(u64, 400), f2.countColorIn(.{ .x = 20, .y = 72, .w = 100, .h = 4 }, menu_bg));
    try std.testing.expectEqual(@as(u64, 400), f2.countColorIn(.{ .x = 20, .y = 100, .w = 100, .h = 4 }, menu_bg));
    try std.testing.expectEqual(@as(u64, 400), f2.countColorIn(.{ .x = 20, .y = 128, .w = 100, .h = 4 }, menu_bg));
    try std.testing.expect(f2.countColor(menu_bg) > 7500); // rows minus text ink
    // click item 1 (second row below the box: y in [76, 104))
    click(&router, dd, 70, 90);
    try std.testing.expectEqual(@as(usize, 1), stateOf(DropdownState, dd).selected);
    try std.testing.expectEqual(@as(u32, 1), rec.fired);
    r.paint(dd, bg);
    var f3 = try r.readback(std.testing.allocator);
    defer f3.deinit();
    try std.testing.expectEqual(@as(u64, 0), f3.countColor(menu_bg)); // closed again
}

test "golden: chip paints selected background when the signal is set" {
    const bg = 0x101010FF;
    const sig = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer sig.deinit();
    const root = try chip(std.testing.allocator, "Tag", sig, null, null, .{ .bg = 0x282838FF, .bg_selected = 0x3B5BDBFF });
    defer root.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 100, 32);
    defer r.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 32 });
    r.paint(root, bg);
    var f1 = try r.readback(std.testing.allocator);
    defer f1.deinit();
    // Unselected bg (rounded corners + text ink reduce the exact count).
    try std.testing.expect(f1.countColor(0x282838FF) > 100 * 32 - 400);
    sig.set(true);
    r.paint(root, bg);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expect(f2.countColor(0x3B5BDBFF) > 100 * 32 - 400);
}
