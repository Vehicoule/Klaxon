// Skia ABI bindings — generated at build time by `zig translate-c` over
// kx_skia/include/kx_skia.h (b.addTranslateC in build.zig).
pub const c = @import("kx_c");

pub const Ctx = c.kx_ctx;

pub fn create(window: ?*anyopaque, width: c_int, height: c_int, backend: c.kx_backend) ?*Ctx {
    return c.kx_create(window, width, height, backend);
}
