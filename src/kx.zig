// Skia ABI bindings — generated at build time by `zig translate-c` over
// kx_skia/include/kx_skia.h (b.addTranslateC in build.zig).
pub const c = @import("kx_c");

pub const Ctx = c.kx_ctx;

// --- macOS NSAccessibility bridge (Phase 3a) ---
pub const c_extern = struct {
    extern fn kx_a11y_init(root_node: ?*anyopaque) void;
    extern fn kx_a11y_shutdown() void;
    extern fn kx_a11y_root_element() ?*anyopaque;
};

pub fn a11yInit(root: *anyopaque) void {
    c_extern.kx_a11y_init(root);
}

pub fn a11yShutdown() void {
    c_extern.kx_a11y_shutdown();
}

pub fn create(window: ?*anyopaque, width: c_int, height: c_int, backend: c.kx_backend) ?*Ctx {
    return c.kx_create(window, width, height, backend);
}
