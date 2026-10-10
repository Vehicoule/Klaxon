// platform_wasm.zig — Emscripten platform glue (Phase 3f, wasm32-emscripten).
//
// The browser owns the main thread: main() builds the host + tree, then
// runWasm() installs emscripten_set_main_loop_arg(wasmFrameCallback, ...) —
// one host.runIteration() per animation frame (fps = 0 → rAF/vsync). The
// callback never blocks: SDL_WaitEvent/SDL_Delay busy-poll without Asyncify
// and freeze the tab, so host.runIteration compiles its blocking branches
// and the SDL_Delay pacing out on emscripten (host.is_emscripten).
//
// A11y: the semantics bridge events are forwarded to web/kx_a11y.js (an
// emcc --js-library import — no EM_ASM string soup) through the extern
// kx_js_a11y_event; JS maintains the hidden ARIA DOM mirroring the canvas.
const std = @import("std");
const host_mod = @import("host.zig");
const ui = @import("ui.zig");
const sem = @import("ui/semantics.zig");

const Host = host_mod.Host;
const Node = ui.node.Node;

// Force-reference the JS-callable exports (kx_a11y_root_node, kx_a11y_key) so
// the linker keeps them — Zig only emits referenced symbols.
comptime {
    _ = kx_a11y_root_node;
    _ = kx_a11y_key;
}

// --- Emscripten C library (<emscripten.h>, resolved by emcc at link) ---

extern fn emscripten_set_main_loop_arg(
    cb: ?*const fn (arg: ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    fps: c_int, // 0 = run at the rAF / vsync cadence
    simulate_infinite_loop: c_int, // 1 = unwind main()'s stack; the loop keeps running
) void;

extern fn emscripten_cancel_main_loop() void;

// --- JS library (web/kx_a11y.js, linked with --js-library) ---

/// Forward one semantics bridge event to JS (hidden-DOM mirror). Convention:
/// on tree_dirty the node_id carries the ROOT NODE POINTER — JS passes it to
/// ccall('kx_a11y_dump_tree', ...) to rebuild the ARIA tree.
extern fn kx_js_a11y_event(
    kind: u32, // sem.BridgeEvent.Kind backing integer
    node_id: u64,
    text_ptr: [*]const u8,
    text_len: usize,
    region: u32, // sem.LiveRegion backing integer
) void;

// --- rAF main loop ---

const FrameState = struct {
    host: *Host,
    root: *Node,
    max_frames: u64,
    on_frame: ?host_mod.OnFrame,
    on_frame_ctx: ?*anyopaque,
};

var frame_state: FrameState = undefined;
var loop_installed: bool = false;

/// Root Node pointer captured in runWasm — served to JS by kx_a11y_root_node
/// so the browser side can call kx_a11y_dump_tree(root).
var root_node_ptr: ?*anyopaque = null;

/// Install the rAF main loop and return. The loop state is process-global
/// (single-window P0, same pattern as the input router). Call from main()
/// after the tree is built; with simulate_infinite_loop = 1 the emscripten
/// call unwinds main()'s stack (Zig defers do not run — the host lives as
/// long as the page) without stopping the scheduled loop.
pub fn runWasm(host: *Host, root: *Node, max_frames: u64, on_frame: ?host_mod.OnFrame, on_frame_ctx: ?*anyopaque) void {
    // Remember the root for kx_a11y_root_node (JS dumps the tree through it).
    root_node_ptr = @ptrCast(root);
    // A11y bridge: forward semantics events to the JS hidden-DOM mirror.
    // userdata carries the root pointer — the callback substitutes it for
    // node_id on tree_dirty (kx_js_a11y_event's contract above).
    sem.setBridgeC(wasmBridgeCallback, @ptrCast(root));
    // Initial sync: the JS side builds the hidden DOM from the first dump.
    sem.notifyTreeDirty();

    frame_state = .{
        .host = host,
        .root = root,
        .max_frames = max_frames,
        .on_frame = on_frame,
        .on_frame_ctx = on_frame_ctx,
    };
    if (loop_installed) return;
    loop_installed = true;
    // fps = 0 → rAF: the browser paces the loop (vsync-aligned).
    emscripten_set_main_loop_arg(wasmFrameCallback, null, 0, 1);
}

/// rAF callback: exactly one non-blocking loop pass (drain events, tick the
/// timeline + app, render when dirty). Returning hands the main thread back
/// to the browser, which composites the drawing buffer.
fn wasmFrameCallback(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    const st = &frame_state;
    const quit = st.host.runIteration(st.root, st.on_frame, st.on_frame_ctx) catch {
        // A loop error on wasm is unrecoverable: stop the loop.
        emscripten_cancel_main_loop();
        return;
    };
    // Quit request, or the demo's frame budget exhausted: stop the rAF loop.
    if (quit or st.host.stats.frames >= st.max_frames) emscripten_cancel_main_loop();
}

/// Semantics bridge callback (C ABI, installed via setBridgeC): forwards
/// every event to JS. tree_dirty carries no node — the root pointer travels
/// in node_id so JS can dump the tree.
fn wasmBridgeCallback(userdata: ?*anyopaque, ev: sem.BridgeEventC) callconv(.c) void {
    const node_id: u64 = if (ev.kind == @intFromEnum(sem.BridgeEvent.Kind.tree_dirty))
        if (userdata) |u| @intFromPtr(u) else 0
    else
        ev.node_id;
    kx_js_a11y_event(ev.kind, node_id, ev.text, ev.text_len, ev.region);
}

// --- JS → Zig exports (web/kx_a11y.js) ---

/// Export for JS (web/kx_a11y.js): returns the root Node pointer captured by
/// runWasm, so the JS side can call kx_a11y_dump_tree(root). u64 sidesteps
/// pointer-alignment concerns in the wasm32 C ABI; JS sees a plain number.
export fn kx_a11y_root_node() callconv(.c) u64 {
    return if (root_node_ptr) |p| @intFromPtr(p) else 0;
}

/// Export for JS (web/kx_a11y.js): push a keyboard event into SDL's queue —
/// called from the hidden-DOM mirror's keydown/keyup handlers.
///   down: 1 = key down, 0 = key up
///   key:  SDL_Keycode (u32, e.g. 13 = Enter, 0x40000050 = ArrowLeft)
///   mod:  SDL_Keymod bitmask (u16, e.g. 0x0001 = Shift, 0x0040 = Ctrl)
export fn kx_a11y_key(down: c_int, key: u32, mod: u16) callconv(.c) void {
    const sdl = @import("sdl.zig");
    var event: sdl.c.SDL_Event = std.mem.zeroes(sdl.c.SDL_Event);
    event.type = @intCast(if (down != 0) sdl.c.SDL_EVENT_KEY_DOWN else sdl.c.SDL_EVENT_KEY_UP);
    event.common.timestamp = sdl.c.SDL_GetTicksNS();
    event.key.key = key;
    event.key.mod = mod;
    event.key.down = down != 0;
    event.key.windowID = 0; // 0 = virtual keyboard, no specific window
    _ = sdl.c.SDL_PushEvent(&event);
}
